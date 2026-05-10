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
    /// Retrieval scope — `.currentBook` (default) or `.library`.
    /// Per-window: switching scope on one editor doesn't affect
    /// chats running in other windows. Surfaced as a picker at the
    /// top of the chat pane.
    @Published var chatScope: ChatScope = .currentBook
    /// Library-index lifecycle and statistics. The chat pane uses
    /// this to render an "X of Y books indexed for current backend"
    /// status row when scope is `.library`.
    @Published private(set) var libraryStatus: LibraryStatus = .idle

    enum LibraryStatus: Equatable {
        case idle
        case building
        /// Ready to serve queries. `indexed` / `unindexed` /
        /// `mismatch` mirror `LibraryEmbeddingIndex.Stats`.
        case ready(indexed: Int, unindexed: Int, mismatch: Int)
        case failed(String)
    }

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
    /// Per-book chapter / section tree from `nav.xhtml`. Built
    /// during the embedding pipeline and cached in the same sidecar.
    /// Used to (a) detect structural queries ("chapter 3"), (b)
    /// label paragraph hits with their containing chapter title in
    /// the rendered context, and (c) include a TOC preamble in the
    /// system prompt.
    private var hierarchyIndex: BookHierarchyIndex?
    /// Federated index over the user's library — built lazily when
    /// the chat scope flips to `.library`. Held until scope flips
    /// back; rebuilt on the next library send so a re-indexed book
    /// joins the federation without an app restart.
    private var libraryIndex: LibraryEmbeddingIndex?
    /// Per-book paragraph cache for library scope. When a hit's
    /// sidecar entry has no cached `text`, we open the book on disk
    /// to extract the paragraph; cache the extracted list so
    /// further hits in the same book skip the unzip cost.
    private var libraryParagraphCache: [URL: [ParagraphExtractor.Item]] = [:]
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

    /// Local Ollama embedding model tag. Independent from the chat
    /// model — embedding tasks want a small dedicated embedder
    /// (`nomic-embed-text` ~ 270 MB) rather than a 20 GB chat model.
    private var ollamaEmbeddingModel: String {
        let raw = UserDefaults.standard.string(
            forKey: "humanist.chat.ollamaEmbeddingModel"
        ) ?? ""
        return raw.isEmpty ? "nomic-embed-text" : raw
    }

    /// Voyage embedding model. `voyage-3` is the strong default;
    /// `voyage-3-lite` is roughly half the cost with a smaller
    /// dimension (512 vs 1024) for users on a tight budget.
    private var voyageModel: String {
        let raw = UserDefaults.standard.string(
            forKey: "humanist.chat.voyageModel"
        ) ?? ""
        return raw.isEmpty ? "voyage-3" : raw
    }

    /// Gemini embedding model. `gemini-embedding-002` is current-
    /// best-in-class on multilingual MTEB.
    private var geminiModel: String {
        let raw = UserDefaults.standard.string(
            forKey: "humanist.chat.geminiModel"
        ) ?? ""
        return raw.isEmpty ? "gemini-embedding-002" : raw
    }

    /// Optional truncation of the Matryoshka output. 0 = full
    /// dimension (~3072 for Gemini); useful values are 768, 1536.
    /// Smaller dimensions cut sidecar storage roughly proportionally
    /// with marginal quality cost.
    private var geminiOutputDimensionality: Int? {
        let raw = UserDefaults.standard.integer(
            forKey: "humanist.chat.geminiOutputDimensionality"
        )
        return raw > 0 ? raw : nil
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
    /// already thinking. Routes to the per-book or library send
    /// path based on `chatScope`.
    func send() async {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isThinking else { return }
        input = ""
        errorMessage = nil

        let userMessage = BookChatMessage(role: .user, text: query)
        appendAndPersist(userMessage)

        switch chatScope {
        case .currentBook:
            await sendCurrentBook(query: query)
        case .library:
            await sendLibrary(query: query)
        }
    }

    /// Per-book send path: BM25 + embedding hybrid retrieval scoped
    /// to the open EPUB. Same flow R-Chat-Embeddings shipped.
    private func sendCurrentBook(query: String) async {
        if bm25Index == nil {
            bm25Index = buildBM25Index()
        }
        guard let bm25 = bm25Index else {
            isThinking = false
            return
        }

        isThinking = true
        let chosenBackend = backend
        let style = retrievalStyle
        let embeddingIndexSnapshot = embeddingIndex
        let task = Task { [weak self] in
            guard let self else { return }
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

    /// Library-scope send path: federates retrieval across every
    /// indexed book. Builds the library index lazily on first use
    /// and on backend change; resolves missing paragraph text by
    /// opening the cited book on disk (cached per-session).
    private func sendLibrary(query: String) async {
        isThinking = true
        let chosenBackend = backend
        let task = Task { [weak self] in
            guard let self else { return }
            // Build library index if not yet built (or rebuild when
            // the backend changed underneath us). Backend identity
            // includes both the choice and dimension, so the
            // library index is invalidated on either swap.
            let resolution = await self.resolveEmbeddingBackend()
            guard let backend = resolution.backend else {
                await MainActor.run {
                    self.appendAndPersist(BookChatMessage(
                        role: .assistant,
                        text: "Couldn't run library retrieval — no embedding backend available."
                    ))
                    self.isThinking = false
                    self.streamTask = nil
                }
                return
            }
            let library = await self.buildOrReuseLibraryIndex(backend: backend)
            guard library.totalParagraphCount > 0 else {
                await MainActor.run {
                    self.appendAndPersist(BookChatMessage(
                        role: .assistant,
                        text: "No books are indexed for the current backend yet. Open each book's chat pane once to build its index, or run a bulk index from the Library window."
                    ))
                    self.isThinking = false
                    self.streamTask = nil
                }
                return
            }
            // Embed the query.
            let queryVector = await self.embedQuery(query, using: backend)
            guard let queryVector else {
                await MainActor.run {
                    self.appendAndPersist(BookChatMessage(
                        role: .assistant,
                        text: "Couldn't embed the query — falling back not yet wired for library scope."
                    ))
                    self.isThinking = false
                    self.streamTask = nil
                }
                return
            }
            let hits = library.search(
                queryVector: queryVector, topK: Self.maxRetrievedParagraphs
            )
            let resolved = await self.resolveLibraryHits(hits)
            let context = self.renderLibraryContext(hits: resolved)
            let userPrompt = context + "\n\nQuestion: " + query

            switch chosenBackend {
            case .cloudHaiku, .cloudSonnet:
                await self.runLibraryCloudSend(
                    userPrompt: userPrompt,
                    allowedHits: resolved,
                    model: chosenBackend == .cloudSonnet ? .sonnet4_6 : .haiku4_5
                )
            case .localOllama:
                await self.runLibraryOllamaSend(
                    userPrompt: userPrompt, allowedHits: resolved
                )
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
        self.hierarchyIndex = nil
        startEmbeddingBuild()
    }

    // MARK: - Embedding pipeline

    /// Resolve the user's chosen embedding backend. Async because
    /// some backends (Ollama, future cloud providers) need a probe
    /// call to learn their dimension before they're usable. Returns
    /// nil only when even the NLEmbedding fallback can't be built.
    ///
    /// On a backend-specific failure (Ollama daemon down, missing
    /// model, missing key), falls back to NLEmbedding rather than
    /// failing the whole index build — the user still gets a
    /// working chat. The fallback note is folded into the
    /// `embeddingStatus` label so the chat pane can surface it.
    private func resolveEmbeddingBackend() async -> (
        backend: (any EmbeddingBackend)?,
        fallbackNote: String?
    ) {
        switch embeddingBackendChoice {
        case .appleNL:
            return (NLSentenceEmbeddingBackend(language: .english), nil)
        case .ollama:
            do {
                let backend = try await OllamaEmbeddingBackend.make(
                    model: ollamaEmbeddingModel
                )
                return (backend, nil)
            } catch {
                let note = "Ollama embedding unavailable (\(error.localizedDescription)). Using Apple NLEmbedding instead."
                return (NLSentenceEmbeddingBackend(language: .english), note)
            }
        case .voyage:
            do {
                let backend = try await VoyageEmbeddingBackend.make(
                    model: voyageModel
                )
                return (backend, nil)
            } catch {
                let note = "Voyage embedding unavailable (\(error.localizedDescription)). Using Apple NLEmbedding instead."
                return (NLSentenceEmbeddingBackend(language: .english), note)
            }
        case .gemini:
            do {
                let backend = try await GeminiEmbeddingBackend.make(
                    model: geminiModel,
                    outputDimensionality: geminiOutputDimensionality
                )
                return (backend, nil)
            } catch {
                let note = "Gemini embedding unavailable (\(error.localizedDescription)). Using Apple NLEmbedding instead."
                return (NLSentenceEmbeddingBackend(language: .english), note)
            }
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
        embeddingBuildTask = Task { [weak self] in
            guard let resolution = await self?.resolveEmbeddingBackend() else { return }
            guard let backend = resolution.backend else {
                await MainActor.run {
                    self?.embeddingStatus = .failed("No embedding backend available.")
                }
                return
            }
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
                // Refresh the hierarchy from the live nav.xhtml.
                // Cheap (regex parse + spine lookup); always re-runs
                // since structural mutations like Split/Merge could
                // have invalidated a cached tree.
                let hierarchy = BookHierarchyIndex.build(from: snapshot)
                sidecar.hierarchy = hierarchy
                store.write(sidecar, for: url)
                try Task.checkCancellation()
                await MainActor.run {
                    self?.embeddingIndex = index
                    self?.hierarchyIndex = hierarchy
                    self?.embeddingStatus = .ready
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self?.embeddingStatus = .failed(error.localizedDescription)
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

    // MARK: - Library scope

    /// One library hit with its text resolved (either from the
    /// sidecar's cached text or by opening the cited book).
    private struct ResolvedLibraryHit: Sendable {
        let epubURL: URL
        let bookTitle: String
        let chapterIdx: Int
        let paragraphIdx: Int
        let text: String
        let score: Double
    }

    /// Build or reuse the library-wide federated embedding index.
    /// Rebuilds whenever the cached index's backend doesn't match
    /// the resolved backend — happens on Settings backend change.
    private func buildOrReuseLibraryIndex(
        backend: any EmbeddingBackend
    ) async -> LibraryEmbeddingIndex {
        if let cached = libraryIndex,
           cached.backend.identifier == backend.identifier,
           cached.backend.dimension == backend.dimension {
            return cached
        }
        await MainActor.run { self.libraryStatus = .building }
        // Snapshot the catalog from the global LibraryStore. We
        // don't persist a reference because the chat view-model
        // outlives a single library snapshot and we want fresh
        // entries on every rebuild.
        let entries = await MainActor.run { LibraryStore().entries }
        let index = LibraryEmbeddingIndex.build(
            libraryEntries: entries,
            backend: backend
        )
        await MainActor.run {
            self.libraryIndex = index
            self.libraryStatus = .ready(
                indexed: index.stats.indexed,
                unindexed: index.stats.unindexed,
                mismatch: index.stats.backendMismatch
            )
        }
        return index
    }

    /// Resolve text for each hit. Uses the sidecar's cached text
    /// when present; otherwise opens the book on disk and extracts
    /// paragraphs once per session (cached per-book).
    private func resolveLibraryHits(
        _ hits: [LibraryEmbeddingIndex.Hit]
    ) async -> [ResolvedLibraryHit] {
        var out: [ResolvedLibraryHit] = []
        out.reserveCapacity(hits.count)
        for hit in hits {
            if let text = hit.text {
                out.append(ResolvedLibraryHit(
                    epubURL: hit.epubURL,
                    bookTitle: hit.bookTitle,
                    chapterIdx: hit.chapterIdx,
                    paragraphIdx: hit.paragraphIdx,
                    text: text,
                    score: hit.score
                ))
                continue
            }
            // Fallback path: open the book on disk and extract its
            // paragraphs. Cached per-book within the session so a
            // burst of hits in one book pays the unzip cost once.
            let paragraphs = await loadLibraryParagraphs(for: hit.epubURL)
            guard let paragraph = paragraphs.first(where: {
                $0.chapterIdx == hit.chapterIdx
                    && $0.paragraphIdx == hit.paragraphIdx
            }) else {
                continue
            }
            out.append(ResolvedLibraryHit(
                epubURL: hit.epubURL,
                bookTitle: hit.bookTitle,
                chapterIdx: hit.chapterIdx,
                paragraphIdx: hit.paragraphIdx,
                text: paragraph.text,
                score: hit.score
            ))
        }
        return out
    }

    /// Open the book at `url` (heavy: unzips into a temp dir) and
    /// return its extracted paragraphs. Cached per-book per-session.
    /// Errors silently → empty array; the missing-text path is
    /// non-fatal (the chat just renders less context).
    @MainActor
    private func loadLibraryParagraphs(
        for url: URL
    ) async -> [ParagraphExtractor.Item] {
        if let cached = libraryParagraphCache[url] { return cached }
        let result = await Task.detached {
            do {
                let book = try EPUBBook.open(epubURL: url)
                return ParagraphExtractor.extract(from: book)
            } catch {
                return [] as [ParagraphExtractor.Item]
            }
        }.value
        libraryParagraphCache[url] = result
        return result
    }

    /// Render the library context: paragraphs grouped by their
    /// source book, with `[book:N chapter:M]` markers so the model
    /// can cite. The book list at the top maps citation N → URL +
    /// title; the chat path's citation parser uses that to build
    /// `BookChatCitation` entries with `bookEpubURL` set.
    private func renderLibraryContext(hits: [ResolvedLibraryHit]) -> String {
        guard !hits.isEmpty else {
            return """
            (No matching paragraphs were found across the user's \
            library. Either the question doesn't match anything in \
            the indexed corpus, or no books have been indexed yet.)
            """
        }
        // Stable book ordering: first appearance order in the hits
        // list. The order doesn't affect retrieval but does affect
        // the [book:N] index the model sees.
        var bookIndex: [URL: Int] = [:]
        var orderedBooks: [(url: URL, title: String)] = []
        for hit in hits where bookIndex[hit.epubURL] == nil {
            bookIndex[hit.epubURL] = orderedBooks.count
            orderedBooks.append((url: hit.epubURL, title: hit.bookTitle))
        }
        var out = "Books in scope:\n"
        for (idx, book) in orderedBooks.enumerated() {
            out += "[book:\(idx)] \(book.title)\n"
        }
        out += "\nRelevant paragraphs:\n\n"
        for hit in hits {
            guard let bIdx = bookIndex[hit.epubURL] else { continue }
            let text = String(hit.text.prefix(Self.maxParagraphChars))
            out += "[book:\(bIdx) chapter:\(hit.chapterIdx)]\n  • \(text)\n\n"
        }
        return out
    }

    private func runLibraryCloudSend(
        userPrompt: String,
        allowedHits: [ResolvedLibraryHit],
        model: AnthropicModel
    ) async {
        defer {
            isThinking = false
            streamTask = nil
        }
        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: 1500,
            system: .cached(libraryScopeSystemPrompt, ttl: .oneHour),
            messages: [
                Message(role: .user, content: .plain(userPrompt))
            ],
            thinking: .disabled
        )
        do {
            let response = try await client.send(request)
            try Task.checkCancellation()
            let raw = response.firstText() ?? ""
            let cited = parseLibraryCitations(in: raw, allowedHits: allowedHits)
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

    private func runLibraryOllamaSend(
        userPrompt: String,
        allowedHits: [ResolvedLibraryHit]
    ) async {
        defer {
            isThinking = false
            streamTask = nil
        }
        let model = ollamaModel
        do {
            let raw = try await ollama.chat(
                model: model,
                system: libraryScopeSystemPrompt,
                userMessage: userPrompt
            )
            try Task.checkCancellation()
            let cited = parseLibraryCitations(in: raw, allowedHits: allowedHits)
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

    /// Library-scope citation parser. Recognizes `[book:N chapter:M]`
    /// markers (in addition to the legacy `[chapter:N]` form, which
    /// the model occasionally produces despite the system prompt's
    /// guidance — fall back to "current book" semantics for those).
    private func parseLibraryCitations(
        in text: String, allowedHits: [ResolvedLibraryHit]
    ) -> CitationParse {
        // Reconstruct the [book:N] → URL/title mapping from the
        // ordered list of distinct allowedHits books — same scheme
        // as renderLibraryContext.
        var bookByIndex: [Int: (url: URL, title: String)] = [:]
        var seenBooks: [URL: Int] = [:]
        for hit in allowedHits where seenBooks[hit.epubURL] == nil {
            let idx = seenBooks.count
            seenBooks[hit.epubURL] = idx
            bookByIndex[idx] = (hit.epubURL, hit.bookTitle)
        }
        let pattern = "\\[book:(\\d+)\\s+chapter:(\\d+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return CitationParse(cleaned: text, citations: [])
        }
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        var cleaned = text
        var seen: [String: BookChatCitation] = [:]
        for match in matches.reversed() {
            guard match.numberOfRanges == 3 else { continue }
            let bookRaw = nsText.substring(with: match.range(at: 1))
            let chapterRaw = nsText.substring(with: match.range(at: 2))
            guard let bookIdx = Int(bookRaw),
                  let chapterIdx = Int(chapterRaw),
                  let bookEntry = bookByIndex[bookIdx]
            else {
                let nsRange = match.range(at: 0)
                if let r = Range(nsRange, in: cleaned) {
                    cleaned.removeSubrange(r)
                }
                continue
            }
            let key = "\(bookIdx)#\(chapterIdx)"
            if seen[key] == nil {
                seen[key] = BookChatCitation(
                    chapterIndex: chapterIdx,
                    title: bookEntry.title,
                    resourceID: "",  // unknown without opening the book
                    bookEpubURL: bookEntry.url,
                    bookTitle: bookEntry.title
                )
            }
            let nsRange = match.range(at: 0)
            if let r = Range(nsRange, in: cleaned) {
                cleaned.removeSubrange(r)
            }
        }
        cleaned = cleaned.replacingOccurrences(
            of: " {2,}", with: " ", options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: " ([.,;:!?])", with: "$1", options: .regularExpression
        )
        let citations = Array(seen.values)
            .sorted { lhs, rhs in
                if lhs.bookTitle ?? "" != rhs.bookTitle ?? "" {
                    return (lhs.bookTitle ?? "") < (rhs.bookTitle ?? "")
                }
                return lhs.chapterIndex < rhs.chapterIndex
            }
        return CitationParse(cleaned: cleaned, citations: citations)
    }

    /// System prompt used in library scope. Differs from the per-
    /// book prompt in that the model is told to cite `[book:N
    /// chapter:M]` and to compare across books when the question
    /// invites it.
    private var libraryScopeSystemPrompt: String {
        """
        You are a research assistant embedded in an EPUB editor. \
        The user has multiple books open across their library and \
        is asking a question that may span more than one of them.

        For each question, you'll receive a small set of paragraphs \
        retrieved from across the user's library (the most relevant \
        on a hybrid keyword + semantic match for the question), \
        prefixed with a list of the source books. Each paragraph is \
        labeled `[book:N chapter:M]` where N indexes into the books \
        list and M indexes into that book's spine.

        When you reference a source in your answer, cite it inline \
        as `[book:N chapter:M]` using the same indices. The user's \
        interface renders these markers as clickable links that \
        open the cited book in a new editor window at the cited \
        chapter.

        Compare across books when the question invites it; quote \
        brief passages with their citation when they directly \
        support the answer. If the supplied paragraphs don't \
        contain enough information to answer, say so plainly — \
        don't guess.

        Keep replies tight: a short paragraph or two is usually \
        enough.
        """
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
        let base = """
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
        guard let preamble = tocPreamble() else { return base }
        return base + "\n\n" + preamble
    }

    /// Compact table of contents the model sees as part of the
    /// system prompt. Lets it reason about structural references
    /// ("the chapter on heterotopia," "what does Part Two cover")
    /// even when retrieval surfaces paragraphs from elsewhere.
    /// Capped at ~80 entries to keep token cost bounded; very long
    /// books (encyclopedia-style) summarize to top-level chapters.
    private func tocPreamble() -> String? {
        guard let hierarchy = hierarchyIndex, !hierarchy.nodes.isEmpty else {
            return nil
        }
        var lines: [String] = []
        lines.reserveCapacity(80)
        var emitted = 0
        for node in hierarchy.nodes where emitted < 80 {
            let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let prefix = "[chapter:\(node.chapterIdx)]"
            lines.append("- \(prefix) \(title)")
            emitted += 1
            // Include up to 4 sub-section titles per chapter so the
            // model sees the structural detail without ballooning.
            for child in node.children.prefix(4) where emitted < 80 {
                let childTitle = child.title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !childTitle.isEmpty else { continue }
                lines.append("  - \(childTitle)")
                emitted += 1
            }
        }
        guard !lines.isEmpty else { return nil }
        let body = lines.joined(separator: "\n")
        return """
        Table of contents (use this to interpret structural \
        references like "chapter 3" or "the introduction"):
        \(body)
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
