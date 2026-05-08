import Foundation

/// BM25-style keyword retrieval over an EPUB's chapters. Built once
/// per book load (cheap — pure-string indexing); each query scores
/// every chapter and returns the top-K. Used by the chat pane to
/// pick which chapters to feed Claude as context for a question.
///
/// Why BM25 vs naive TF-IDF: BM25 caps the influence of repeated
/// terms in a long chapter (`tf` saturation) and normalizes by
/// chapter length — without those a single Aristotle-quoting
/// chapter would dominate every query that mentions "Aristotle".
struct BookKeywordIndex {
    /// One indexable unit. We index whole chapters rather than
    /// paragraphs for v1: fewer items keeps the per-query
    /// retrieval simple, and Sonnet has plenty of context room
    /// for a few chapter bodies.
    struct Chapter {
        let id: String       // EPUB resource id
        let title: String?
        let text: String     // plain text, untagged
    }

    private let chapters: [Chapter]
    /// Per-chapter token-count vectors keyed by stemmed term.
    private let termFrequency: [[String: Int]]
    /// Number of chapters each term appears in.
    private let documentFrequency: [String: Int]
    private let chapterLengths: [Int]
    private let avgChapterLength: Double

    /// BM25 hyperparameters. Defaults are the canonical ones used
    /// across the IR literature (Robertson et al.).
    private static let k1: Double = 1.5
    private static let b: Double = 0.75

    init(chapters: [Chapter]) {
        self.chapters = chapters
        var tfs: [[String: Int]] = []
        var df: [String: Int] = [:]
        var lengths: [Int] = []
        for chapter in chapters {
            var tf: [String: Int] = [:]
            for token in Self.tokenize(chapter.text) {
                tf[token, default: 0] += 1
            }
            tfs.append(tf)
            lengths.append(tf.values.reduce(0, +))
            for term in tf.keys {
                df[term, default: 0] += 1
            }
        }
        self.termFrequency = tfs
        self.documentFrequency = df
        self.chapterLengths = lengths
        self.avgChapterLength = lengths.isEmpty
            ? 0
            : Double(lengths.reduce(0, +)) / Double(lengths.count)
    }

    /// Score every chapter against `query` and return the top-K
    /// chapter indices in descending relevance order. Chapters
    /// with score ≤ 0 are dropped — the chat path can fall back
    /// on the chapter-title list when the query doesn't match.
    func search(query: String, topK: Int = 5) -> [Hit] {
        let queryTerms = Set(Self.tokenize(query))
        guard !queryTerms.isEmpty, !chapters.isEmpty else { return [] }
        let n = Double(chapters.count)
        var hits: [Hit] = []
        for (chapterIndex, tf) in termFrequency.enumerated() {
            var score = 0.0
            for term in queryTerms {
                guard let f = tf[term], f > 0 else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                guard df > 0 else { continue }
                let idf = log(((n - df + 0.5) / (df + 0.5)) + 1.0)
                let tfd = Double(f)
                let lenNorm = 1.0 - Self.b
                    + Self.b * Double(chapterLengths[chapterIndex]) / max(avgChapterLength, 1)
                let saturated = (tfd * (Self.k1 + 1.0))
                    / (tfd + Self.k1 * lenNorm)
                score += idf * saturated
            }
            if score > 0 {
                hits.append(Hit(
                    chapterIndex: chapterIndex,
                    chapter: chapters[chapterIndex],
                    score: score
                ))
            }
        }
        return hits
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0 }
    }

    struct Hit {
        let chapterIndex: Int
        let chapter: Chapter
        let score: Double
    }

    // MARK: - tokenization

    /// Lowercase, alphabetic-only, length >= 2, drop a small list
    /// of very-common English stopwords. We deliberately don't
    /// stem for v1 — stemming hurts non-English books (the
    /// Stanford analyzer would be wrong for Greek / Latin /
    /// French passages a Humanist book is likely to mix in) and
    /// the recall hit on plurals / verb tenses is small enough
    /// that BM25's IDF still surfaces the right chapter.
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
