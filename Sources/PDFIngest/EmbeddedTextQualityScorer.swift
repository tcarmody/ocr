import Foundation
import NaturalLanguage

/// Scores the quality of a PDF's embedded text layer per page so the
/// pipeline can decide whether to trust it (skip Vision OCR) or re-OCR
/// the rendered page image.
///
/// Three signals, combined into a single 0…1 score:
///
///   1. **Mojibake ratio** — fraction of characters that are U+FFFD or
///      sit in a Private Use Area block. These are the smell of a broken
///      ToUnicode mapping (the PDF rendered fine visually but the text
///      stream is gibberish). 0 = clean, 1 = all garbage.
///   2. **Single-char "word" ratio** — fraction of whitespace-split
///      tokens that are exactly one character long. High when glyphs
///      were extracted individually with spurious spacing rather than
///      as real words.
///   3. **Language confidence** — `NLLanguageRecognizer`'s probability
///      for its dominant-language guess. Real prose hits ≥ 0.9 in any
///      supported script; nonsense / mojibake collapses to ~0.
///
/// Combined: `(1 − 4·mojibake) · (1 − 2·singleChar) · langConfidence`,
/// clamped to [0, 1]. Hand-tuned so realistic problem cases (1–2 %
/// mojibake, occasional single-char tokens) still cross the trust
/// threshold; gibberish doesn't.
public struct EmbeddedTextQualityScorer {
    public enum Verdict: String, Sendable, Equatable {
        case trust  // skip Vision OCR — embedded text is good enough
        case reocr  // run Vision (and gap-fill from embedded if any)
    }

    public struct Score: Sendable, Equatable {
        public var combined: Double           // 0…1
        public var mojibakeRatio: Double      // 0 = none, 1 = all
        public var singleCharWordRatio: Double // 0 = none, 1 = all
        public var languageConfidence: Double // 0…1
        public var dominantLanguage: String?  // BCP-47 code or nil
        public var totalCharCount: Int
        public var totalWordCount: Int
        public var verdict: Verdict
    }

    /// Combined score must reach this to flip into the trust path.
    public var trustThreshold: Double
    /// Pages with very little embedded text always get re-OCR'd —
    /// scoring on a handful of chars is too noisy.
    public var minCharsForTrust: Int

    public init(trustThreshold: Double = 0.75, minCharsForTrust: Int = 200) {
        self.trustThreshold = trustThreshold
        self.minCharsForTrust = minCharsForTrust
    }

    public func score(text: String) -> Score {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Score(
                combined: 0, mojibakeRatio: 0, singleCharWordRatio: 0,
                languageConfidence: 0, dominantLanguage: nil,
                totalCharCount: 0, totalWordCount: 0, verdict: .reocr
            )
        }

        // Mojibake: count chars that are U+FFFD or in a Private Use Area.
        let totalChars = trimmed.unicodeScalars.count
        let mojibakeChars = trimmed.unicodeScalars.lazy.filter(Self.isMojibake).count
        let mojibakeRatio = Double(mojibakeChars) / Double(totalChars)

        // Word stats: whitespace-split tokens; ratio of single-char ones.
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        let totalWords = words.count
        let singleCharWords = words.lazy.filter { $0.count == 1 }.count
        let singleCharWordRatio = totalWords > 0
            ? Double(singleCharWords) / Double(totalWords)
            : 0

        // Language confidence via macOS Natural Language framework.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let dominant = recognizer.dominantLanguage
        let langConfidence: Double
        if let dominant {
            langConfidence = recognizer.languageHypotheses(withMaximum: 5)[dominant] ?? 0
        } else {
            langConfidence = 0
        }

        // Combine. Penalties are aggressive on the bad signals so a
        // small amount of garbage tanks the score quickly.
        let mojibakePenalty = max(0, 1 - 4 * mojibakeRatio)
        let singleCharPenalty = max(0, 1 - 2 * singleCharWordRatio)
        let combined = max(0, min(1, mojibakePenalty * singleCharPenalty * langConfidence))

        let verdict: Verdict =
            (combined >= trustThreshold && totalChars >= minCharsForTrust)
            ? .trust : .reocr

        return Score(
            combined: combined,
            mojibakeRatio: mojibakeRatio,
            singleCharWordRatio: singleCharWordRatio,
            languageConfidence: langConfidence,
            dominantLanguage: dominant?.rawValue,
            totalCharCount: totalChars,
            totalWordCount: totalWords,
            verdict: verdict
        )
    }

    /// True if the scalar is the Unicode replacement char or sits in a
    /// Private Use Area block. The standard signal that a PDF's
    /// ToUnicode table is incomplete or wrong.
    static func isMojibake(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v == 0xFFFD { return true }
        if (0xE000...0xF8FF).contains(v) { return true }
        if (0xF0000...0xFFFFD).contains(v) { return true }
        if (0x100000...0x10FFFD).contains(v) { return true }
        return false
    }
}
