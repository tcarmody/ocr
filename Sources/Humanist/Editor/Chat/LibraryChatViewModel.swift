import Foundation
import AI
import EPUB

/// Chat session scoped to the entire library — sibling of
/// `BookChatViewModel` for the case where the user wants to query
/// the corpus without picking an anchor book first. Lives on the
/// library window; persists its transcript independently from the
/// per-book transcripts so the conversations don't interleave.
///
/// Reuses the heavy infrastructure that `R-Chat-Embeddings` and
/// `R-Chat-Graph-Lite` introduced — `LibraryEmbeddingIndex`,
/// `LibraryEntityIndex`, the alias dictionary, the cloud / Ollama
/// clients, the citation parser. Skips per-book concerns: no
/// hierarchy preamble (no single book to TOC), no scope picker (the
/// scope is always library), no embedding-build banner (the
/// retrieval index reads from already-built sidecars).
@MainActor
final class LibraryChatViewModel: ObservableObject {
    @Published private(set) var messages: [BookChatMessage] = []
    @Published var input: String = ""
    @Published private(set) var isThinking: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var libraryStatus: LibraryStatus = .idle
    /// Surfaced when retrieval fell back from the user-selected
    /// embedding backend to NLEmbedding (e.g. the Ollama daemon
    /// isn't running, the Voyage key was rotated, the network's
    /// out). Cleared on the next successful send.
    @Published private(set) var fallbackNote: String?
    /// Long-form synthesis mode — see the per-book chat VM for the
    /// full doc-comment. Library scope is where this matters most:
    /// "summarize what my library says about heterotopia" naturally
    /// wants more than a tight paragraph.
    @Published var useLongFormSynthesis: Bool = false
    /// Optional retrieval restriction. When non-nil, library
    /// search and entity matches both filter to the URLs in this
    /// set so the answer comes from just the selected books.
    /// Driven by the Library window's "Chat with Selected" action;
    /// nil = whole library (the federated default).
    @Published private(set) var scopedURLs: Set<URL>?
    /// Display titles for the scoped books, in selection order.
    /// Surfaced in the chat pane's status row so the user sees
    /// which books are participating without opening the picker.
    @Published private(set) var scopedTitles: [String] = []
    /// Books the user excluded mid-conversation via the citation
    /// chip's context menu. Applied to retrieval as a deny-list
    /// (after any active scope's allow-list). Stays scoped to the
    /// session — clearing the chat or app-restart resets.
    @Published private(set) var excludedBookURLs: Set<URL> = []
    /// Display titles for excluded books, parallel to
    /// `excludedBookURLs`. Used to render "Excluded N: X, Y" in
    /// the status banner.
    @Published private(set) var excludedBookTitles: [URL: String] = [:]

    enum LibraryStatus: Equatable {
        case idle
        case building
        case ready(indexed: Int, unindexed: Int, mismatch: Int)
        case failed(String)
    }

    /// Same backend-choice machinery as the per-book chat path —
    /// the user's Settings choice drives both surfaces.
    private var backend: ChatBackend {
        if let raw = UserDefaults.standard.string(forKey: "humanist.chat.backend"),
           let b = ChatBackend(rawValue: raw) {
            return b
        }
        return UserDefaults.standard.bool(forKey: "humanist.chat.useSonnet")
            ? .cloudSonnet : .cloudHaiku
    }

    private var ollamaModel: String {
        let raw = UserDefaults.standard.string(forKey: "humanist.chat.ollamaModel")
            ?? ""
        return raw.isEmpty ? "gemma4:26b" : raw
    }

    private var ollamaEmbeddingModel: String {
        let raw = UserDefaults.standard.string(
            forKey: "humanist.chat.ollamaEmbeddingModel"
        ) ?? ""
        return raw.isEmpty ? "nomic-embed-text" : raw
    }

    private var voyageModel: String {
        let raw = UserDefaults.standard.string(
            forKey: "humanist.chat.voyageModel"
        ) ?? ""
        return raw.isEmpty ? "voyage-3" : raw
    }

