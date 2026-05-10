import Foundation
import AI
import EPUB

/// Per-EPUB chat session: tracks message history, runs queries
/// through the hybrid retriever (BM25 + embedding cosine), and asks
/// Claude / Ollama to answer using the retrieved paragraphs. Lives on
/// the `EditorViewModel` and is recreated when a different EPUB is
/// opened.
///
/// Retrieval is two-stage:
///  1. On init, kick off an async build of the per-book embedding
///     index (consulting the on-disk sidecar so unchanged paragraphs
///     skip re-embedding). The chat pane shows an "Indexing…" badge
///     while it runs.
///  2. Per send, optionally embed the query (when style is
///     `.embeddings` or `.hybrid` and the index is ready) and call
///     `HybridRetriever.search` to get paragraph-shaped hits. The
///     answer prompt receives those paragraphs grouped by chapter.
@MainActor
final class BookChatViewModel: ObservableObject {
    /// Replayable transcript. The user-facing pane renders this
    /// straight; assistant messages may carry citations parsed
    /// out of `[chapter:N]` markers in the model's response.
    @Published private(set) var messages: [BookChatMessage] = []
    @Published var input: String = ""
    @Published private(set) var isThinking: Bool = false
    /// Surfaces transient failures (no API key, network error,
    /// content-filter refusal, etc.) so the pane can show a banner.
    @Published var errorMessage: String?
    /// State of the per-book embedding index. The chat pane reads
    /// this to render the "Indexing for chat-with-book…" badge while
    /// it runs and to decide whether the next query can use the
    /// hybrid retriever.
    @Published private(set) var embeddingStatus: EmbeddingStatus = .idle

    /// Index lifecycle states surfaced to the UI. `.failed` carries
    /// the user-facing message so the pane can show it inline.
    enum EmbeddingStatus: Equatable {
        case idle
        case building
        case ready
        case disabled    // user picked .bm25 retrieval style
        case failed(String)
    }

    /// BM25 index over chapters. Built lazily on first send so opening
    /// the editor stays cheap for users who never use chat.
    private var bm25Index: BookKeywordIndex?
    /// Per-paragraph vector index; built asynchronously after init
    /// or after `bookDidReload`. Nil until the build completes.
    private var embeddingIndex: BookEmbeddingIndex?
    private(set) var book: EPUBBook
    private let bookTitle: String
    private let client: AnthropicAPIClient
    private let ollama: OllamaClient
    private let transcriptStore: ChatTranscriptStore
    private let embeddingsStore: EmbeddingsSidecarStore
    private let epubURL: URL

    /// Selected chat backend. Resolved per-send so a Settings change
    /// applies on the next query without rebuilding the view model.
    /// Default is Cloud (Haiku 4.5).
    private var backend: ChatBackend {
        if let raw = UserDefaults.standard.string(forKey: "humanist.chat.backend"),
           let b = ChatBackend(rawValue: raw) {
            return b
        }
        // Legacy fallback: pre-backend-picker users had a "useSonnet"
        // bool. Honour it so an existing setup doesn't reset on first
        // launch after this change.
        return UserDefaults.standard.bool(forKey: "humanist.chat.useSonnet")
            ? .cloudSonnet : .cloudHaiku
    }

    /// Local Ollama model tag. Default is the Gemma 4 26B MoE; users
    /// can override via Settings → AI for a different local model.
    private var ollamaModel: String {
        let raw = UserDefaults.standard.string(forKey: "humanist.chat.ollamaModel")
            ?? ""
        return raw.isEmpty ? "gemma4:26b" : raw
    }

    /// User's retrieval style. Read per-send so a Settings change
    /// applies immediately.
    private var retrievalStyle: HybridRetriever.Style {
        let raw = UserDefaults.standard.string(
            forKey: "humanist.chat.retrievalStyle"
        ) ?? HybridRetriever.Style.hybrid.rawValue
        return HybridRetriever.Style(rawValue: raw) ?? .hybrid
    }

