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
    struct Source: Sendable {
        let epubURL: URL
        let bookTitle: String
        let paragraphs: [EmbeddingsSidecar.Entry]
    }

    /// One paragraph hit. Carries the book identity so the chat
    /// pane can render a `[book:n chapter:m]` citation that opens
    /// the right editor window. `text` is the paragraph itself —
    /// nil for sidecars that pre-date the per-entry text storage,
    /// which the chat path resolves by opening the book on disk.
    struct Hit: Sendable {
        let epubURL: URL
        let bookTitle: String
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
            guard let sidecar = store.read(for: entry.epubURL) else {
                unindexed += 1
                continue
            }
            guard sidecar.backendIdentifier == backend.identifier,
                  sidecar.dimension == backend.dimension else {
                mismatch += 1
                continue
            }
            sources.append(Source(
                epubURL: entry.epubURL,
                bookTitle: entry.title,
                paragraphs: sidecar.paragraphs
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
    /// similarity order. Brute-force per-source loop; faster than
    /// flattening the parallel arrays into one giant Float[] thanks
    /// to better cache locality on the per-source pass.
    func search(queryVector: [Float], topK: Int = 12) -> [Hit] {
        guard !queryVector.isEmpty else { return [] }
        var hits: [Hit] = []
        hits.reserveCapacity(min(totalParagraphCount, topK * 4))
        for source in sources {
            for entry in source.paragraphs {
                let score = BookEmbeddingIndex.cosine(
                    entry.vector, queryVector
                )
                hits.append(Hit(
                    epubURL: source.epubURL,
                    bookTitle: source.bookTitle,
                    chapterIdx: entry.chapterIdx,
                    paragraphIdx: entry.paragraphIdx,
                    textHash: entry.textHash,
                    text: entry.text,
                    score: score
                ))
            }
        }
        return hits
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0 }
    }
}
