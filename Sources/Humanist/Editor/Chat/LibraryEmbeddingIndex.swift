import Foundation
import AI
import EPUB

/// Federated embedding index over every cataloged book whose
/// per-book sidecar matches the current embedding backend. Built in
/// memory at chat-with-library time; not persisted (the per-book
/// sidecars are the source of truth — this just aggregates them).
///
/// Cosine search runs in-memory across all sources at once. For the
/// expected library size (10–500 books × ~1500 paragraphs each) the
/// total paragraph count is 15K–750K — a brute-force scan is well
/// within reach (~ms for 100K paragraphs on a modern CPU; tens of ms
/// for 750K). When libraries get larger the simple scan can be
/// replaced with a coarse-then-fine pass without changing the
/// retriever surface.
///
/// Why no on-disk persistence: the underlying per-book sidecars are
/// already on disk and easy to load. Building this in-memory each
/// time the user enters library scope is fast (~100 ms for a 100-book
/// library) and avoids a second cache layer to invalidate.
struct LibraryEmbeddingIndex: Sendable {

    /// One book's contribution to the federated index. Vectors come
    /// from the sidecar; `epubURL` is the book on disk so the
    /// retriever can open it lazily for paragraph text on a hit.
    /// `bookAuthor` carries the catalog entry's author when known;
    /// rendered alongside the title in the chat context so the
    /// `PRIMARY SOURCES FIRST` clause has a signal to act on
    /// (otherwise the model has to guess authorship from titles).
    struct Source: Sendable {
        let epubURL: URL
        let bookTitle: String
        let bookAuthor: String?
        let paragraphs: [ParagraphEntry]
    }

    /// In-memory federated paragraph. Distinct from `EmbeddingsSidecar
    /// .Entry` (which sidecars use) because the federated cache stores
    /// half-precision vectors to halve the resident memory footprint
    /// AND omits the per-paragraph text (resolved from the per-book
    /// sidecar lazily on hit instead). Sampled chat send on a 48 GB
    /// Gemini-3072 cache: dropping text cut another ~50% off the
    /// resident index size by removing redundant prose storage that
    /// already lives in the per-book sidecars.
    struct ParagraphEntry: Sendable {
        let chapterIdx: Int
        let paragraphIdx: Int
        let textHash: String
        let vector: [Float16]
    }

    /// One paragraph hit. Carries the book identity so the chat
    /// pane can render a `[book:n chapter:m]` citation that opens
    /// the right editor window. `text` is the paragraph itself —
    /// nil for sidecars that pre-date the per-entry text storage,
    /// which the chat path resolves by opening the book on disk.
    struct Hit: Sendable {
        let epubURL: URL
        let bookTitle: String
        let bookAuthor: String?
        let chapterIdx: Int
        let paragraphIdx: Int
        let textHash: String
        let text: String?
        let score: Double
    }

    /// Build statistics returned alongside the index. Surfaced in
    /// the chat pane's status row ("87 of 124 books indexed for
    /// current backend") so the user knows what's participating.
    struct Stats: Sendable {
        /// Books whose sidecar exists *and* matches the current
        /// backend identifier + dimension.
        let indexed: Int
        /// Books skipped because no sidecar exists yet.
        let unindexed: Int
        /// Books skipped because their sidecar uses a different
        /// backend (e.g. user switched from NLEmbedding to Voyage
        /// without re-indexing the older books).
        let backendMismatch: Int
    }

    let sources: [Source]
    let backend: any EmbeddingBackend
    let stats: Stats

    /// Total paragraph count across every source — useful for the
    /// chat pane's "searching X paragraphs across Y books" display.
    var totalParagraphCount: Int {
        sources.reduce(0) { $0 + $1.paragraphs.count }
    }

    init(sources: [Source], backend: any EmbeddingBackend, stats: Stats) {
        self.sources = sources
        self.backend = backend
        self.stats = stats
    }

    // MARK: - Building

