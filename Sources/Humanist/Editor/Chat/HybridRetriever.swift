import Foundation

/// Two-source paragraph retriever for the chat-with-book pane.
/// Fuses BM25 (keyword precision) and embedding cosine (conceptual
/// recall) via reciprocal rank fusion (RRF), which is the standard
/// way to merge ranked lists when the underlying scores aren't
/// comparable on the same scale.
///
/// RRF: each paragraph's final score is `sum over rankers of 1/(k + rank)`.
/// We use the canonical `k=60`. The constant matters less than people
/// expect — RRF's good behavior comes from the rank-of-rank-1
/// dominance, not the exact `k`.
///
/// **BM25-to-paragraph projection**: BM25 ranks chapters, not
/// paragraphs. We project a chapter's BM25 rank onto every paragraph
/// in that chapter. So if BM25 ranks chapter 3 first, every paragraph
/// in chapter 3 gets BM25 rank 1; the embedding rank within those
/// paragraphs breaks ties. This keeps the keyword-precision signal
/// intact (a chapter that literally mentions "heterotopia" still
/// surfaces) while letting the embedding pass disambiguate among the
/// paragraphs inside it.
struct HybridRetriever {

    /// Style for one query — Settings exposes this so users can opt
    /// out of either path. Default is `.hybrid`.
    enum Style: String, CaseIterable, Identifiable, Sendable {
        case bm25
        case embeddings
        case hybrid

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .bm25:        return "Keyword (BM25)"
            case .embeddings:  return "Embeddings"
            case .hybrid:      return "Hybrid (default)"
            }
        }
        var blurb: String {
            switch self {
            case .bm25:
                return "Pick chapters by exact keyword overlap. Fast, no embedding setup, best for queries that share vocabulary with the book."
            case .embeddings:
                return "Rank paragraphs by semantic similarity. Catches conceptual matches that don't share words with the book."
            case .hybrid:
                return "Combine both via reciprocal rank fusion. Keyword precision plus conceptual recall — the right default for academic text."
            }
        }
    }

    /// One paragraph-level result. `bm25Rank` and `embeddingRank` are
    /// 1-based; `nil` means the paragraph didn't appear in that
    /// ranker's top-N. Carried so the chat pane can debug-log "why
    /// was this picked" if a future bug needs it.
    struct Hit: Sendable {
        let chapterIdx: Int
        let paragraphIdx: Int
        let text: String
        let score: Double
        let bm25Rank: Int?
        let embeddingRank: Int?
    }

    /// Standard RRF constant from Cormack et al. The mixing constant
    /// matters less than the rank distribution shape; 60 is a
    /// reliable default across IR benchmarks.
    static let rrfK: Double = 60

    let style: Style
    let bm25: BookKeywordIndex
    /// Optional — `nil` when the embedding index is still building
    /// (first-open case) or when the user picked `.bm25` style.
    let embeddings: BookEmbeddingIndex?
    /// Optional — only populated for styles that need it. The chat
    /// path is responsible for embedding the query before calling
    /// `search`; this type is dependency-free of any backend.
    let queryVector: [Float]?

    /// Run retrieval. Returns up to `topK` paragraph hits in
    /// descending fused-score order. The chat path renders each
    /// hit's `text` into Claude's context.
    func search(query: String, topK: Int = 8) -> [Hit] {
        // Decide which rankers are usable for this query. If a style
        // requires a signal we don't have, fall back gracefully:
        // .embeddings without a vector → empty (caller routes to
        // BM25 fallback); .hybrid without a vector → BM25-only.
        let useBM25: Bool
        let useEmbedding: Bool
        switch style {
        case .bm25:
            useBM25 = true
            useEmbedding = false
        case .embeddings:
            useBM25 = false
            useEmbedding = (embeddings != nil) && (queryVector != nil)
        case .hybrid:
            useBM25 = true
            useEmbedding = (embeddings != nil) && (queryVector != nil)
        }

        // Gather raw lists. BM25 → ordered chapter hits. Embeddings
        // → ordered paragraph hits.
        let bm25Hits = useBM25
            ? bm25.search(query: query, topK: max(topK * 2, 8))
            : []
        let embeddingHits: [BookEmbeddingIndex.Hit] = {
            guard useEmbedding,
                  let embeddings, let queryVector else { return [] }
            return embeddings.search(queryVector: queryVector, topK: max(topK * 3, 24))
        }()

        // Build a ranking dictionary keyed by (chapterIdx, paragraphIdx).
        // BM25 contributes one rank per paragraph in each top chapter;
        // embeddings contribute one rank per top paragraph.
        var bm25RankByPara: [Pair: Int] = [:]
        if useEmbedding, let embeddings {
            // When we have paragraph-level data, project BM25 chapter
            // ranks onto their paragraphs so the fusion sees a
            // consistent paragraph granularity.
            var paragraphsByChapter: [Int: [Int]] = [:]
            for paragraph in embeddings.paragraphs {
                paragraphsByChapter[paragraph.chapterIdx, default: []]
                    .append(paragraph.paragraphIdx)
            }
            for (chapterRank, hit) in bm25Hits.enumerated() {
                let chapterIdx = hit.chapterIndex
                let paragraphs = paragraphsByChapter[chapterIdx] ?? []
                for paragraphIdx in paragraphs {
                    bm25RankByPara[Pair(chapterIdx, paragraphIdx)] = chapterRank + 1
                }
            }
        }

        var embeddingRankByPara: [Pair: Int] = [:]
        for (rank, hit) in embeddingHits.enumerated() {
            embeddingRankByPara[Pair(hit.chapterIdx, hit.paragraphIdx)] = rank + 1
        }

        // BM25-only path: return the top BM25 chapters projected onto
        // the first paragraph of each (so the caller still gets
        // paragraph-shaped Hits). The chat path's renderContext can
        // expand to full chapter text for BM25-only style.
        if !useEmbedding {
            return bm25Hits.prefix(topK).map { hit in
                Hit(
                    chapterIdx: hit.chapterIndex,
                    paragraphIdx: 0,
                    text: hit.chapter.text,
                    score: hit.score,
                    bm25Rank: nil,
                    embeddingRank: nil
                )
            }
        }

        // Hybrid / embeddings-only with paragraph data: compute RRF.
        let allKeys = Set(bm25RankByPara.keys).union(embeddingRankByPara.keys)
        var scored: [Hit] = []
        scored.reserveCapacity(allKeys.count)
        for key in allKeys {
            let bm25Rank = bm25RankByPara[key]
            let embeddingRank = embeddingRankByPara[key]
            var score: Double = 0
            if let r = bm25Rank { score += 1.0 / (Self.rrfK + Double(r)) }
            if let r = embeddingRank { score += 1.0 / (Self.rrfK + Double(r)) }
            // Find the paragraph text. If the paragraph is in the
            // embedding index we have it directly; otherwise (BM25
            // brought it in via projection but embedding rank is
            // missing) use the chapter snippet from BM25.
            guard let paragraphText = paragraphText(
                key, embeddings: embeddings, bm25Hits: bm25Hits
            ) else { continue }
            scored.append(Hit(
                chapterIdx: key.chapterIdx,
                paragraphIdx: key.paragraphIdx,
                text: paragraphText,
                score: score,
                bm25Rank: bm25Rank,
                embeddingRank: embeddingRank
            ))
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0 }
    }

    /// Resolve a paragraph's text. The embedding index keeps the
    /// text verbatim; BM25-projected paragraphs that aren't in the
    /// embedding index fall back to the chapter's text.
    private func paragraphText(
        _ key: Pair,
        embeddings: BookEmbeddingIndex?,
        bm25Hits: [BookKeywordIndex.Hit]
    ) -> String? {
        if let para = embeddings?.paragraphs.first(where: {
            $0.chapterIdx == key.chapterIdx && $0.paragraphIdx == key.paragraphIdx
        }) {
            return para.text
        }
        return bm25Hits.first(where: { $0.chapterIndex == key.chapterIdx })?.chapter.text
    }

    private struct Pair: Hashable {
        let chapterIdx: Int
        let paragraphIdx: Int
        init(_ c: Int, _ p: Int) { chapterIdx = c; paragraphIdx = p }
    }
}
