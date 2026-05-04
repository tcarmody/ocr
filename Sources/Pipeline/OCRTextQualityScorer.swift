import Foundation
import NaturalLanguage

/// Scores the quality of an OCR engine's text output for a single
/// region so the cascade can fall through when Vision returns
/// over-confident gibberish (the actual symptom: words running
/// together, words split apart, or non-prose-looking strings — but
/// confidence values still in the 0.85+ range that the existing
/// `meanConfidenceFloor` / `minObservationConfidenceFloor` triggers
/// don't catch).
///
/// Three signals, combined into 0…1:
///
///   1. **Single-char word ratio** — fraction of whitespace-split
///      tokens that are exactly one character. Real prose is
///      typically <8% (just `I`, `a`, etc.); over-split OCR hits
///      30%+. Catches "th is is a pa ge."
///   2. **Long-word ratio** — fraction of tokens longer than
///      `longWordThreshold` chars. Real prose has near-zero;
///      run-together OCR ("thisisapage") spikes. Catches missing
///      spaces.
///   3. **Language confidence** — `NLLanguageRecognizer`'s top
///      hypothesis probability. Real prose ≥0.9; nonsense collapses.
///
/// Combined: `(1 − 2·singleChar) · (1 − 10·longWord) · langConf`,
/// clamped to [0, 1]. Same multiplicative shape as the embedded-text
/// scorer so a single bad signal tanks the score.
public struct OCRTextQualityScorer {
    public struct Score: Sendable, Equatable {
        public var combined: Double            // 0…1, higher = better
        public var singleCharWordRatio: Double
        public var longWordRatio: Double
        public var languageConfidence: Double
        public var dominantLanguage: String?
        public var totalWords: Int
    }

    /// Word lengths above this count toward `longWordRatio`. 20 chars
    /// is well past any real English word ("internationalization" is
    /// 20); concatenations like "andthenhewenttothebookstore"
    /// blow well past it.
    public var longWordThreshold: Int
    /// Don't score regions with fewer than this many words — too
    /// noisy. Captions, page numbers, single-line headings sit
    /// below the threshold.
    public var minWordsForScoring: Int

    public init(longWordThreshold: Int = 20, minWordsForScoring: Int = 8) {
        self.longWordThreshold = longWordThreshold
        self.minWordsForScoring = minWordsForScoring
    }

    /// Returns nil when the region has too few words to score
    /// meaningfully — caller should treat that as "no signal" rather
    /// than triggering re-OCR.
    public func score(text: String) -> Score? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        let totalWords = tokens.count
        guard totalWords >= minWordsForScoring else { return nil }

        let singleCharWords = tokens.lazy.filter { $0.count == 1 }.count
        let longWords = tokens.lazy.filter { $0.count > longWordThreshold }.count
        let singleCharRatio = Double(singleCharWords) / Double(totalWords)
        let longWordRatio = Double(longWords) / Double(totalWords)

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let dominant = recognizer.dominantLanguage
        let langConfidence: Double
        if let dominant {
            langConfidence = recognizer.languageHypotheses(withMaximum: 5)[dominant] ?? 0
        } else {
            langConfidence = 0
        }

        // Penalties:
        //   * single-char: 0% → 1.0, 25% → 0.5, 50% → 0.0
        //   * long-word:   0% → 1.0,  5% → 0.5, 10% → 0.0
        let singleCharPenalty = max(0, 1 - 2 * singleCharRatio)
        let longWordPenalty = max(0, 1 - 10 * longWordRatio)
        let combined = max(0, min(1,
            singleCharPenalty * longWordPenalty * langConfidence
        ))

        return Score(
            combined: combined,
            singleCharWordRatio: singleCharRatio,
            longWordRatio: longWordRatio,
            languageConfidence: langConfidence,
            dominantLanguage: dominant?.rawValue,
            totalWords: totalWords
        )
    }
}