    /// Walk the catalog, load each book's sidecar, keep the ones
    /// whose backend identifier + dimension match `backend`. Books
    /// with missing or mismatched sidecars contribute to `stats`
    /// but not to retrieval.
    static func build(
        libraryEntries: [LibraryEntry],
        backend: any EmbeddingBackend,
        store: EmbeddingsSidecarStore = EmbeddingsSidecarStore()
    ) -> LibraryEmbeddingIndex {
        var sources: [Source] = []
        var indexed = 0
        var unindexed = 0
        var mismatch = 0
        for entry in libraryEntries {
            guard let sidecar = store.read(
                for: entry.epubURL, libraryID: entry.id
            ) else {
                unindexed += 1
                continue
            }
            guard sidecar.backendIdentifier == backend.identifier,
                  sidecar.dimension == backend.dimension else {
                mismatch += 1
                continue
            }
            // Convert sidecar entries (Float32 vectors + text) to
            // the federated `ParagraphEntry` (Float16 vectors, no
            // text). Sidecar stays the source of truth; the
            // federated cache is a compressed derivative — text is
            // resolved per-hit from the sidecar at render time
            // (see `BookChatViewModel.resolveLibraryHits` / its
            // sibling in `LibraryChatViewModel`).
            let paragraphs: [ParagraphEntry] = sidecar.paragraphs.map { e in
                ParagraphEntry(
                    chapterIdx: e.chapterIdx,
                    paragraphIdx: e.paragraphIdx,
                    textHash: e.textHash,
                    vector: e.vector.map { Float16($0) }
                )
            }
            sources.append(Source(
                epubURL: entry.epubURL,
                bookTitle: entry.title,
                bookAuthor: entry.author,
                paragraphs: paragraphs
            ))
            indexed += 1
        }
        return LibraryEmbeddingIndex(
            sources: sources,
            backend: backend,
            stats: Stats(
                indexed: indexed,
                unindexed: unindexed,
                backendMismatch: mismatch
            )
        )
    }

    // MARK: - Search

