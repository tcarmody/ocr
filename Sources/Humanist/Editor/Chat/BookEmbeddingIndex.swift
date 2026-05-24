import Foundation
import LibraryIndexing
import CryptoKit
import AI
import EPUB

/// Per-paragraph vector index for one EPUB. Pairs every paragraph in
/// the spine with an embedding produced by an `EmbeddingBackend`, then
/// answers cosine-similarity queries against an embedded query string.
///
/// Sits next to `BookKeywordIndex`: the keyword index ranks chapters
/// by BM25, this one ranks paragraphs by vector similarity.
/// `HybridRetriever` fuses both via reciprocal rank fusion so users
/// get keyword precision *and* conceptual recall.
///
/// Why per-paragraph instead of per-chapter: when the user asks a
/// conceptual question, the answer is usually a few sentences inside a
/// long chapter, not the whole chapter. Returning the specific
/// paragraph keeps Claude's context lean and the citation specific.
struct BookEmbeddingIndex {

    /// One embedded paragraph. `chapterIdx` is the spine position
    /// (matches `BookKeywordIndex.Hit.chapterIndex`); `paragraphIdx`
    /// is the position within that chapter (0-based, in source
    /// order). `textHash` is a SHA-256 of the normalized paragraph
    /// text — used for invalidation when a paragraph is edited.
    struct Paragraph: Sendable {
        let chapterIdx: Int
        let paragraphIdx: Int
        let text: String
        let textHash: String
        let vector: [Float]
    }

    /// One result of a cosine search. `score` is the cosine
    /// similarity in `[-1, 1]` (typically `[0, 1]` for normalized
    /// sentence embeddings); higher is more similar.
    struct Hit: Sendable {
        let chapterIdx: Int
        let paragraphIdx: Int
        let text: String
        let score: Double
    }

    /// All embedded paragraphs in the book. Order matches the order
    /// produced by `ParagraphExtractor.extract` (spine order, then
    /// document order within each chapter).
    let paragraphs: [Paragraph]
    /// The backend that produced these vectors. Stored so the
    /// retriever can re-embed the *query* with the same backend
    /// (otherwise the cosine compares vectors from different vector
    /// spaces, which is meaningless).
    let backend: any EmbeddingBackend

    init(paragraphs: [Paragraph], backend: any EmbeddingBackend) {
        self.paragraphs = paragraphs
        self.backend = backend
    }

    // MARK: - Search

