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
    /// Surfaced when the resolved embedding backend silently fell
    /// back to NLEmbedding (e.g. Voyage key rotated, Ollama daemon
    /// stopped, network out). Cleared on the next clean resolution.
    /// The chat pane renders this as an inline notice so users
    /// notice the silent degrade rather than wondering why their
    /// fancy backend isn't producing different results.
    @Published private(set) var fallbackNote: String?

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
    /// Per-book NER index built via `NLTagger`. Used by the
    /// retriever to boost paragraphs mentioning entities the user
    /// references in the query. Populated alongside the hierarchy
    /// during the embedding-build task.
    private var entityIndex: BookEntityIndex?
    /// Federated index over the user's library — built lazily when
    /// the chat scope flips to `.library`. Held until scope flips
    /// back; rebuilt on the next library send so a re-indexed book
    /// joins the federation without an app restart.
    private var libraryIndex: LibraryEmbeddingIndex?
    /// Federated entity index over the library. Built alongside
    /// `libraryIndex` and consulted when the user names an entity
    /// in a library-scope query — every paragraph mentioning that
    /// entity across the library participates in RRF.
    private var libraryEntityIndex: LibraryEntityIndex?
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

    /// Gemini embedding model. Default is `gemini-embedding-2` —
    /// Google's first multimodal embedding model, GA on the
    /// Generative Language API. The older `gemini-embedding-001`
    /// is still available for text-only use cases. Note the
    /// digit-only `-2` (no `00` prefix); `gemini-embedding-002`
    /// is not a published model id and returns 404 — treat any
    /// persisted `-002` value as a synonym for the GA `-2` so
    /// users with the prior bad default don't have to fix it
    /// manually in Settings.
    private var geminiModel: String {
        let raw = UserDefaults.standard.string(
            forKey: "humanist.chat.geminiModel"
        ) ?? ""
        if raw.isEmpty || raw == "gemini-embedding-002" {
            return "gemini-embedding-2"
        }
        return raw
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

    /// Whether structural-query expansion contributes to the RRF
    /// fusion. Default on. Disabling skips the per-query
    /// hierarchy boost but doesn't drop the cached hierarchy from
    /// the sidecar (the TOC preamble in the system prompt always
    /// runs — that's free).
    private var useStructuralRetrieval: Bool {
        UserDefaults.standard.object(
            forKey: "humanist.chat.useStructuralRetrieval"
        ) as? Bool ?? true
    }

    /// Whether entity-match boosting contributes to the RRF fusion.
    /// Default on. Disabling skips the entity boost on both
    /// per-book and library scopes; the cached entity index stays
    /// on disk for when the user re-enables it.
    private var useEntityRetrieval: Bool {
        UserDefaults.standard.object(
            forKey: "humanist.chat.useEntityRetrieval"
        ) as? Bool ?? true
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
    /// Notification observer that catches embedding-backend
    /// changes from Settings so this VM can drop its cached
    /// indexes mid-session instead of waiting for an editor
    /// reload. `nonisolated(unsafe)` because the token is opaque
    /// (`NSObjectProtocol`), only touched in `deinit`, and there's
    /// no reachable race — same justification as the
    /// `pdfPageObserver` token in `EditorViewModel`.
    private nonisolated(unsafe) var backendChangeObserver: (any NSObjectProtocol)?

    /// Top-K BM25 chapters when the path is BM25-only. Mirrors the
    /// pre-embedding behavior.
    private static let maxRetrievedChapters = 4
    /// Per-chapter character cap on the BM25-only context.
    private static let maxChapterChars = 60_000
    /// Top-K paragraphs returned by hybrid / embeddings retrieval.
    /// Higher than the chapter count because each paragraph is much
    /// smaller — 12 paragraphs ≈ 12 KB, well under the cloud cost
    /// budget and enough to cover the answer most of the time.
    /// User-tunable via Settings → AI → Advanced.
    private var maxRetrievedParagraphs: Int {
        let raw = UserDefaults.standard.integer(forKey: "humanist.chat.topK")
        return raw > 0 ? raw : 12
    }
    /// Per-paragraph character cap. Trims abnormally long paragraphs
    /// (one of the OCR pipeline's known failure modes — a missed
    /// paragraph break can produce a 10 KB run-on). 4 KB is plenty
    /// for any well-formed paragraph. User-tunable.
    private var maxParagraphChars: Int {
        let raw = UserDefaults.standard.integer(forKey: "humanist.chat.maxParaChars")
        return raw > 0 ? raw : 4_000
    }
    /// RRF constant from Cormack et al. Default 60. User-tunable
    /// via Settings → AI → Advanced for power users who want to
    /// shift the balance between top-ranked and middle-ranked hits.
    private var rrfK: Double {
        let raw = UserDefaults.standard.integer(forKey: "humanist.chat.rrfK")
        return raw > 0 ? Double(raw) : HybridRetriever.defaultRRFK
    }
    /// Hit count above which the renderer switches a chapter from
    /// per-paragraph bullets to whole-chapter expansion. 4 hits in
    /// one chapter is a strong "this is what the user wants" signal
    /// — fewer is still better-served by paragraph-level rendering.
    private static let chapterClusterThreshold = 4
    /// Cap on the text emitted by a single chapter expansion. Long
    /// enough to cover a normal chapter (~30 pages of prose); short
    /// enough that a fully-expanded chapter doesn't blow the cloud
    /// chat budget. Only applies to expansion mode; paragraph
    /// rendering stays per-paragraph capped.
    private static let maxExpansionChars = 30_000

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
        // Subscribe to Settings backend changes. Drop cached
        // indexes and re-trigger the build so a flip from e.g.
        // NLEmbedding → Gemini takes effect on the next send
        // without forcing the user to close and reopen the editor.
        self.backendChangeObserver = NotificationCenter.default
            .addObserver(
                forName: .humanistEmbeddingBackendChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleBackendChange() }
            }
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
        if let observer = backendChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Handle a Settings-driven backend change. Drop cached
    /// per-book and library indexes (the latter is also held by
    /// this VM via the library scope path) and kick off a fresh
    /// embedding build. The on-disk sidecar self-invalidates
    /// when the build pass sees a backend identifier mismatch,
    /// so we don't have to wipe it explicitly here.
    private func handleBackendChange() {
        embeddingIndex = nil
        hierarchyIndex = nil
        entityIndex = nil
        libraryIndex = nil
        libraryEntityIndex = nil
        libraryParagraphCache.removeAll()
        fallbackNote = nil
        startEmbeddingBuild()
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
        let hierarchySnapshot = hierarchyIndex
        let entitySnapshot = entityIndex
        let task = Task { [weak self] in
            guard let self else { return }
            let queryVector: [Float]?
            if style != .bm25, let index = embeddingIndexSnapshot {
                queryVector = await self.embedQuery(query, using: index.backend)
            } else {
                queryVector = nil
            }

            // Compute hierarchy / entity boost paragraphs from the
            // query, gated by the user's Settings preferences.
            // Hierarchy: matched chapter nodes expand to every
            // paragraph in that chapter (the embedding index is
            // the source of paragraph identities). Entities:
            // anchors come straight from the entity index.
            let useStructural = await MainActor.run { self.useStructuralRetrieval }
            let useEntity = await MainActor.run { self.useEntityRetrieval }
            let hierarchyMatches = useStructural
                ? self.computeHierarchyMatches(
                    query: query,
                    hierarchy: hierarchySnapshot,
                    embeddings: embeddingIndexSnapshot
                  )
                : []
            // Alias dictionary is gated by the same toggle as
            // entity retrieval — both are entity-shaped boosts and
            // users should be able to flip them together.
            let aliasDictionary = useEntity
                ? AliasDictionaryStore().read()
                : .empty
            var entityMatches = useEntity
                ? self.computeEntityMatches(
                    query: query, entities: entitySnapshot
                  )
                : []
            entityMatches.append(contentsOf: self.computeAliasMatches(
                query: query,
                embeddings: embeddingIndexSnapshot,
                aliases: aliasDictionary
            ))

            var retriever = HybridRetriever(
                style: style,
                bm25: bm25,
                embeddings: embeddingIndexSnapshot,
                queryVector: queryVector
            )
            retriever.hierarchyMatches = hierarchyMatches
            retriever.entityMatches = entityMatches
            // Apply user-tuned RRF constant (default 60). The
            // tunable lives on the instance because Settings can
            // change it mid-session.
            retriever.rrfK = await MainActor.run { self.rrfK }
            let usedParagraphs = (style != .bm25) && (queryVector != nil) && (embeddingIndexSnapshot != nil)
            let topK = usedParagraphs
                ? await MainActor.run { self.maxRetrievedParagraphs }
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
            await MainActor.run {
                self.fallbackNote = resolution.fallbackNote
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
            // Library entity boost — when the user named an
            // entity present in the federated index, every
            // paragraph mentioning that entity gets a rank-1 RRF
            // contribution alongside the cosine hits. Gated by
            // the same Settings toggle as per-book entity
            // retrieval.
            let useEntity = await MainActor.run { self.useEntityRetrieval }
            let entityIndex = await MainActor.run { self.libraryEntityIndex }
            var entityAnchors = useEntity
                ? self.computeLibraryEntityAnchors(
                    query: query, entities: entityIndex
                  )
                : []
            // Alias dictionary contributes additional anchors via
            // a paragraph-text scan across the federated sources.
            // Same toggle as the entity boost.
            let aliasDictionary = useEntity
                ? AliasDictionaryStore().read()
                : .empty
            entityAnchors.append(contentsOf: self.computeLibraryAliasAnchors(
                query: query, library: library, aliases: aliasDictionary
            ))
            let topK = await MainActor.run { self.maxRetrievedParagraphs }
            let rrfK = await MainActor.run { self.rrfK }
            let hits = library.search(
                queryVector: queryVector,
                topK: topK,
                entityMatches: entityAnchors,
                rrfK: rrfK
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
                citations: cited.citations,
                retrievalDetail: Self.makeRetrievalDetail(
                    hits: allowedHits
                )
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
                citations: cited.citations,
                retrievalDetail: Self.makeRetrievalDetail(
                    hits: allowedHits
                )
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

    /// Project per-book hybrid hits into the persisted retrieval-
    /// debug shape. The `bookTitle` field stays nil for per-book
    /// scope — the source book is implicit in the editor window.
    private static func makeRetrievalDetail(
        hits: [HybridRetriever.Hit]
    ) -> RetrievalDetail {
        let entries: [RetrievalDetail.Hit] = hits.map {
            RetrievalDetail.Hit(
                chapterIdx: $0.chapterIdx,
                paragraphIdx: $0.paragraphIdx,
                bookTitle: nil,
                score: $0.score,
                bm25Rank: $0.bm25Rank,
                embeddingRank: $0.embeddingRank,
                hierarchyMatched: $0.hierarchyMatched,
                entityMatched: $0.entityMatched
            )
        }
        return RetrievalDetail(hits: entries)
    }

    /// Library-scope variant. `bookTitle` is populated so the
    /// debug surface can label hits with their source book.
    private static func makeRetrievalDetail(
        libraryHits: [ResolvedLibraryHit]
    ) -> RetrievalDetail {
        let entries: [RetrievalDetail.Hit] = libraryHits.map {
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
        self.entityIndex = nil
        startEmbeddingBuild()
    }

    /// Wipe this book's sidecar from disk and rebuild every index
    /// from scratch. Surfaced from the chat-pane header so a user
    /// can recover from a corrupt or stale cache without going
    /// through "Settings → Clear all indexes" (which would also
    /// nuke every other book's sidecar).
    func rebuildIndex() {
        bm25Index = nil
        embeddingIndex = nil
        hierarchyIndex = nil
        entityIndex = nil
        fallbackNote = nil
        embeddingsStore.clear(for: epubURL)
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
            // Surface the fallback note (if any) so the user sees
            // why their chosen backend isn't actually being used.
            await MainActor.run {
                self?.fallbackNote = resolution.fallbackNote
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
                // Run NER over every paragraph. Sequential pass
                // through ParagraphExtractor; ~5-10ms per paragraph
                // (~10-15s for a typical 1500-paragraph book).
                // Uses the same paragraphs the embedder already
                // walked, so the I/O cost is just the NLTagger
                // run itself.
                let entities = BookEntityIndex.build(from: snapshot)
                sidecar.entities = entities
                store.write(sidecar, for: url)
                try Task.checkCancellation()
                await MainActor.run {
                    self?.embeddingIndex = index
                    self?.hierarchyIndex = hierarchy
                    self?.entityIndex = entities
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

    /// Expand structural-query matches to paragraph anchors. A hit
    /// on "chapter 3" → every paragraph in chapter 3. The embedding
    /// index supplies the paragraph identity space (it knows which
    /// paragraph indices exist per chapter); when the embedding
    /// index isn't built yet, we return an empty list and the RRF
    /// fusion proceeds without the structural boost.
    private func computeHierarchyMatches(
        query: String,
        hierarchy: BookHierarchyIndex?,
        embeddings: BookEmbeddingIndex?
    ) -> [(chapterIdx: Int, paragraphIdx: Int)] {
        guard let hierarchy, let embeddings else { return [] }
        let matches = hierarchy.nodesMatching(query: query)
        guard !matches.isEmpty else { return [] }
        // Distinct chapter indices the query referenced. Multiple
        // matched nodes typically share a chapter (a section
        // matches and so does its containing chapter); dedup so
        // we don't double-count.
        let chapterIdxs = Set(matches.map(\.chapterIdx))
        var anchors: [(chapterIdx: Int, paragraphIdx: Int)] = []
        for paragraph in embeddings.paragraphs
        where chapterIdxs.contains(paragraph.chapterIdx) {
            anchors.append((paragraph.chapterIdx, paragraph.paragraphIdx))
        }
        return anchors
    }

    /// Look up entities the user named in `query` and project to
    /// paragraph anchors. Caps the per-entity anchor count so a
    /// single very-frequent entity ("Foucault" in a Foucault book)
    /// doesn't drown the RRF fusion in boosts that all share rank
    /// 1 — beyond a few dozen anchors the boost adds noise without
    /// adding signal.
    private func computeEntityMatches(
        query: String,
        entities: BookEntityIndex?
    ) -> [(chapterIdx: Int, paragraphIdx: Int)] {
        guard let entities else { return [] }
        let matched = entities.entitiesMatching(query: query)
        guard !matched.isEmpty else { return [] }
        var out: [(chapterIdx: Int, paragraphIdx: Int)] = []
        // Cap per-entity at 50 anchors — enough to surface the
        // entity meaningfully, low enough that the boost is
        // selective. Across-entity total cap of 200 is a defense
        // against a 5-entity query in a 10K-paragraph book.
        let perEntityCap = 50
        let totalCap = 200
        for canonical in matched {
            for anchor in entities.anchors(for: canonical).prefix(perEntityCap) {
                out.append((anchor.chapterIdx, anchor.paragraphIdx))
                if out.count >= totalCap { return out }
            }
        }
        return out
    }

    /// Library-scope counterpart to `computeEntityMatches`. Returns
    /// every (book, chapter, paragraph) anchor mentioning a
    /// query-named entity that the federated index knows about.
    /// Same per-entity / total caps as the per-book path; the
    /// budget is shared across books since a popular entity in a
    /// 100-book corpus could otherwise dominate.
    private func computeLibraryEntityAnchors(
        query: String,
        entities: LibraryEntityIndex?
    ) -> [LibraryEntityIndex.LibraryAnchor] {
        guard let entities else { return [] }
        let matched = entities.entitiesMatching(query: query)
        guard !matched.isEmpty else { return [] }
        var out: [LibraryEntityIndex.LibraryAnchor] = []
        // Larger total cap for library scope (1500 vs 200 per-book)
        // — corpus-wide queries naturally surface more anchors.
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

    /// Look up alias matches in the per-book paragraph cache. For
    /// each alias the user has defined that appears in `query`,
    /// scan the embedding index's paragraph texts (which have been
    /// stripped + decoded) for that alias as a substring. Returns
    /// every matching paragraph anchor — these participate in RRF
    /// the same way as NER entity matches.
    private func computeAliasMatches(
        query: String,
        embeddings: BookEmbeddingIndex?,
        aliases: AliasDictionary
    ) -> [(chapterIdx: Int, paragraphIdx: Int)] {
        guard let embeddings, !aliases.terms.isEmpty else { return [] }
        let queryLowered = query.lowercased()
        let matched = aliases.terms.filter { queryLowered.contains($0) }
        guard !matched.isEmpty else { return [] }
        var anchors: [(chapterIdx: Int, paragraphIdx: Int)] = []
        for paragraph in embeddings.paragraphs {
            let textLowered = paragraph.text.lowercased()
            for term in matched where textLowered.contains(term) {
                anchors.append((paragraph.chapterIdx, paragraph.paragraphIdx))
                break  // one anchor per paragraph; multi-term hits don't compound
            }
        }
        return anchors
    }

    /// Library-scope alias matches. Walks every source's paragraph
    /// entries and emits anchors for paragraphs whose cached text
    /// contains a query-matched alias. Sources whose sidecar
    /// pre-dates the per-entry text storage contribute nothing for
    /// this path — the alias scan needs the text on hand and we
    /// don't unzip books on every query.
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
    /// The companion `libraryEntityIndex` is built / refreshed in
    /// the same pass.
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
        let entityIndex = LibraryEntityIndex.build(
            libraryEntries: entries
        )
        await MainActor.run {
            self.libraryIndex = index
            self.libraryEntityIndex = entityIndex
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
            let text = String(hit.text.prefix(self.maxParagraphChars))
            out += "[book:\(bIdx) chapter:\(hit.chapterIdx) para:\(hit.paragraphIdx)]\n  • \(text)\n\n"
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
                citations: cited.citations,
                retrievalDetail: Self.makeRetrievalDetail(
                    libraryHits: allowedHits
                )
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
                citations: cited.citations,
                retrievalDetail: Self.makeRetrievalDetail(
                    libraryHits: allowedHits
                )
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
        // Match `[book:N chapter:M]` and `[book:N chapter:M para:K]`
        // in one pass — paragraph segment is optional. Group 3 is
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
                    resourceID: "",  // unknown without opening the book
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
                if lhs.bookTitle ?? "" != rhs.bookTitle ?? "" {
                    return (lhs.bookTitle ?? "") < (rhs.bookTitle ?? "")
                }
                if lhs.chapterIndex != rhs.chapterIndex {
                    return lhs.chapterIndex < rhs.chapterIndex
                }
                return (lhs.paragraphIndex ?? -1) < (rhs.paragraphIndex ?? -1)
            }
        return CitationParse(cleaned: cleaned, citations: citations)
    }

    /// System prompt used in library scope. Differs from the per-
    /// book prompt in that the model is told to cite `[book:N
    /// chapter:M para:K]` and to compare across books when the
    /// question invites it.
    private var libraryScopeSystemPrompt: String {
        """
        You are a research assistant embedded in an EPUB editor. \
        The user has multiple books open across their library and \
        is asking a question that may span more than one of them.

        For each question, you'll receive a small set of paragraphs \
        retrieved from across the user's library, prefixed with a \
        list of the source books. Each paragraph is labeled \
        `[book:N chapter:M para:K]` where N indexes into the books \
        list, M indexes into that book's spine, and K is the \
        paragraph within the chapter.

        Cite sources inline using the same marker form. The user's \
        interface renders these as clickable links that open the \
        cited book in a new editor window. Use the full \
        `[book:N chapter:M para:K]` marker when the claim comes \
        from a specific paragraph; the shorter `[book:N chapter:M]` \
        form is fine for whole-chapter references.

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
    ///
    /// Variable-granularity expansion: when several hits cluster
    /// in one chapter, the model usually wants the whole chapter as
    /// context — the answer is "this chapter discusses X" not "here
    /// are 4 sentences from this chapter." When `chapterClusterThreshold`
    /// or more hits land in a single chapter, the chapter's full
    /// text (capped at `maxExpansionChars`) is rendered in place of
    /// the individual paragraph bullets. Chapters with fewer hits
    /// keep the per-paragraph rendering.
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
            // Hit-cluster check — if many hits sit in this chapter,
            // surface the whole chapter as context so the model has
            // surrounding prose. Cap the expansion so a single
            // very-long chapter (encyclopedia-style books can have
            // 100KB+ chapters) doesn't blow the token budget.
            let shouldExpand = chapterHits.count >= Self.chapterClusterThreshold
            if shouldExpand,
               let expansion = chapterTextForExpansion(chapterIdx) {
                out += "  (chapter-level context — \(chapterHits.count) of the top hits cluster here)\n"
                out += expansion + "\n"
            } else {
                for hit in chapterHits {
                    let text = String(hit.text.prefix(self.maxParagraphChars))
                    // Per-paragraph marker so citations can resolve
                    // to a specific paragraph anchor — the model
                    // cites with the same marker form, our parser
                    // captures the para:M index, and the chip's
                    // tap handler scrolls source + preview to
                    // `<p id="hu-p-N-M">`.
                    out += "  [chapter:\(hit.chapterIdx) para:\(hit.paragraphIdx)] \(text)\n"
                }
            }
            out += "\n"
        }
        return out
    }

    /// Pull the full text of a chapter for variable-granularity
    /// expansion. Capped at `maxExpansionChars` so long chapters
    /// don't blow the model's context. Returns nil when the
    /// resource isn't a text resource or doesn't exist.
    private func chapterTextForExpansion(_ idx: Int) -> String? {
        guard idx >= 0, idx < book.spine.count else { return nil }
        let resourceID = book.spine[idx]
        guard let resource = book.resourcesByID[resourceID],
              let xhtml = resource.text else { return nil }
        let stripped = stripTags(xhtml)
        return String(stripped.prefix(Self.maxExpansionChars))
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
        // Key by "chapter#paragraph" so the same chapter cited at
        // two different paragraphs produces two distinct chips
        // (each scrolling to its own anchor). Chapter-only
        // citations key as "chapter#-".
        var seen: [String: BookChatCitation] = [:]
        // Match `[chapter:N]` and `[chapter:N para:M]` in one pass.
        // `(?:\\s+para:(\\d+))?` makes the paragraph segment
        // optional; group 2 is the paragraph index when present.
        let pattern = "\\[chapter:(\\d+)(?:\\s+para:(\\d+))?\\]"
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
            guard match.numberOfRanges == 3 else { continue }
            let chapterRaw = nsText.substring(with: match.range(at: 1))
            let paragraphRaw: String? = {
                let r = match.range(at: 2)
                return r.location == NSNotFound
                    ? nil
                    : nsText.substring(with: r)
            }()
            guard let idx = Int(chapterRaw),
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
            let paraIdx: Int? = paragraphRaw.flatMap(Int.init)
            let title = chapterTitle(forChapterIndex: idx)
            let key = "\(idx)#\(paraIdx.map(String.init) ?? "-")"
            if seen[key] == nil {
                seen[key] = BookChatCitation(
                    chapterIndex: idx,
                    title: title ?? "Chapter \(idx + 1)",
                    resourceID: resource.id,
                    paragraphIndex: paraIdx
                )
            }
            // Strip the inline marker entirely — the citation
            // chips below the message body carry the click
            // target. Inlining "(see TITLE)" looked terrible
            // when Claude cited the same chapter twice in a row.
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
            .sorted {
                if $0.chapterIndex != $1.chapterIndex {
                    return $0.chapterIndex < $1.chapterIndex
                }
                return ($0.paragraphIndex ?? -1) < ($1.paragraphIndex ?? -1)
            }
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
        retrieved from the book. Each paragraph is labeled \
        `[chapter:N para:M]` where N is the chapter index and M is \
        the paragraph index within that chapter. Answer the \
        question using only the supplied text.

        Cite the source of every claim inline. When the claim comes \
        from a specific paragraph, use the full `[chapter:N para:M]` \
        marker — the user's interface scrolls the editor to that \
        exact paragraph on click. When the claim is broader (a \
        whole chapter's argument), you may use the shorter \
        `[chapter:N]` form, which selects the chapter without \
        scrolling to a specific paragraph.

        If the supplied paragraphs don't contain enough information \
        to answer, say so plainly — don't guess. Quote brief \
        passages when they directly support the answer; cite their \
        location with the marker form above.

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