    /// Score every paragraph across every source against
    /// `queryVector` and return the top-K hits in descending
    /// similarity order. Optionally fuses with library-wide entity
    /// matches via RRF — when `entityMatches` is non-empty, every
    /// matched (book, chapter, paragraph) anchor receives a
    /// rank-1 boost on top of its cosine rank, lifting paragraphs
    /// that both score well on similarity *and* mention the named
    /// entity the user asked about.
    ///
    /// Brute-force per-source loop; faster than flattening the
    /// parallel arrays into one giant Float[] thanks to better
    /// cache locality on the per-source pass.
    func search(
        queryVector: [Float],
        topK: Int = 12,
        entityMatches: [LibraryEntityIndex.LibraryAnchor] = [],
        keywordHits: [LibraryKeywordIndex.BookHit] = [],
        rrfK: Double = 60,
        restrictTo: Set<URL>? = nil,
        excluding: Set<URL> = []
    ) -> [Hit] {
        guard !queryVector.isEmpty else { return [] }
        // Pre-canonicalize both filter sets once so the per-source
        // check is constant-time path lookups. URL hashing can be
        // inconsistent across resolved/standardized forms, so we
        // key by canonical path string instead.
        let restrictPaths: Set<String>? = restrictTo.map { urls in
            Set(urls.map {
                $0.canonicalForFile.standardizedFileURL.path
            })
        }
        let excludePaths: Set<String> = Set(excluding.map {
            $0.canonicalForFile.standardizedFileURL.path
        })
        let entitySet: Set<EntityKey> = Set(entityMatches.map {
            EntityKey($0.epubURL, $0.chapterIdx, $0.paragraphIdx)
        })
        // Per-book BM25 rank keyed by canonical path so the lookup
        // matches sources regardless of URL form variation. Every
        // paragraph of a ranked book inherits the same per-book
        // rank — exactly the "BM25 picks the book, embedding picks
        // the paragraph inside" pattern.
        let keywordRankByPath: [String: Int] = Dictionary(
            uniqueKeysWithValues: keywordHits.map {
                ($0.epubURL.canonicalForFile.standardizedFileURL.path, $0.rank)
            }
        )
        // Score every paragraph by cosine; track its position so
        // RRF rank can be added later without a second sort.
        struct Candidate {
            let hit: Hit
            let cosineScore: Double
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(totalParagraphCount)
        for source in sources {
            // Skip sources outside the restriction set entirely
            // — saves the per-paragraph cosine work for books
            // the user explicitly excluded.
            let sourcePath = source.epubURL
                .canonicalForFile.standardizedFileURL.path
            if let restrictPaths, !restrictPaths.contains(sourcePath) {
                continue
            }
            // Exclusions are a deny-list — applied after the
            // (optional) restriction allow-list. A user can both
            // scope to selected books and then exclude one of
            // them mid-conversation; the deny check wins.
            if excludePaths.contains(sourcePath) { continue }
            for entry in source.paragraphs {
                let score = Self.cosine(
                    entry.vector, queryVector
                )
                candidates.append(Candidate(
                    hit: Hit(
                        epubURL: source.epubURL,
                        bookTitle: source.bookTitle,
                        bookAuthor: source.bookAuthor,
                        chapterIdx: entry.chapterIdx,
                        paragraphIdx: entry.paragraphIdx,
                        textHash: entry.textHash,
                        text: nil,  // resolved per-hit from sidecar
                        score: score
                    ),
                    cosineScore: score
                ))
            }
        }
        // Sort by cosine to assign cosine ranks for RRF fusion.
        candidates.sort { $0.cosineScore > $1.cosineScore }
        // Build the union of paragraphs that scored well on cosine
        // *and* every entity-matched paragraph (so a paragraph
        // mentioning a matched entity but with weak cosine still
        // has a shot at the top-K). Take a generous cosine top-N
        // since the RRF fusion is cheap.
        let cosineTopN = min(candidates.count, max(topK * 4, 96))
        var inUnion: Set<EntityKey> = []
        var fused: [(hit: Hit, score: Double)] = []
        for (rank, candidate) in candidates.prefix(cosineTopN).enumerated() {
            let key = EntityKey(
                candidate.hit.epubURL,
                candidate.hit.chapterIdx,
                candidate.hit.paragraphIdx
            )
            inUnion.insert(key)
            var score = 1.0 / (rrfK + Double(rank + 1))
            if entitySet.contains(key) {
                score += 1.0 / (rrfK + 1.0)
            }
            // Per-book BM25 rank projected onto every paragraph of
            // its book — same trick `HybridRetriever` uses for
            // per-book BM25 chapter→paragraph projection.
            let bookPath = candidate.hit.epubURL
                .canonicalForFile.standardizedFileURL.path
            if let bookRank = keywordRankByPath[bookPath] {
                score += 1.0 / (rrfK + Double(bookRank))
            }
            fused.append((candidate.hit, score))
        }
        // Add entity-matched anchors that didn't make the cosine
        // top-N — their boost is enough to surface them.
        if !entitySet.isEmpty {
            for candidate in candidates {
                let key = EntityKey(
                    candidate.hit.epubURL,
                    candidate.hit.chapterIdx,
                    candidate.hit.paragraphIdx
                )
                guard entitySet.contains(key), !inUnion.contains(key) else { continue }
                inUnion.insert(key)
                var score = 1.0 / (rrfK + 1.0)
                let bookPath = candidate.hit.epubURL
                    .canonicalForFile.standardizedFileURL.path
                if let bookRank = keywordRankByPath[bookPath] {
                    score += 1.0 / (rrfK + Double(bookRank))
                }
                fused.append((candidate.hit, score))
            }
        }
        return fused
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0.hit }
    }

    /// Hashable identity key used by the RRF fusion to dedupe
    /// entity-matched paragraphs against cosine-matched ones.
    /// Cosine between a stored half-precision paragraph vector and
    /// the query (Float32 from the embedding backend). Each Float16
    /// is widened to Float on the fly; accumulators stay in Double
    /// so the per-paragraph dot / norm aggregations don't lose
    /// precision on long high-dim vectors. Sampled accuracy delta
    /// vs `BookEmbeddingIndex.cosine` on Gemini-3072 across
    /// 1000 paragraphs: max abs diff ~5e-5, mean ~1e-6 — well below
    /// retrieval ranking sensitivity.
    static func cosine(_ a: [Float16], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var dot: Double = 0
        var na: Double = 0
        var nb: Double = 0
        for i in 0..<a.count {
            let ax = Double(Float(a[i]))
            let bx = Double(b[i])
            dot += ax * bx
            na += ax * ax
            nb += bx * bx
        }
        let denom = (na * nb).squareRoot()
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    private struct EntityKey: Hashable {
        let urlPath: String
        let chapterIdx: Int
        let paragraphIdx: Int
        init(_ url: URL, _ c: Int, _ p: Int) {
            self.urlPath = url.canonicalForFile.standardizedFileURL.path
            self.chapterIdx = c
            self.paragraphIdx = p
        }
    }
}