    /// Score every paragraph against `queryVector` and return the
    /// top-K hits in descending similarity order. Pure scan — the
    /// expected book size (1k–5k paragraphs) is well below the
    /// threshold where any tree structure beats a brute force on
    /// modern CPUs.
    func search(queryVector: [Float], topK: Int = 12) -> [Hit] {
        guard !paragraphs.isEmpty, !queryVector.isEmpty else { return [] }
        var hits: [Hit] = []
        hits.reserveCapacity(paragraphs.count)
        for paragraph in paragraphs {
            let score = Self.cosine(paragraph.vector, queryVector)
            hits.append(Hit(
                chapterIdx: paragraph.chapterIdx,
                paragraphIdx: paragraph.paragraphIdx,
                text: paragraph.text,
                score: score
            ))
        }
        return hits
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0 }
    }

    /// Cosine similarity between two equal-length float vectors.
    /// Skips the divide-by-zero check because every backend produces
    /// a finite-norm vector for non-empty input, and zero-vector
    /// inputs (the empty-text fallback in `NLSentenceEmbeddingBackend`)
    /// are rare and degrade gracefully (score 0 ranks last).
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var dot: Double = 0
        var na: Double = 0
        var nb: Double = 0
        for i in 0..<a.count {
            let ax = Double(a[i])
            let bx = Double(b[i])
            dot += ax * bx
            na += ax * ax
            nb += bx * bx
        }
        let denom = (na * nb).squareRoot()
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    // MARK: - Building

    /// Build an index for `book` using `backend`, consulting
    /// `cache` to skip paragraphs that were already embedded with
    /// this backend in a prior session. After the build, `cache`
    /// contains the up-to-date set of vectors and is ready to be
    /// flushed to disk by the caller.
    ///
    /// Throws if the backend fails to embed any paragraph; the
    /// caller can fall back to keyword-only retrieval and surface
    /// a banner.
    static func build(
        for book: EPUBBook,
        backend: any EmbeddingBackend,
        cache: inout EmbeddingsSidecar
    ) async throws -> BookEmbeddingIndex {
        let extracted = ParagraphExtractor.extract(from: book)
        // Group cache entries by (chapterIdx, paragraphIdx) for
        // O(1) lookup.
        var cached: [Key: EmbeddingsSidecar.Entry] = [:]
        for entry in cache.paragraphs {
            cached[Key(entry.chapterIdx, entry.paragraphIdx)] = entry
        }

        // First pass: assemble the list of paragraphs that need
        // embedding (cache miss OR text drift since the prior run).
        struct Pending { let chapterIdx: Int; let paragraphIdx: Int; let text: String; let textHash: String }
        var pending: [Pending] = []
        var resolved: [Paragraph?] = Array(repeating: nil, count: extracted.count)
        for (offset, item) in extracted.enumerated() {
            let key = Key(item.chapterIdx, item.paragraphIdx)
            if let entry = cached[key], entry.textHash == item.textHash, entry.vector.count == backend.dimension {
                resolved[offset] = Paragraph(
                    chapterIdx: item.chapterIdx,
                    paragraphIdx: item.paragraphIdx,
                    text: item.text,
                    textHash: item.textHash,
                    vector: entry.vector
                )
            } else {
                pending.append(Pending(
                    chapterIdx: item.chapterIdx,
                    paragraphIdx: item.paragraphIdx,
                    text: item.text,
                    textHash: item.textHash
                ))
            }
        }

        // Second pass: embed the misses in batches. Batch size is
        // a tradeoff: bigger batches amortize HTTP round-trip cost
        // for cloud backends but block per-paragraph progress
        // signaling. 32 keeps both reasonable.
        let batchSize = 32
        var pendingIdx = 0
        while pendingIdx < pending.count {
            let end = min(pendingIdx + batchSize, pending.count)
            let slice = Array(pending[pendingIdx..<end])
            let vectors = try await backend.embed(slice.map(\.text))
            guard vectors.count == slice.count else {
                throw EmbeddingError.decode(
                    "backend returned \(vectors.count) vectors for \(slice.count) inputs"
                )
            }
            for (sliceOffset, item) in slice.enumerated() {
                let vec = vectors[sliceOffset]
                if vec.count != backend.dimension {
                    throw EmbeddingError.dimensionMismatch(
                        expected: backend.dimension, got: vec.count
                    )
                }
                // Find the resolved-array slot for this pending item.
                if let resolvedIdx = extracted.firstIndex(where: {
                    $0.chapterIdx == item.chapterIdx && $0.paragraphIdx == item.paragraphIdx
                }) {
                    resolved[resolvedIdx] = Paragraph(
                        chapterIdx: item.chapterIdx,
                        paragraphIdx: item.paragraphIdx,
                        text: item.text,
                        textHash: item.textHash,
                        vector: vec
                    )
                }
            }
            pendingIdx = end
        }

        let allParagraphs = resolved.compactMap { $0 }
        // Refresh the cache's paragraph entries in place. Other
        // sections (hierarchy, future: entities) are preserved —
        // BookEmbeddingIndex.build owns paragraphs only.
        cache.schemaVersion = EmbeddingsSidecar.currentSchemaVersion
        cache.backendIdentifier = backend.identifier
        cache.dimension = backend.dimension
        cache.paragraphs = allParagraphs.map {
            EmbeddingsSidecar.Entry(
                chapterIdx: $0.chapterIdx,
                paragraphIdx: $0.paragraphIdx,
                textHash: $0.textHash,
                vector: $0.vector,
                text: $0.text
            )
        }
        return BookEmbeddingIndex(paragraphs: allParagraphs, backend: backend)
    }

    /// Compact lookup key for the cache map.
    private struct Key: Hashable {
        let chapterIdx: Int
        let paragraphIdx: Int
        init(_ c: Int, _ p: Int) { chapterIdx = c; paragraphIdx = p }
    }
}