    /// User's embedding-backend choice. Today only `.appleNL` is
    /// wired; the other choices fall back to `.appleNL` until their
    /// implementations land.
    private var embeddingBackendChoice: EmbeddingBackendChoice {
        let raw = UserDefaults.standard.string(
            forKey: EmbeddingBackendChoice.userDefaultsKey
        ) ?? EmbeddingBackendChoice.appleNL.rawValue
        return EmbeddingBackendChoice(rawValue: raw) ?? .appleNL
    }

    /// Outstanding stream task. Cancelled when the user closes the
    /// pane mid-stream or sends a follow-up too fast.
    private var streamTask: Task<Void, Never>?
    /// Outstanding embedding-build task. Cancelled and replaced when
    /// `bookDidReload` runs so we don't race two builds against
    /// possibly-divergent paragraph numbering.
    private var embeddingBuildTask: Task<Void, Never>?

    /// Top-K BM25 chapters when the path is BM25-only. Mirrors the
    /// pre-embedding behavior.
    private static let maxRetrievedChapters = 4
    /// Per-chapter character cap on the BM25-only context.
    private static let maxChapterChars = 60_000
    /// Top-K paragraphs returned by hybrid / embeddings retrieval.
    /// Higher than the chapter count because each paragraph is much
    /// smaller — 12 paragraphs ≈ 12 KB, well under the cloud cost
    /// budget and enough to cover the answer most of the time.
    private static let maxRetrievedParagraphs = 12
    /// Per-paragraph character cap. Trims abnormally long paragraphs
    /// (one of the OCR pipeline's known failure modes — a missed
    /// paragraph break can produce a 10 KB run-on). 4 KB is plenty
    /// for any well-formed paragraph.
    private static let maxParagraphChars = 4_000

    init(book: EPUBBook, epubURL: URL) {
        self.book = book
        self.epubURL = epubURL
        self.bookTitle = book.metadata.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? book.sourceURL
            .deletingPathExtension()
            .lastPathComponent
        let keyStore = AnthropicAPIKeyStore()
        self.client = AnthropicAPIClient(
            apiKeyProvider: { keyStore.read() }
        )
        self.ollama = OllamaClient()
        self.transcriptStore = ChatTranscriptStore()
        self.embeddingsStore = EmbeddingsSidecarStore()
        // Restore prior transcript synchronously so the pane
        // doesn't flash empty before the load completes.
        self.messages = transcriptStore.read(for: epubURL)
        // Kick off embedding indexing in the background; the
        // pane shows progress via `embeddingStatus`.
        startEmbeddingBuild()
    }

    deinit {
        // Use a non-isolated cancel — the task will see the cancel
        // on its next yield. Final transcript was persisted on
        // the last `appendAndPersist`.
        streamTask?.cancel()
        embeddingBuildTask?.cancel()
    }