    private var geminiModel: String {
        let raw = UserDefaults.standard.string(
            forKey: "humanist.chat.geminiModel"
        ) ?? ""
        // Treat the legacy `-002` default as a synonym for the GA
        // `-2`; mirrors the BookChatViewModel migration logic.
        if raw.isEmpty || raw == "gemini-embedding-002" {
            return "gemini-embedding-2"
        }
        return raw
    }

    private var geminiOutputDimensionality: Int? {
        let raw = UserDefaults.standard.integer(
            forKey: "humanist.chat.geminiOutputDimensionality"
        )
        return raw > 0 ? raw : nil
    }

    private var embeddingBackendChoice: EmbeddingBackendChoice {
        let raw = UserDefaults.standard.string(
            forKey: EmbeddingBackendChoice.userDefaultsKey
        ) ?? EmbeddingBackendChoice.appleNL.rawValue
        return EmbeddingBackendChoice(rawValue: raw) ?? .appleNL
    }

    private var useEntityRetrieval: Bool {
        UserDefaults.standard.object(
            forKey: "humanist.chat.useEntityRetrieval"
        ) as? Bool ?? true
    }

    private let client: AnthropicAPIClient
    private let ollama: OllamaClient
    private let transcriptURL: URL

    /// Live library reference passed in by the Library window after
    /// init. The VM uses this for catalog snapshots during the
    /// federated-index build path; without it, the build path would
    /// have to allocate a fresh `LibraryStore()` per send, which
    /// runs the full `load()` (JSON decode + 2k `fileExists` calls
    /// + relativePath rewrites) synchronously on the main thread —
    /// several seconds per chat send for an iCloud catalog. With a
    /// live reference, catalog access is free. Optional so unit
    /// tests / non-Library-window callers still work.
    weak var library: LibraryStore?

    private var libraryIndex: LibraryEmbeddingIndex?
    private var libraryEntityIndex: LibraryEntityIndex?
    private var streamTask: Task<Void, Never>?
    /// Same `nonisolated(unsafe)` justification as the per-book
    /// chat VM: the observer token is opaque, deinit-only, and
    /// has no reachable race.
    private nonisolated(unsafe) var backendChangeObserver: (any NSObjectProtocol)?

    /// Top-K paragraphs returned by retrieval. User-tunable via
    /// Settings → AI → Advanced; default 12.
    private var maxRetrievedParagraphs: Int {
        let raw = UserDefaults.standard.integer(forKey: "humanist.chat.topK")
        return raw > 0 ? raw : 12
    }
    /// Per-paragraph character cap. User-tunable; default 4000.
    private var maxParagraphChars: Int {
        let raw = UserDefaults.standard.integer(forKey: "humanist.chat.maxParaChars")
        return raw > 0 ? raw : 4_000
    }
    /// RRF constant. User-tunable; default 60.
    private var rrfK: Double {
        let raw = UserDefaults.standard.integer(forKey: "humanist.chat.rrfK")
        return raw > 0 ? Double(raw) : HybridRetriever.defaultRRFK
    }

