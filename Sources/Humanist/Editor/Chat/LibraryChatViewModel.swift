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
    /// Per-book BM25 over title + author + section headings. Built
    /// in-memory each session alongside the federated embedding
    /// index — not persisted (the underlying inputs are catalog
    /// metadata + the existing sidecar's hierarchy; building from
    /// them is sub-second even at 2k+ books).
    private var libraryKeywordIndex: LibraryKeywordIndex?
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
    /// Max turns of history forwarded to the model. User-tunable;
    /// default 10. Set to 0 for unbounded (escape hatch). The cap
    /// keeps both cloud token cost and context-window pressure in
    /// check on long-running sessions — see `trimChatHistory` for
    /// the full rationale.
    private var maxHistoryTurns: Int {
        let stored = UserDefaults.standard
            .object(forKey: "humanist.chat.maxHistoryTurns") as? Int
        return stored ?? 10
    }
    /// Max iterations of tool calls the model can issue per user
    /// turn before we force a final answer. Each iteration is an
    /// extra round-trip; without a cap, a confused model could
    /// loop on `search_library` forever. Default 3 (initial
    /// retrieval + up to 3 model-issued searches = generous).
    /// Set to 0 to disable tool use entirely (model gets only the
    /// initial implicit context, same as before this feature).
    private var agenticMaxIterations: Int {
        let stored = UserDefaults.standard
            .object(forKey: "humanist.chat.agenticMaxIterations") as? Int
        return stored ?? 3
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
            // Use the most recent prior user turn as conversational
            // context for the embedding. Without this, a short
            // follow-up like "what about Lacan's own texts?" embeds
            // against ~5 words and cosine search surfaces off-topic
            // paragraphs. Entity / alias matching stays on the bare
            // current query — those are intentionally precise to
            // what the user just asked.
            let priorUserQuery = self.messages.dropLast().reversed()
                .first(where: { $0.role == .user })?.text
            let queryForEmbedding: String = priorUserQuery
                .map { "\($0)\n\n\(query)" } ?? query
            let queryVector = await self.embedQuery(
                queryForEmbedding, using: backend
            )
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
            let useEntity = self.useEntityRetrieval
            let entityIndex = self.libraryEntityIndex
            let keywordIndex = self.libraryKeywordIndex
            let topK = self.maxRetrievedParagraphs
            let rrfK = self.rrfK
            let scope = self.scopedURLs
            let excluded = self.excludedBookURLs
            let maxParaChars = self.maxParagraphChars
            // Heavy retrieval — brute-force cosine across every
            // paragraph in every source, plus entity + alias scans
            // that walk every paragraph. Both are O(library) and
            // dominate the wall time on big libraries. Push them
            // off the main actor so the UI stays live; without this
            // the @MainActor Task inherits actor isolation and the
            // search blocks the event loop for the whole pass.
            let aliases: AliasDictionary = useEntity
                ? AliasDictionaryStore().read()
                : .empty
            let hits = await Task.detached(priority: .userInitiated) {
                () -> [LibraryEmbeddingIndex.Hit] in
                var entityAnchors = useEntity
                    ? Self.computeLibraryEntityAnchors(
                        query: query, entities: entityIndex
                      )
                    : []
                entityAnchors.append(contentsOf: Self.computeLibraryAliasAnchors(
                    query: query, library: library, aliases: aliases
                ))
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
                let filtered = entityAnchors.filter { anchor in
                    let p = anchor.epubURL
                        .canonicalForFile.standardizedFileURL.path
                    if let allowedSourcePaths, !allowedSourcePaths.contains(p) {
                        return false
                    }
                    return !excludedSourcePaths.contains(p)
                }
                // BM25 over per-book metadata (title + author +
                // section headings). Surfaces books that match the
                // query on the title/author/headings axis but didn't
                // happen to score high on cosine — the textbook case
                // is an author-name query.
                let keywordHits = keywordIndex?.search(query: query, topK: 20) ?? []
                return library.search(
                    queryVector: queryVector,
                    topK: topK,
                    entityMatches: filtered,
                    keywordHits: keywordHits,
                    rrfK: rrfK,
                    restrictTo: scope,
                    excluding: excluded
                )
            }.value
            // Build a per-turn registry so `[book:N]` indices stay
            // consistent across the initial context AND any later
            // tool-result renders. The Ollama path doesn't use tools
            // yet — registry-rendering still works fine for it,
            // there just won't be any subsequent renders.
            let registry = LibraryChatTools.TurnBookRegistry()
            let context = LibraryChatTools.renderInitialContext(
                hits: hits, registry: registry, maxParaChars: maxParaChars
            )
            let userPrompt = context + "\n\nQuestion: " + query

            switch chosenBackend {
            case .cloudHaiku, .cloudSonnet:
                await self.runCloudSendAgentic(
                    userPrompt: userPrompt,
                    initialHits: hits,
                    registry: registry,
                    library: library,
                    backend: backend,
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
        let backendID = backend.identifier
        let backendDim = backend.dimension

        // Disk-cache fast path: fingerprint the catalog (stat-only,
        // no sidecar bytes read) and try to load a matching snapshot
        // off `FederatedIndexCache.defaultCacheURL`. A hit
        // re-hydrates the same `(LibraryEmbeddingIndex,
        // LibraryEntityIndex)` shape the slow path produces, without
        // re-walking every sidecar.
        let detached = await Task.detached(
            priority: .userInitiated
        ) { () -> (
            LibraryEmbeddingIndex,
            LibraryEntityIndex,
            LibraryKeywordIndex,
            String,
            Bool
        ) in
            let fingerprint = FederatedIndexCache.fingerprint(
                backendIdentifier: backendID,
                dimension: backendDim,
                entries: entries
            )
            // Per-book BM25 is built off the catalog + each book's
            // hierarchy sidecar. Always rebuilt in-memory — cheap
            // (sub-second at 2k books), and decoupling from the
            // on-disk federated cache means existing v2 caches stay
            // valid without a format bump.
            let keywordIdx = LibraryKeywordIndex(libraryEntries: entries)
            if let payload = FederatedIndexCache.load(
                expectedFingerprint: fingerprint,
                backendIdentifier: backendID,
                dimension: backendDim
            ) {
                let idx = LibraryEmbeddingIndex(
                    sources: payload.sources,
                    backend: backend,
                    stats: payload.stats
                )
                return (idx, payload.entityIndex, keywordIdx, fingerprint, true)
            }
            let idx = LibraryEmbeddingIndex.build(
                libraryEntries: entries, backend: backend
            )
            let entityIdx = LibraryEntityIndex.build(libraryEntries: entries)
            // Side-effect: write a fresh cache. Fire-and-forget at
            // utility priority — if the save fails the next send
            // just rebuilds, no user-visible breakage.
            let snapshot = FederatedIndexCache.Payload(
                backendIdentifier: backendID,
                dimension: backendDim,
                fingerprint: fingerprint,
                stats: idx.stats,
                sources: idx.sources,
                entityIndex: entityIdx
            )
            Task.detached(priority: .utility) {
                FederatedIndexCache.save(snapshot)
            }
            return (idx, entityIdx, keywordIdx, fingerprint, false)
        }.value

        let (index, entityIndex, keywordIndex, _, _) = detached
        libraryIndex = index
        libraryEntityIndex = entityIndex
        libraryKeywordIndex = keywordIndex
        libraryStatus = .ready(
            indexed: index.stats.indexed,
            unindexed: index.stats.unindexed,
            mismatch: index.stats.backendMismatch
        )
        return index
    }

    /// Force a fresh library-index rebuild on the next send.
    /// Surfaced via the chat pane so the user can pick up
    /// newly-indexed books without quitting the app. Wipes both
    /// the in-memory cache and the on-disk snapshot — the latter
    /// would otherwise re-hydrate the same stale shape on next
    /// send and defeat the user's explicit "rebuild" intent.
    func invalidateLibraryIndex() {
        libraryIndex = nil
        libraryEntityIndex = nil
        libraryKeywordIndex = nil
        libraryStatus = .idle
        FederatedIndexCache.invalidate()
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

    /// `nonisolated static` so the off-main retrieval block in
    /// `send()` can call it without hopping back to MainActor.
    /// Reads only its parameters — no instance state.
    private nonisolated static func computeLibraryEntityAnchors(
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

    /// `nonisolated static` for the same reason as
    /// `computeLibraryEntityAnchors` — walks every paragraph in
    /// every source, so it MUST run off the main actor on large
    /// libraries.
    private nonisolated static func computeLibraryAliasAnchors(
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

    // MARK: - Sending

    /// Cloud send with tool use enabled. Issues an initial request
    /// with `search_library` in the tools list, then dispatches any
    /// `tool_use` blocks the model emits and loops until either the
    /// model returns text-only or `agenticMaxIterations` is hit.
    ///
    /// Non-streaming for v1 — Anthropic's streaming-with-tool-use
    /// surface interleaves block kinds and needs more parser
    /// surgery; landing the agentic loop without that complexity
    /// first lets us validate the retrieval-quality win on its own,
    /// then add streaming as a focused follow-up.
    ///
    /// Tool dispatch reuses the same federated retriever the
    /// initial pass uses (cosine + entity + alias + per-book BM25)
    /// so the model's mid-answer searches get the same quality as
    /// the initial pull. The per-turn `registry` keeps `[book:N]`
    /// indices stable across the initial render + every tool
    /// result, so a citation the model emits at the end resolves
    /// correctly no matter which retrieval surfaced the paragraph.
    private func runCloudSendAgentic(
        userPrompt: String,
        initialHits: [LibraryEmbeddingIndex.Hit],
        registry: LibraryChatTools.TurnBookRegistry,
        library: LibraryEmbeddingIndex,
        backend: any EmbeddingBackend,
        model: CloudModel
    ) async {
        defer {
            isThinking = false
            streamTask = nil
        }
        // Accumulate every hit the model has seen this turn —
        // citation validation runs over the union so a marker
        // pointing into a tool-discovered paragraph still passes.
        var accumulatedHits: [LibraryEmbeddingIndex.Hit] = initialHits
        // Snapshot the state the detached tool-dispatch task will
        // need. Read on @MainActor here so the inner Task.detached
        // closure doesn't have to hop back.
        let useEntity = self.useEntityRetrieval
        let entityIndex = self.libraryEntityIndex
        let keywordIndex = self.libraryKeywordIndex
        let topKDefault = self.maxRetrievedParagraphs
        let rrfK = self.rrfK
        let scope = self.scopedURLs
        let excluded = self.excludedBookURLs
        let maxParaChars = self.maxParagraphChars

        let trimmed = trimChatHistory(
            Array(messages.dropLast()), maxTurns: maxHistoryTurns
        )
        var apiMessages = buildAnthropicMessages(
            history: trimmed,
            currentUserPrompt: userPrompt
        )

        let draftId = appendDraftAssistant()
        let maxIterations = agenticMaxIterations
        var iteration = 0

        do {
            while true {
                let request = AnthropicMessageRequest(
                    model: model,
                    maxTokens: useLongFormSynthesis ? 2500 : 1500,
                    system: .cached(systemPrompt, ttl: .oneHour),
                    messages: apiMessages,
                    thinking: .disabled,
                    tools: maxIterations > 0 ? [LibraryChatTools.searchLibraryTool] : nil
                )
                let response = try await client.send(request)
                try Task.checkCancellation()

                // Pull out text + tool_use blocks. Unknown blocks
                // we drop quietly — they're a forward-compat hatch.
                var textChunks: [String] = []
                var toolCalls: [(id: String, name: String, inputJSON: Data)] = []
                for block in response.content {
                    switch block {
                    case .text(let s): textChunks.append(s)
                    case .toolUse(let id, let name, let json):
                        toolCalls.append((id, name, json))
                    case .unknown: break
                    }
                }

                // Append any text the model emitted on this round
                // into the visible draft so the user sees progress
                // even when the model is mid-loop.
                let combinedText = textChunks.joined()
                if !combinedText.isEmpty {
                    appendToDraft(id: draftId, text: combinedText)
                    isThinking = false
                }

                // Final answer reached: either no tool calls or
                // iteration cap hit. Finalize the draft using the
                // registry-derived validity sets so citations are
                // checked against everything the model saw.
                if toolCalls.isEmpty || iteration >= maxIterations {
                    finalizeAgenticDraft(
                        id: draftId,
                        registry: registry,
                        accumulatedHits: accumulatedHits
                    )
                    return
                }

                // Echo the assistant turn's blocks back into the
                // running messages array — the API requires the
                // full assistant turn (including tool_use blocks)
                // to precede the matching tool_result user turn.
                var assistantBlocks: [ContentBlock] = []
                for block in response.content {
                    switch block {
                    case .text(let s):
                        assistantBlocks.append(.text(s, cacheControl: nil))
                    case .toolUse(let id, let name, let json):
                        assistantBlocks.append(.toolUse(id: id, name: name, inputJSON: json))
                    case .unknown: break
                    }
                }
                apiMessages.append(Message(
                    role: .assistant, content: .blocks(assistantBlocks)
                ))

                // Dispatch every tool call from this round in
                // parallel-shaped order (sequential dispatch is
                // simpler and matches how the model expects to read
                // them back; the cost of one extra round-trip is
                // already paid).
                var resultBlocks: [ContentBlock] = []
                for call in toolCalls {
                    let resultText: String
                    let isError: Bool
                    do {
                        let (text, hits) = try await dispatchSearchLibrary(
                            call: call,
                            library: library,
                            backend: backend,
                            registry: registry,
                            useEntity: useEntity,
                            entityIndex: entityIndex,
                            keywordIndex: keywordIndex,
                            topKDefault: topKDefault,
                            rrfK: rrfK,
                            scope: scope,
                            excluded: excluded,
                            maxParaChars: maxParaChars
                        )
                        accumulatedHits.append(contentsOf: hits)
                        resultText = text
                        isError = false
                    } catch {
                        resultText = "search_library failed: \(error.localizedDescription)"
                        isError = true
                    }
                    resultBlocks.append(.toolResult(
                        toolUseID: call.id,
                        content: resultText,
                        isError: isError
                    ))
                }
                apiMessages.append(Message(
                    role: .user, content: .blocks(resultBlocks)
                ))
                iteration += 1
            }
        } catch is CancellationError {
            removeDraft(id: draftId)
            return
        } catch let error as AnthropicAPIError {
            replaceDraftWithError(
                id: draftId, message: error.localizedDescription
            )
        } catch {
            replaceDraftWithError(
                id: draftId, message: error.localizedDescription
            )
        }
    }

    /// Run one `search_library` call from the model. Throws if the
    /// tool name doesn't match, the args don't decode, or the
    /// embed step fails — caller surfaces the throw as a
    /// `tool_result` with `isError: true` so the model can recover
    /// (try a different query, give up gracefully).
    private func dispatchSearchLibrary(
        call: (id: String, name: String, inputJSON: Data),
        library: LibraryEmbeddingIndex,
        backend: any EmbeddingBackend,
        registry: LibraryChatTools.TurnBookRegistry,
        useEntity: Bool,
        entityIndex: LibraryEntityIndex?,
        keywordIndex: LibraryKeywordIndex?,
        topKDefault: Int,
        rrfK: Double,
        scope: Set<URL>?,
        excluded: Set<URL>,
        maxParaChars: Int
    ) async throws -> (text: String, hits: [LibraryEmbeddingIndex.Hit]) {
        guard call.name == "search_library" else {
            throw LibraryChatToolError.unknownTool(call.name)
        }
        let args = try JSONDecoder().decode(
            LibraryChatTools.SearchLibraryArgs.self, from: call.inputJSON
        )
        let toolQuery = args.query
        let toolTopK = args.topK ?? topKDefault
        guard let vec = await embedQuery(toolQuery, using: backend) else {
            throw LibraryChatToolError.embedFailed
        }
        let aliases: AliasDictionary = useEntity
            ? AliasDictionaryStore().read()
            : .empty
        let hits = await Task.detached(priority: .userInitiated) {
            () -> [LibraryEmbeddingIndex.Hit] in
            var entityAnchors = useEntity
                ? Self.computeLibraryEntityAnchors(
                    query: toolQuery, entities: entityIndex
                  )
                : []
            entityAnchors.append(contentsOf: Self.computeLibraryAliasAnchors(
                query: toolQuery, library: library, aliases: aliases
            ))
            let allowedSourcePaths: Set<String>? = scope.map { urls in
                Set(urls.map {
                    $0.canonicalForFile.standardizedFileURL.path
                })
            }
            let excludedSourcePaths: Set<String> = Set(excluded.map {
                $0.canonicalForFile.standardizedFileURL.path
            })
            let filtered = entityAnchors.filter { anchor in
                let p = anchor.epubURL
                    .canonicalForFile.standardizedFileURL.path
                if let allowedSourcePaths, !allowedSourcePaths.contains(p) {
                    return false
                }
                return !excludedSourcePaths.contains(p)
            }
            let keywordHits = keywordIndex?.search(query: toolQuery, topK: 20) ?? []
            return library.search(
                queryVector: vec,
                topK: toolTopK,
                entityMatches: filtered,
                keywordHits: keywordHits,
                rrfK: rrfK,
                restrictTo: scope,
                excluding: excluded
            )
        }.value
        let text = LibraryChatTools.renderToolResult(
            query: toolQuery,
            hits: hits,
            registry: registry,
            maxParaChars: maxParaChars
        )
        return (text, hits)
    }

    private enum LibraryChatToolError: Error, LocalizedError {
        case unknownTool(String)
        case embedFailed

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name):
                return "Unknown tool: \(name)"
            case .embedFailed:
                return "Failed to embed the search query"
            }
        }
    }

    /// Finalize the agentic draft: run citation parse against the
    /// per-turn registry's book mapping + accumulated hits so
    /// `[book:N chapter:M para:K]` markers from any retrieval
    /// pass (initial or tool-discovered) resolve correctly.
    private func finalizeAgenticDraft(
        id: UUID,
        registry: LibraryChatTools.TurnBookRegistry,
        accumulatedHits: [LibraryEmbeddingIndex.Hit]
    ) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        let raw = messages[idx].text
        let bookByIndex = registry.bookByIndex
        var chapterValid: Set<String> = []
        var paraValid: Set<String> = []
        // Build validity sets keyed by registry index. The registry
        // already assigned indices for every book the model saw;
        // look up each hit's book to get its (stable) index.
        let indexByURL: [URL: Int] = Dictionary(
            uniqueKeysWithValues: bookByIndex.map { ($0.value.url, $0.key) }
        )
        for hit in accumulatedHits {
            guard let bookIdx = indexByURL[hit.epubURL] else { continue }
            chapterValid.insert("\(bookIdx)#\(hit.chapterIdx)")
            paraValid.insert("\(bookIdx)#\(hit.chapterIdx)#\(hit.paragraphIdx)")
        }
        let cited = parseCitations(
            in: raw,
            bookByIndex: bookByIndex,
            chapterValid: chapterValid,
            paraValid: paraValid
        )
        messages[idx].text = cited.cleaned
        messages[idx].citations = cited.citations
        messages[idx].retrievalDetail = Self.makeRetrievalDetail(hits: accumulatedHits)
        persistTranscript()
    }

    private func runOllamaSend(
        userPrompt: String,
        allowedHits: [LibraryEmbeddingIndex.Hit]
    ) async {
        defer {
            isThinking = false
            streamTask = nil
        }
        // History: see the matching comment in `runCloudSend`. Same
        // capture-before-draft ordering. Trimmed to the same per-VM
        // `maxHistoryTurns` cap as the cloud path so local-model
        // context doesn't grow without bound either.
        let trimmed = trimChatHistory(
            Array(messages.dropLast()), maxTurns: maxHistoryTurns
        )
        var history: [OllamaClient.ChatHistoryMessage] = []
        for prior in trimmed {
            history.append(.init(
                role: prior.role == .user ? .user : .assistant,
                content: prior.text
            ))
        }
        let draftId = appendDraftAssistant()
        var sawFirstDelta = false
        do {
            let stream = ollama.chatStream(
                model: ollamaModel,
                system: systemPrompt,
                history: history,
                userMessage: userPrompt
            )
            for try await delta in stream {
                try Task.checkCancellation()
                if !sawFirstDelta {
                    sawFirstDelta = true
                    isThinking = false
                }
                appendToDraft(id: draftId, text: delta)
            }
            finalizeDraft(id: draftId, allowedHits: allowedHits)
        } catch is CancellationError {
            removeDraft(id: draftId)
            return
        } catch let error as OllamaError {
            replaceDraftWithError(
                id: draftId, message: error.localizedDescription
            )
        } catch {
            replaceDraftWithError(
                id: draftId, message: error.localizedDescription
            )
        }
    }

    // MARK: - Streaming draft helpers

    /// Append an empty assistant draft message and return its id.
    /// The streaming send paths grow this message's `text` as deltas
    /// arrive, then finalize it (parse citations + persist) at
    /// stream end. Same id remains stable throughout so SwiftUI's
    /// LazyVStack can keep view identity. Mirrors the per-book chat
    /// VM's helper of the same name.
    private func appendDraftAssistant() -> UUID {
        let draft = BookChatMessage(role: .assistant, text: "")
        messages.append(draft)
        return draft.id
    }

    private func appendToDraft(id: UUID, text: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[idx].text += text
    }

    /// Stream completed cleanly. Run citation parse + persist.
    private func finalizeDraft(
        id: UUID, allowedHits: [LibraryEmbeddingIndex.Hit]
    ) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        let raw = messages[idx].text
        let cited = parseCitations(in: raw, allowedHits: allowedHits)
        messages[idx].text = cited.cleaned
        messages[idx].citations = cited.citations
        messages[idx].retrievalDetail = Self.makeRetrievalDetail(hits: allowedHits)
        persistTranscript()
    }

    private func replaceDraftWithError(id: UUID, message: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[idx].text = "Couldn't answer that — \(message)."
        messages[idx].citations = []
        persistTranscript()
    }

    private func removeDraft(id: UUID) {
        messages.removeAll { $0.id == id }
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
    /// Hit-ordered overload used by the Ollama path — derives the
    /// `bookByIndex` mapping + validity sets directly from the
    /// hits in the order they appear. The agentic cloud path uses
    /// the explicit-mapping overload below since its `[book:N]`
    /// indices come from a per-turn registry that survives across
    /// multiple tool calls (and may not match hit insertion order).
    private func parseCitations(
        in text: String,
        allowedHits: [LibraryEmbeddingIndex.Hit]
    ) -> CitationParse {
        var bookByIndex: [Int: (url: URL, title: String)] = [:]
        var seenBooks: [URL: Int] = [:]
        var chapterValid: Set<String> = []
        var paraValid: Set<String> = []
        for hit in allowedHits {
            if seenBooks[hit.epubURL] == nil {
                let idx = seenBooks.count
                seenBooks[hit.epubURL] = idx
                bookByIndex[idx] = (hit.epubURL, hit.bookTitle)
            }
            let idx = seenBooks[hit.epubURL] ?? 0
            chapterValid.insert("\(idx)#\(hit.chapterIdx)")
            paraValid.insert("\(idx)#\(hit.chapterIdx)#\(hit.paragraphIdx)")
        }
        return parseCitations(
            in: text,
            bookByIndex: bookByIndex,
            chapterValid: chapterValid,
            paraValid: paraValid
        )
    }

    /// Explicit-mapping overload — the agentic cloud path passes
    /// the per-turn registry's `bookByIndex` directly so citations
    /// resolve against the same numbering the model saw across
    /// every tool result. Validity sets gate paragraph / chapter
    /// citations the same way the hit-ordered overload does; an
    /// invalid citation chip looks clickable but jumps to a wrong
    /// anchor, so we drop those at parse time.
    /// `[book:N chapter:M]` without a paragraph passes if ANY hit
    /// covered that chapter — matches the prompt's "shorter form
    /// is fine for whole-chapter references" clause.
    private func parseCitations(
        in text: String,
        bookByIndex: [Int: (url: URL, title: String)],
        chapterValid: Set<String>,
        paraValid: Set<String>
    ) -> CitationParse {
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
            // Validate (book, chapter[, para]) against the
            // retrieved set. Drop hallucinated citations rather
            // than render a chip that opens the wrong paragraph.
            let isValid: Bool = {
                if let paraIdx {
                    return paraValid.contains(
                        "\(bookIdx)#\(chapterIdx)#\(paraIdx)"
                    )
                }
                return chapterValid.contains("\(bookIdx)#\(chapterIdx)")
            }()
            guard isValid else {
                let nsRange = match.range(at: 0)
                if let r = Range(nsRange, in: cleaned) {
                    cleaned.removeSubrange(r)
                }
                continue
            }
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

        PRIMARY SOURCES FIRST — when a question concerns a particular \
        author, thinker, or work, ground your answer in that author's \
        own texts whenever they appear in the retrieved set. Treat \
        books *about* the author as secondary commentary. Distinguish \
        the two in your wording so the user can tell which is which \
        ("In Discipline and Punish, Foucault writes…" vs "As one \
        commentator puts it…"). If only secondary sources were \
        retrieved, the right move is usually to call `search_library` \
        with a more author-specific query — name the author and a \
        characteristic concept — rather than draw on secondary work.

        TOOL USE — `search_library(query, top_k?)` runs the same \
        federated retriever that produced the initial context. Call it \
        when the initial paragraphs don't cover the question, when you \
        want to broaden via a rephrased query, when you need primary \
        sources after secondary commentary came back, or when the user \
        asks a follow-up that pivots topics. Each tool result extends \
        the master Books-in-scope list rather than restarting it, so a \
        `[book:N]` index stays stable across the entire turn. You can \
        issue several tool calls per turn; spend them on different \
        angles rather than re-running the same query verbatim.

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
