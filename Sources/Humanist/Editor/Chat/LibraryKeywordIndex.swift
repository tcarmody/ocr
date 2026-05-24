import Foundation
import EPUB

/// BM25 index over per-book "documents" assembled from the catalog
/// entry's title + author + every chapter / section title pulled out
/// of each book's hierarchy sidecar. Used by library-scope chat as
/// the keyword half of a hybrid retrieval — without it, a query like
/// "Lacan on the mirror stage" embeds conceptually but never surfaces
/// a book *by* Lacan when the cosine ranker happens to pick
/// secondary-source paragraphs higher (the catch the new
/// `PRIMARY SOURCES FIRST` prompt clause is built around).
///
/// Per-book granularity is deliberate. Per-paragraph BM25 across a
/// 2k-book library is ~3M documents — expensive to build and most of
/// the win is already captured by the embedding cosine. Per-book is
/// roughly 100k tokens total, builds in well under a second, and
/// catches the precision misses (author / title / chapter-heading
/// keyword overlap) that cosine drifts past.
///
/// Output: per-book BM25 rank, which the federated retriever projects
/// onto every paragraph in that book and contributes to the RRF
/// fusion alongside the cosine + entity ranks.
struct LibraryKeywordIndex: Sendable {

    struct BookHit: Sendable {
        let epubURL: URL
        let rank: Int   // 1-based
        let score: Double
    }

    /// Per-book document text used to build the BM25 vocabulary.
    /// Stored as opaque tokenized data — callers never see it.
    private struct Document {
        let epubURL: URL
        let termFrequency: [String: Int]
        let length: Int
    }

    private let documents: [Document]
    private let documentFrequency: [String: Int]
    private let avgLength: Double

    /// Canonical BM25 hyperparameters — same as `BookKeywordIndex`.
    private static let k1: Double = 1.5
    private static let b: Double = 0.75

    init(libraryEntries: [LibraryEntry],
         store: EmbeddingsSidecarStore = EmbeddingsSidecarStore()) {
        var docs: [Document] = []
        var df: [String: Int] = [:]
        var totalLen = 0
        for entry in libraryEntries {
            // Build the per-book "document" text. Sidecar's hierarchy
            // contributes chapter / section titles when present;
            // unindexed books contribute just title + author so they
            // still match an author query even before the embedding
            // sidecar exists.
            var parts: [String] = [entry.title]
            if let author = entry.author, !author.isEmpty {
                parts.append(author)
            }
            if let sidecar = store.read(for: entry.epubURL, libraryID: entry.id),
               let hierarchy = sidecar.hierarchy {
                for node in hierarchy.flatNodes {
                    parts.append(node.title)
                }
            }
            let blob = parts.joined(separator: " ")
            var tf: [String: Int] = [:]
            for token in Self.tokenize(blob) {
                tf[token, default: 0] += 1
            }
            let length = tf.values.reduce(0, +)
            docs.append(Document(
                epubURL: entry.epubURL,
                termFrequency: tf,
                length: length
            ))
            for term in tf.keys {
                df[term, default: 0] += 1
            }
            totalLen += length
        }
        self.documents = docs
        self.documentFrequency = df
        self.avgLength = docs.isEmpty
            ? 0 : Double(totalLen) / Double(docs.count)
    }

    /// Score every book against `query` and return the top-K in
    /// descending BM25 order. Books with score ≤ 0 are dropped so
    /// the federated retriever doesn't apply a meaningless rank
    /// boost on every book in the library for a query that didn't
    /// match anything.
    func search(query: String, topK: Int = 20) -> [BookHit] {
        let queryTerms = Set(Self.tokenize(query))
        guard !queryTerms.isEmpty, !documents.isEmpty else { return [] }
        let n = Double(documents.count)
        var scored: [(epubURL: URL, score: Double)] = []
        scored.reserveCapacity(documents.count)
        for doc in documents {
            var score = 0.0
            for term in queryTerms {
                guard let f = doc.termFrequency[term], f > 0 else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                guard df > 0 else { continue }
                let idf = log(((n - df + 0.5) / (df + 0.5)) + 1.0)
                let tfd = Double(f)
                let lenNorm = 1.0 - Self.b
                    + Self.b * Double(doc.length) / max(avgLength, 1)
                let saturated = (tfd * (Self.k1 + 1.0))
                    / (tfd + Self.k1 * lenNorm)
                score += idf * saturated
            }
            if score > 0 {
                scored.append((doc.epubURL, score))
            }
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .enumerated()
            .map { idx, pair in
                BookHit(epubURL: pair.epubURL, rank: idx + 1, score: pair.score)
            }
    }

    // MARK: - Tokenization

    /// Same shape as `BookKeywordIndex.tokenize` — lowercase,
    /// alphabetic-only, length ≥ 2, English stopword list. Library
    /// titles and headings sit in the same English-leaning regime,
    /// so the same rules apply. Stemming deliberately skipped — see
    /// `BookKeywordIndex` for the rationale.
    private static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        var buffer = ""
        for char in text.lowercased() {
            if char.isLetter {
                buffer.append(char)
            } else {
                if buffer.count >= 2, !stopwords.contains(buffer) {
                    out.append(buffer)
                }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if buffer.count >= 2, !stopwords.contains(buffer) {
            out.append(buffer)
        }
        return out
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all",
        "any", "can", "had", "has", "have", "her", "his", "its",
        "may", "one", "our", "out", "she", "that", "their", "them",
        "they", "this", "was", "were", "what", "when", "where",
        "which", "who", "why", "with", "would", "from", "into",
        "of", "in", "on", "to", "is", "as", "be", "by", "an",
        "or", "if", "it", "we", "us", "do", "so", "no",
    ]
}