    /// Submit `input` as the next user turn. No-op on empty / while
    /// already thinking. Builds the BM25 index if needed, runs
    /// retrieval through `HybridRetriever`, dispatches to the
    /// configured backend (Cloud Haiku/Sonnet via the Anthropic API,
    /// or local Ollama), appends the assistant reply when the
    /// round-trip completes.
    func send() async {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isThinking else { return }
        input = ""
        errorMessage = nil

        let userMessage = BookChatMessage(role: .user, text: query)
        appendAndPersist(userMessage)

        if bm25Index == nil {
            bm25Index = buildBM25Index()
        }
        guard let bm25 = bm25Index else {
            // Shouldn't happen — buildBM25Index returns a non-nil
            // value even for an empty book.
            isThinking = false
            return
        }

        isThinking = true
        let chosenBackend = backend
        let style = retrievalStyle
        let embeddingIndexSnapshot = embeddingIndex
        let task = Task { [weak self] in
            guard let self else { return }
            // Embed the query if the style needs it. Failures fall
            // back to BM25-only retrieval — the user still gets an
            // answer rather than a banner.
            let queryVector: [Float]?
            if style != .bm25, let index = embeddingIndexSnapshot {
                queryVector = await self.embedQuery(query, using: index.backend)
            } else {
                queryVector = nil
            }

            let retriever = HybridRetriever(
                style: style,
                bm25: bm25,
                embeddings: embeddingIndexSnapshot,
                queryVector: queryVector
            )
            let usedParagraphs = (style != .bm25) && (queryVector != nil) && (embeddingIndexSnapshot != nil)
            let topK = usedParagraphs
                ? Self.maxRetrievedParagraphs
                : Self.maxRetrievedChapters
            let hits = retriever.search(query: query, topK: topK)
            let context = self.renderContext(
                hits: hits, paragraphMode: usedParagraphs
            )
            let userPrompt = context + "\n\nQuestion: " + query

            switch chosenBackend {
            case .cloudHaiku, .cloudSonnet:
                await self.runCloudSend(
                    userPrompt: userPrompt, allowedHits: hits,
                    model: chosenBackend == .cloudSonnet ? .sonnet4_6 : .haiku4_5
                )
            case .localOllama:
                await self.runOllamaSend(userPrompt: userPrompt, allowedHits: hits)
            }
        }
        streamTask?.cancel()
        streamTask = task
    }