    init(transcriptURL: URL? = nil) {
        let keyStore = AnthropicAPIKeyStore()
        self.client = AnthropicAPIClient(
            apiKeyProvider: { keyStore.read() }
        )
        self.ollama = OllamaClient()
        self.transcriptURL = transcriptURL ?? Self.defaultTranscriptURL()
        self.messages = Self.loadTranscript(from: self.transcriptURL)
        // Drop the federated index when the user changes their
        // embedding backend in Settings — same posture as the
        // per-book chat VMs.
        self.backendChangeObserver = NotificationCenter.default
            .addObserver(
                forName: .humanistEmbeddingBackendChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.invalidateLibraryIndex() }
            }
    }

    deinit {
        streamTask?.cancel()
        if let observer = backendChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Transcript persistence

    /// Library-chat transcript file. Sibling to the per-book
    /// transcripts under `~/Library/Application Support/Humanist/Chats/`,
    /// but with a fixed `library.json` filename rather than a
    /// per-book hash — the library has one chat, not per-book.
    private static func defaultTranscriptURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = support
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("Chats", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir.appendingPathComponent("library.json")
    }

    private static func loadTranscript(from url: URL) -> [BookChatMessage] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? Self.decoder.decode(Payload.self, from: data)
        else { return [] }
        return payload.messages.sorted { $0.createdAt < $1.createdAt }
    }

    private func persistTranscript() {
        let payload = Payload(version: 1, messages: messages)
        guard let data = try? Self.encoder.encode(payload) else { return }
        try? data.write(to: transcriptURL, options: .atomic)
    }

    private struct Payload: Codable {
        let version: Int
        let messages: [BookChatMessage]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Send path

    func send() async {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isThinking else { return }
        // Refuse to send while the vector index is being mutated.
        // Reading sidecars concurrently with a writer gives garbage
        // results (mismatched dimensions, partial JSON, missing
        // entries that were just added), and the writer's per-book
        // publish storm thrashes the view tree at the same time.
        // The chat pane surfaces this via the coordinator's banner
        // separately — this guard is the last line of defense.
        if !VectorIndexCoordinator.shared.isStable {
            let desc = VectorIndexCoordinator.shared.activeDescription
                ?? "Library indexing is in progress"
            errorMessage = "\(desc) — wait for it to finish before sending."
            return
        }
        input = ""
        errorMessage = nil
        fallbackNote = nil
        appendAndPersist(BookChatMessage(role: .user, text: query))

        isThinking = true
        let chosenBackend = backend
        let task = Task { [weak self] in
            guard let self else { return }
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
            if let note = resolution.fallbackNote {
                await MainActor.run { self.fallbackNote = note }
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
            let queryVector = await self.embedQuery(query, using: backend)
            guard let queryVector else {
                await MainActor.run {
                    self.appendAndPersist(BookChatMessage(
                        role: .assistant,
                        text: "Couldn't embed the query. Try again or switch backends in Settings → AI."
                    ))
                    self.isThinking = false
                    self.streamTask = nil
                }
                return
            }
            // Entity + alias boosts. Same gating as the per-book
            // path — when the user disables entity retrieval in
            // Settings, both NER hits and aliases skip.
            let useEntity = await MainActor.run { self.useEntityRetrieval }
            let entityIndex = await MainActor.run { self.libraryEntityIndex }
            var entityAnchors = useEntity
                ? self.computeLibraryEntityAnchors(
                    query: query, entities: entityIndex
                  )
                : []
            let aliases = useEntity
                ? AliasDictionaryStore().read()
                : .empty
            entityAnchors.append(contentsOf: self.computeLibraryAliasAnchors(
                query: query, library: library, aliases: aliases
            ))
            let topK = await MainActor.run { self.maxRetrievedParagraphs }
            let rrfK = await MainActor.run { self.rrfK }
            let scope = await MainActor.run { self.scopedURLs }
            let excluded = await MainActor.run { self.excludedBookURLs }
            // Filter entity anchors against the same scope + deny-
            // list combination the cosine search uses, otherwise
            // the federated entity index would pull in anchors
            // outside the effective participating-books set.
            let allowedSourcePaths: Set<String>? = scope.map { urls in
                Set(urls.map {
                    $0.canonicalForFile.standardizedFileURL.path
                })
            }
            let excludedSourcePaths: Set<String> = Set(excluded.map {
                $0.canonicalForFile.standardizedFileURL.path
            })
            let filteredEntityAnchors = entityAnchors.filter { anchor in
                let p = anchor.epubURL
                    .canonicalForFile.standardizedFileURL.path
                if let allowedSourcePaths, !allowedSourcePaths.contains(p) {
                    return false
                }
                return !excludedSourcePaths.contains(p)
            }
            let hits = library.search(
                queryVector: queryVector,
                topK: topK,
                entityMatches: filteredEntityAnchors,
                rrfK: rrfK,
                restrictTo: scope,
                excluding: excluded
            )
            let context = self.renderLibraryContext(hits: hits)
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

    /// Wipe the transcript. Doesn't touch the federated index —
    /// rebuilding it is much cheaper than rebuilding per-book
    /// embedding indexes (it's just a sidecar read pass).
    func clear() {
        streamTask?.cancel()
        messages.removeAll()
        errorMessage = nil
        fallbackNote = nil
        try? FileManager.default.removeItem(at: transcriptURL)
    }

    // MARK: - Backend resolution + library index

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

    private func buildOrReuseLibraryIndex(
        backend: any EmbeddingBackend
    ) async -> LibraryEmbeddingIndex {
        if let cached = libraryIndex,
           cached.backend.identifier == backend.identifier,
           cached.backend.dimension == backend.dimension {
            return cached
        }
        libraryStatus = .building
        // Snapshot entries from the live LibraryStore (zero-cost
        // — just a published array read), then run the heavy
        // per-book sidecar disk-IO on a detached task. Both
        // `LibraryEmbeddingIndex.build` and `LibraryEntityIndex
        // .build` do per-book sidecar JSON reads — at library
        // scale (2k+ books) that's gigabytes of synchronous IO;
        // doing it on the main thread freezes the UI for ~30s and
        // trips a hang report. Detached task hops to the
        // cooperative thread pool so the UI keeps rendering;
        // results hop back to MainActor for the state writes
        // (compiler-enforced via @MainActor on self).
        //
        // Falls back to a fresh LibraryStore() when no live
        // reference is attached (unit tests / standalone usage).
        // That fallback path does pay the load() cost on main —
        // acceptable for tests; the Library window always wires
        // the live reference so the production path is free.
        let entries = (library?.entries) ?? LibraryStore().entries
        let (index, entityIndex) = await Task.detached(priority: .userInitiated) {
            let idx = LibraryEmbeddingIndex.build(
                libraryEntries: entries, backend: backend
            )
            let entityIdx = LibraryEntityIndex.build(libraryEntries: entries)
            return (idx, entityIdx)
        }.value
        libraryIndex = index
        libraryEntityIndex = entityIndex
        libraryStatus = .ready(
            indexed: index.stats.indexed,
            unindexed: index.stats.unindexed,
            mismatch: index.stats.backendMismatch
        )
        return index
    }

    /// Force a fresh library-index rebuild on the next send.
    /// Surfaced via the chat pane so the user can pick up
    /// newly-indexed books without quitting the app.
    func invalidateLibraryIndex() {
        libraryIndex = nil
        libraryEntityIndex = nil
        libraryStatus = .idle
    }

    /// Restrict retrieval to a subset of the library — used by the
    /// Library window's "Chat with Selected" action. `urls` is the
    /// canonical EPUB URL set; `titles` are the display labels for
    /// the chat-pane status row. Pass `nil` / empty to reset to
    /// the whole library.
    func setScope(urls: Set<URL>?, titles: [String]) {
        if let urls, !urls.isEmpty {
            scopedURLs = urls
            scopedTitles = titles
        } else {
            scopedURLs = nil
            scopedTitles = []
        }
    }

    /// Reset retrieval scope to the whole library. Surfaced as a
    /// "Clear" affordance in the chat pane's status row when a
    /// scope is active.
    func clearScope() {
        scopedURLs = nil
        scopedTitles = []
    }

    /// Add a book to the deny-list for the rest of this chat
    /// session. Library retrieval skips it on subsequent sends.
    /// Idempotent — adding the same book twice is a no-op.
    func excludeBook(url: URL, title: String) {
        excludedBookURLs.insert(url)
        excludedBookTitles[url] = title
    }

    /// Drop every exclusion. Surfaced as the "Clear" button next
    /// to the exclusion banner in the chat pane.
    func clearExclusions() {
        excludedBookURLs.removeAll()
        excludedBookTitles.removeAll()
    }

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

    // MARK: - Entity / alias boosts (library scope)

    private func computeLibraryEntityAnchors(
        query: String,
        entities: LibraryEntityIndex?
    ) -> [LibraryEntityIndex.LibraryAnchor] {
        guard let entities else { return [] }
        let matched = entities.entitiesMatching(query: query)
        guard !matched.isEmpty else { return [] }
        var out: [LibraryEntityIndex.LibraryAnchor] = []
        let perEntityCap = 200
        let totalCap = 1500
        for canonical in matched {
            for anchor in entities.anchors(for: canonical).prefix(perEntityCap) {
                out.append(anchor)
                if out.count >= totalCap { return out }
            }
        }
        return out
    }

    private func computeLibraryAliasAnchors(
        query: String,
        library: LibraryEmbeddingIndex,
        aliases: AliasDictionary
    ) -> [LibraryEntityIndex.LibraryAnchor] {
        guard !aliases.terms.isEmpty else { return [] }
        let queryLowered = query.lowercased()
        let matched = aliases.terms.filter { queryLowered.contains($0) }
        guard !matched.isEmpty else { return [] }
        var anchors: [LibraryEntityIndex.LibraryAnchor] = []
        let perAliasCap = 200
        let totalCap = 1500
        for source in library.sources {
            for entry in source.paragraphs {
                guard let text = entry.text else { continue }
                let textLowered = text.lowercased()
                for term in matched where textLowered.contains(term) {
                    anchors.append(LibraryEntityIndex.LibraryAnchor(
                        epubURL: source.epubURL,
                        bookTitle: source.bookTitle,
                        chapterIdx: entry.chapterIdx,
                        paragraphIdx: entry.paragraphIdx
                    ))
                    if anchors.count >= totalCap { return anchors }
                    break
                }
            }
            if anchors.count >= perAliasCap * matched.count { break }
        }
        return anchors
    }

    // MARK: - Rendering + sending

    private func renderLibraryContext(hits: [LibraryEmbeddingIndex.Hit]) -> String {
        guard !hits.isEmpty else {
            return """
            (No matching paragraphs were found across the user's \
            library. Either the question doesn't match anything in \
            the indexed corpus, or no books have been indexed yet.)
            """
        }
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
            let text = (hit.text ?? "")
                .prefix(maxParagraphChars)
            out += "[book:\(bIdx) chapter:\(hit.chapterIdx) para:\(hit.paragraphIdx)]\n  • \(text)\n\n"
        }
        return out
    }

    private func runCloudSend(
        userPrompt: String,
        allowedHits: [LibraryEmbeddingIndex.Hit],
        model: AnthropicModel
    ) async {
        defer {
            isThinking = false
            streamTask = nil
        }
        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: useLongFormSynthesis ? 2500 : 1500,
            system: .cached(systemPrompt, ttl: .oneHour),
            messages: [Message(role: .user, content: .plain(userPrompt))],
            thinking: .disabled
        )
        do {
            let response = try await client.send(request)
            try Task.checkCancellation()
            let raw = response.firstText() ?? ""
            let cited = parseCitations(
                in: raw, allowedHits: allowedHits
            )
            appendAndPersist(BookChatMessage(
                role: .assistant,
                text: cited.cleaned,
                citations: cited.citations,
                retrievalDetail: Self.makeRetrievalDetail(hits: allowedHits),
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
        allowedHits: [LibraryEmbeddingIndex.Hit]
    ) async {
        defer {
            isThinking = false
            streamTask = nil
        }
        do {
            let raw = try await ollama.chat(
                model: ollamaModel,
                system: systemPrompt,
                userMessage: userPrompt
            )
            try Task.checkCancellation()
            let cited = parseCitations(
                in: raw, allowedHits: allowedHits
            )
            appendAndPersist(BookChatMessage(
                role: .assistant,
                text: cited.cleaned,
                citations: cited.citations,
                retrievalDetail: Self.makeRetrievalDetail(hits: allowedHits),
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

    /// Project library hits into the persisted retrieval-debug
    /// shape. The library scope's hits don't carry BM25 / hierarchy
    /// / entity rank info on the underlying type — the federated
    /// retriever fuses cosine + entity boost only — so those
    /// fields stay nil / false.
    private static func makeRetrievalDetail(
        hits: [LibraryEmbeddingIndex.Hit]
    ) -> RetrievalDetail {
        let entries: [RetrievalDetail.Hit] = hits.map {
            RetrievalDetail.Hit(
                chapterIdx: $0.chapterIdx,
                paragraphIdx: $0.paragraphIdx,
                bookTitle: $0.bookTitle,
                score: $0.score,
                bm25Rank: nil,
                embeddingRank: nil,
                hierarchyMatched: false,
                entityMatched: false
            )
        }
        return RetrievalDetail(hits: entries)
    }

    private func appendAndPersist(_ message: BookChatMessage) {
        messages.append(message)
        persistTranscript()
    }

    /// Library-citation parser — recognizes `[book:N chapter:M]`
    /// markers and projects each back to the source book via the
    /// `allowedHits` ordering (first-appearance-order book index).
    private func parseCitations(
        in text: String,
        allowedHits: [LibraryEmbeddingIndex.Hit]
    ) -> CitationParse {
        var bookByIndex: [Int: (url: URL, title: String)] = [:]
        var seenBooks: [URL: Int] = [:]
        for hit in allowedHits where seenBooks[hit.epubURL] == nil {
            let idx = seenBooks.count
            seenBooks[hit.epubURL] = idx
            bookByIndex[idx] = (hit.epubURL, hit.bookTitle)
        }
        // Match `[book:N chapter:M]` and `[book:N chapter:M para:K]`
        // in one pass; paragraph segment is optional. Group 3 is
        // the paragraph index when present.
        let pattern = "\\[book:(\\d+)\\s+chapter:(\\d+)(?:\\s+para:(\\d+))?\\]"
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
            guard match.numberOfRanges == 4 else { continue }
            let bookRaw = nsText.substring(with: match.range(at: 1))
            let chapterRaw = nsText.substring(with: match.range(at: 2))
            let paragraphRaw: String? = {
                let r = match.range(at: 3)
                return r.location == NSNotFound
                    ? nil
                    : nsText.substring(with: r)
            }()
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
            let paraIdx: Int? = paragraphRaw.flatMap(Int.init)
            let key = "\(bookIdx)#\(chapterIdx)#\(paraIdx.map(String.init) ?? "-")"
            if seen[key] == nil {
                seen[key] = BookChatCitation(
                    chapterIndex: chapterIdx,
                    title: bookEntry.title,
                    resourceID: "",
                    bookEpubURL: bookEntry.url,
                    bookTitle: bookEntry.title,
                    paragraphIndex: paraIdx
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
                if (lhs.bookTitle ?? "") != (rhs.bookTitle ?? "") {
                    return (lhs.bookTitle ?? "") < (rhs.bookTitle ?? "")
                }
                if lhs.chapterIndex != rhs.chapterIndex {
                    return lhs.chapterIndex < rhs.chapterIndex
                }
                return (lhs.paragraphIndex ?? -1) < (rhs.paragraphIndex ?? -1)
            }
        return CitationParse(cleaned: cleaned, citations: citations)
    }

    private struct CitationParse {
        let cleaned: String
        let citations: [BookChatCitation]
    }

    private var systemPrompt: String {
        """
        You are a research assistant scoped to a personal library of \
        books. The user is asking a corpus-wide question and you'll \
        receive a small set of paragraphs retrieved from across that \
        library, prefixed with a list of source books. Each paragraph \
        is labeled `[book:N chapter:M para:K]` where N indexes into \
        the books list, M indexes into that book's spine, and K is \
        the paragraph within the chapter.

        Cite sources inline using the same marker form. The user's \
        interface renders these as clickable links that open the \
        cited book in a new editor window. Use the full \
        `[book:N chapter:M para:K]` marker when the claim comes \
        from a specific paragraph; the shorter `[book:N chapter:M]` \
        form is fine for whole-chapter references.

        Compare across books when the question invites it; quote \
        brief passages with their citation when they directly support \
        the answer. If the supplied paragraphs don't contain enough \
        information, say so — don't guess.

        \(lengthGuidance)
        """
    }

    /// Per-book chat VM has the canonical doc-comment; same idea
    /// here. Swap between chat-paragraph default and essay-shaped
    /// long-form depending on the user's toggle. Follow-up
    /// suggestions ride along in either mode.
    private var lengthGuidance: String {
        let length: String
        if useLongFormSynthesis {
            length = """
            The user has requested a longer-form answer. Take a \
            few well-developed paragraphs (4-6 paragraphs is the \
            target) — enough room to compare across books and \
            quote the strongest passages with citations, but still \
            readable in a sidebar pane. Don't pad; if the question \
            only needs a short answer, give a short answer.
            """
        } else {
            length = "Keep replies tight: a paragraph or two is usually enough."
        }
        return length
    }
}

// MARK: - Helpers

private extension AnthropicMessageResponse {
    func firstText() -> String? {
        for block in content {
            if case .text(let str) = block { return str }
        }
        return nil
    }
}