    private func runCloudSend(
        userPrompt: String,
        allowedHits: [HybridRetriever.Hit],
        model: AnthropicModel
    ) async {
        defer {
            isThinking = false
            streamTask = nil
        }
        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: 1500,
            system: .cached(systemPrompt, ttl: .oneHour),
            messages: [
                Message(role: .user, content: .plain(userPrompt))
            ],
            thinking: .disabled
        )
        do {
            let response = try await client.send(request)
            try Task.checkCancellation()
            let raw = response.firstText() ?? ""
            let cited = parseCitations(in: raw, allowedHits: allowedHits)
            appendAndPersist(BookChatMessage(
                role: .assistant,
                text: cited.cleaned,
                citations: cited.citations
            ))
        } catch is CancellationError {
            return
        } catch let error as AnthropicAPIError {
            appendAndPersist(BookChatMessage(
                role: .assistant,
                text: "Couldn't answer that — \(error.localizedDescription)."
            ))
        } catch {
            appendAndPersist(BookChatMessage(
                role: .assistant,
                text: "Couldn't answer that — \(error.localizedDescription)."
            ))
        }
    }

    private func runOllamaSend(
        userPrompt: String,
        allowedHits: [HybridRetriever.Hit]
    ) async {
        defer {
            isThinking = false
            streamTask = nil
        }
        let model = ollamaModel
        do {
            let raw = try await ollama.chat(
                model: model,
                system: systemPrompt,
                userMessage: userPrompt
            )
            try Task.checkCancellation()
            let cited = parseCitations(in: raw, allowedHits: allowedHits)
            appendAndPersist(BookChatMessage(
                role: .assistant,
                text: cited.cleaned,
                citations: cited.citations
            ))
        } catch is CancellationError {
            return
        } catch let error as OllamaError {
            appendAndPersist(BookChatMessage(
                role: .assistant,
                text: "Couldn't answer that — \(error.localizedDescription)."
            ))
        } catch {
            appendAndPersist(BookChatMessage(
                role: .assistant,
                text: "Couldn't answer that — \(error.localizedDescription)."
            ))
        }
    }

    private func appendAndPersist(_ message: BookChatMessage) {
        messages.append(message)
        persist()
    }

    private func persist() {
        transcriptStore.write(messages, for: epubURL)
    }

    /// Wipe the transcript. Doesn't touch the keyword or embedding
    /// indexes — they're per-book, not per-session, and rebuilding
    /// the embedding index is expensive (~1 minute for NLEmbedding).
    func clear() {
        streamTask?.cancel()
        messages.removeAll()
        errorMessage = nil
        transcriptStore.clear(for: epubURL)
    }

    /// Called by the editor when the book reloads from disk (after
    /// a save, after Bulk Re-OCR, etc.). Drop the BM25 index and
    /// rebuild the embedding index against the freshest text. The
    /// sidecar's per-paragraph hashes mean unchanged paragraphs
    /// skip re-embedding — a typical save (one chapter edited)
    /// re-embeds ~1% of paragraphs, not the whole book.
    func bookDidReload(_ updated: EPUBBook) {
        self.book = updated
        self.bm25Index = nil
        self.embeddingIndex = nil
        startEmbeddingBuild()
    }

    // MARK: - Embedding pipeline

    /// Resolve the user's chosen embedding backend. Until the
    /// non-NLEmbedding paths land, anything other than `.appleNL`
    /// silently falls back to `.appleNL` so the index still builds.
    /// Returns nil only when the system can't even build the
    /// NLEmbedding fallback (rare).
    private func resolveEmbeddingBackend() -> (any EmbeddingBackend)? {
        switch embeddingBackendChoice {
        case .appleNL, .ollama, .voyage, .gemini:
            // .ollama / .voyage / .gemini will dispatch to their
            // own implementations once those backends are wired.
            // Until then, fall through to NLEmbedding so the chat
            // path keeps working — the Settings picker hides
            // unwired choices behind a "coming soon" hint.
            return NLSentenceEmbeddingBackend(language: .english)
        }
    }

    /// Spawn the background indexing task. Re-entrant — cancels any
    /// outstanding build first so we don't race two builds.
    private func startEmbeddingBuild() {
        // Honor user opt-out: if retrieval is BM25-only there's no
        // point spending the embed budget. The Settings picker can
        // flip this and a follow-up `bookDidReload` (or app restart)
        // re-runs the build.
        if retrievalStyle == .bm25 {
            embeddingStatus = .disabled
            return
        }
        embeddingBuildTask?.cancel()
        embeddingStatus = .building
        let url = epubURL
        let store = embeddingsStore
        let snapshot = book
        let backend = resolveEmbeddingBackend()
        guard let backend else {
            embeddingStatus = .failed("No embedding backend available.")
            return
        }
        embeddingBuildTask = Task { [weak self] in
            do {
                var sidecar = store.read(for: url)
                    ?? EmbeddingsSidecar.empty(
                        backend: backend.identifier,
                        dimension: backend.dimension
                    )
                // Discard cached vectors when the backend or
                // dimension changed — they're from a different
                // vector space and aren't comparable.
                if sidecar.backendIdentifier != backend.identifier
                    || sidecar.dimension != backend.dimension {
                    sidecar = EmbeddingsSidecar.empty(
                        backend: backend.identifier,
                        dimension: backend.dimension
                    )
                }
                let index = try await BookEmbeddingIndex.build(
                    for: snapshot, backend: backend, cache: &sidecar
                )
                store.write(sidecar, for: url)
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    self.embeddingIndex = index
                    self.embeddingStatus = .ready
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.embeddingStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Embed a single query string. Returns nil on backend failure
    /// (cosine path skips silently — we still have BM25).
    private func embedQuery(
        _ query: String, using backend: any EmbeddingBackend
    ) async -> [Float]? {
        do {
            let vectors = try await backend.embed([query])
            return vectors.first
        } catch {
            return nil
        }
    }

    // MARK: - retrieval

    private func buildBM25Index() -> BookKeywordIndex {
        let chapters: [BookKeywordIndex.Chapter] = book.spine.compactMap { id in
            guard let resource = book.resourcesByID[id],
                  let xhtml = resource.text else { return nil }
            return BookKeywordIndex.Chapter(
                id: id,
                title: chapterTitle(from: xhtml),
                text: stripTags(xhtml)
            )
        }
        return BookKeywordIndex(chapters: chapters)
    }

    /// Paragraph-level rendering when hybrid / embeddings retrieval
    /// returned hits with paragraph granularity. Chapter-level
    /// rendering when BM25-only style was used.
    private func renderContext(
        hits: [HybridRetriever.Hit], paragraphMode: Bool
    ) -> String {
        guard !hits.isEmpty else {
            return """
            (No paragraphs in this book matched the question. Answer \
            from the chapter list alone if possible; otherwise say \
            you can't find a match.)
            """
        }
        if paragraphMode {
            return renderParagraphContext(hits: hits)
        }
        return renderChapterContext(hits: hits)
    }

    /// Render paragraph-level hits grouped by chapter so the model
    /// can still cite `[chapter:N]` accurately. Within each chapter
    /// the paragraphs appear in their best-rank order (already what
    /// the retriever returns).
    private func renderParagraphContext(hits: [HybridRetriever.Hit]) -> String {
        var byChapter: [Int: [HybridRetriever.Hit]] = [:]
        var chapterOrder: [Int] = []
        for hit in hits {
            if byChapter[hit.chapterIdx] == nil {
                chapterOrder.append(hit.chapterIdx)
            }
            byChapter[hit.chapterIdx, default: []].append(hit)
        }
        var out = "Relevant paragraphs from \"\(bookTitle)\":\n\n"
        for chapterIdx in chapterOrder {
            guard let chapterHits = byChapter[chapterIdx] else { continue }
            let title = chapterTitle(forChapterIndex: chapterIdx)
                ?? "Chapter \(chapterIdx + 1)"
            out += "[chapter:\(chapterIdx)] \(title)\n"
            for hit in chapterHits {
                let text = String(hit.text.prefix(Self.maxParagraphChars))
                out += "  • \(text)\n"
            }
            out += "\n"
        }
        return out
    }

    /// Chapter-level rendering — used for BM25-only retrieval and
    /// for hybrid fallback when the embedding index isn't ready yet.
    private func renderChapterContext(hits: [HybridRetriever.Hit]) -> String {
        var out = "Available chapters from \"\(bookTitle)\":\n\n"
        for hit in hits {
            let body = hit.text.prefix(Self.maxChapterChars)
            let title = chapterTitle(forChapterIndex: hit.chapterIdx)
                ?? "Chapter \(hit.chapterIdx + 1)"
            out += "[chapter:\(hit.chapterIdx)] \(title)\n"
            out += String(body)
            out += "\n\n---\n\n"
        }
        return out
    }

    // MARK: - chapter parsing

    /// Title for the chapter at the given spine index. Looks up the
    /// resource and pulls the first `<h1>` / `<h2>` / `<title>`
    /// inside its XHTML. Falls back to nil; the renderer substitutes
    /// "Chapter N" in that case.
    private func chapterTitle(forChapterIndex idx: Int) -> String? {
        guard idx >= 0, idx < book.spine.count else { return nil }
        let resourceID = book.spine[idx]
        guard let resource = book.resourcesByID[resourceID],
              let xhtml = resource.text else { return nil }
        return chapterTitle(from: xhtml)
    }

    /// Pull the chapter title from the first `<h1>` / `<h2>` / `<title>`
    /// in the XHTML. Falls back to nil; the renderer substitutes
    /// "Chapter N" in that case.
    private func chapterTitle(from xhtml: String) -> String? {
        for tag in ["h1", "h2", "title"] {
            if let range = xhtml.range(
                of: "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>",
                options: .regularExpression
            ) {
                let chunk = String(xhtml[range])
                let inner = chunk
                    .replacingOccurrences(
                        of: "<[^>]+>",
                        with: "",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { return inner }
            }
        }
        return nil
    }

    /// Strip every HTML/XHTML tag and decode the small set of named
    /// entities (`&amp;` / `&lt;` / `&gt;` / `&quot;` / `&apos;`)
    /// — same posture as the existing PlainTextWriter for the
    /// sibling `.txt` output. Numeric refs (`&#160;` etc.) pass
    /// through unchanged; the model sees the raw codepoint as a
    /// plain space at most, which is fine.
    private func stripTags(_ xhtml: String) -> String {
        var s = xhtml.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression
        )
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&nbsp;": " ",
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - citation extraction

    private struct CitationParse {
        let cleaned: String
        let citations: [BookChatCitation]
    }

    /// Extract `[chapter:N]` markers from the model's reply. Replace
    /// each occurrence with a tagged span so the renderer can
    /// produce a clickable button; collect the unique
    /// `(chapterIndex, title)` pairs as `BookChatCitation` values
    /// for the message footer.
    private func parseCitations(
        in text: String, allowedHits: [HybridRetriever.Hit]
    ) -> CitationParse {
        let allowedIndices = Set(allowedHits.map(\.chapterIdx))
        var seen: [Int: BookChatCitation] = [:]
        let pattern = "\\[chapter:(\\d+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return CitationParse(cleaned: text, citations: [])
        }
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        var cleaned = text
        for match in matches.reversed() {
            guard match.numberOfRanges == 2 else { continue }
            let raw = nsText.substring(with: match.range(at: 1))
            guard let idx = Int(raw),
                  allowedIndices.contains(idx),
                  let resource = chapterResource(for: idx)
            else {
                // Drop the marker even if it's bogus — keeps the
                // visible text clean.
                let nsRange = match.range(at: 0)
                if let r = Range(nsRange, in: cleaned) {
                    cleaned.removeSubrange(r)
                }
                continue
            }
            let title = chapterTitle(forChapterIndex: idx)
            seen[idx] = BookChatCitation(
                chapterIndex: idx,
                title: title ?? "Chapter \(idx + 1)",
                resourceID: resource.id
            )
            // Strip the inline marker entirely — the citation
            // chips below the message body carry the click
            // target. Inlining "(see TITLE)" looked terrible
            // when Claude cited the same chapter twice in a row
            // ("…(see X)(see X)…").
            let nsRange = match.range(at: 0)
            if let r = Range(nsRange, in: cleaned) {
                cleaned.removeSubrange(r)
            }
        }
        // Tidy: collapse whitespace runs left behind by removed
        // markers (e.g. "Foucault writes  about Baudelaire"
        // collapses to a single space).
        cleaned = cleaned.replacingOccurrences(
            of: " {2,}", with: " ", options: .regularExpression
        )
        // Trim spaces immediately before punctuation that the
        // marker may have separated from its sentence.
        cleaned = cleaned.replacingOccurrences(
            of: " ([.,;:!?])", with: "$1", options: .regularExpression
        )
        let citations = Array(seen.values)
            .sorted { $0.chapterIndex < $1.chapterIndex }
        return CitationParse(cleaned: cleaned, citations: citations)
    }

    private func chapterResource(for index: Int) -> Resource? {
        guard index >= 0, index < book.spine.count else { return nil }
        return book.resourcesByID[book.spine[index]]
    }

    // MARK: - prompt

    private var systemPrompt: String {
        """
        You are a research assistant embedded in an EPUB editor. \
        The user has opened "\(bookTitle)" and is asking questions \
        about its contents.

        For each question, you'll receive a small set of paragraphs \
        retrieved from the book (the most relevant on a hybrid \
        keyword + semantic match for the question). Answer the \
        question using only the supplied text.

        When you reference a specific chapter in your answer, mark \
        the reference inline as `[chapter:N]` where N is the index \
        from the supplied chapter headers. The user's interface \
        renders these markers as clickable links to the chapter.

        If the supplied paragraphs don't contain enough information \
        to answer, say so plainly — don't guess. Quote brief \
        passages when they directly support the answer; cite their \
        chapter with `[chapter:N]`.

        Keep replies tight: a short paragraph or two is plenty for \
        most questions. The user is reading the answer in a sidebar \
        pane, not a full window.
        """
    }
}

// MARK: - Helpers

private extension AnthropicMessageResponse {
    /// Concatenate every text block in the first content piece. The
    /// chat path expects plain prose; multi-block tool-use responses
    /// don't apply.
    func firstText() -> String? {
        for block in content {
            if case .text(let str) = block { return str }
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
