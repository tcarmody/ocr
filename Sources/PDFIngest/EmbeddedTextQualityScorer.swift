import Foundation
import NaturalLanguage

/// Scores the quality of a PDF's embedded text layer per page so the
/// pipeline can decide whether to trust it (skip Vision OCR) or re-OCR
/// the rendered page image.
///
/// Three statistical signals, combined into a single 0…1 score:
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
///
/// Plus two language gates that downgrade `.trust` → `.reocr` even
/// when the combined score passes:
///
///   * **Language confidence floor.** `NLLanguageRecognizer`'s
///     confidence in its top guess must be ≥ `minLanguageConfidence`.
///     Catches structurally word-shaped gibberish that crosses the
///     mojibake / single-char gates but doesn't actually look like
///     any language.
///   * **Language mismatch.** When the caller passes expected
///     languages and the detected language doesn't match any of
///     them (with a small allowlist for known-confusable pairs like
///     ancient ↔ modern Greek), downgrade. Catches the case where
///     the embedded text is coherent but in the wrong language —
///     usually means the user mis-specified the language hint, but
///     also catches "this PDF's old OCR pass detected the wrong
///     language and produced consistent-looking gibberish."
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
    /// `NLLanguageRecognizer` confidence floor for the trust path.
    /// 0.5 catches "this could be any of five languages, none with
    /// high confidence" — usually a sign the text isn't really prose.
    public var minLanguageConfidence: Double

    public init(
        trustThreshold: Double = 0.75,
        minCharsForTrust: Int = 200,
        minLanguageConfidence: Double = 0.5
    ) {
        self.trustThreshold = trustThreshold
        self.minCharsForTrust = minCharsForTrust
        self.minLanguageConfidence = minLanguageConfidence
    }

    /// Backwards-compatible scorer with no language hints. Useful for
    /// callers that don't have language context (or for scoring
    /// arbitrary text fragments). Equivalent to passing
    /// `expectedLanguages: []` — the language-mismatch gate is then
    /// effectively disabled, leaving the language-confidence floor
    /// as the only language-aware check.
    public func score(text: String) -> Score {
        score(text: text, expectedLanguages: [])
    }

    /// Score with optional language hints. When `expectedLanguages`
    /// is non-empty, a language mismatch downgrades the verdict to
    /// `.reocr`. Hints are BCP-47 primary subtags; case-insensitive.
    public func score(text: String, expectedLanguages: [String]) -> Score {
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

        // Base verdict from the statistical signals.
        var verdict: Verdict =
            (combined >= trustThreshold && totalChars >= minCharsForTrust)
            ? .trust : .reocr

        // Language-confidence gate: even shaped gibberish can pass
        // the mojibake / single-char checks. If NLLanguageRecognizer
        // can't confidently identify *any* language, this isn't real
        // prose — re-OCR.
        if verdict == .trust, langConfidence < minLanguageConfidence {
            verdict = .reocr
        }

        // Language-mismatch gate: the user said the document is in
        // language X, but the embedded text reads as language Y.
        // Either the user's hint is wrong (re-OCR will catch it) or
        // the embedded text is itself a bad-OCR artifact (re-OCR
        // produces something better). Tolerate the small allowlist
        // of confusable pairs so polytonic-Greek (`grc`) PDFs whose
        // embedded text gets identified as modern Greek (`el`) still
        // trust through.
        if verdict == .trust,
           !expectedLanguages.isEmpty,
           let detected = dominant?.rawValue,
           !Self.languageMatches(detected: detected, expected: expectedLanguages) {
            verdict = .reocr
        }

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

    /// True when `detected` matches at least one of `expected`,
    /// after primary-subtag normalization and a small allowlist of
    /// known-confusable pairs that should NOT count as a mismatch
    /// for OCR purposes:
    ///
    /// - `grc` (Ancient Greek) ↔ `el` (Modern Greek) — same script;
    ///   `NLLanguageRecognizer` returns `el` on polytonic Greek.
    /// - `la` (Latin) ↔ Romance languages (`it`, `es`, `fr`, `pt`,
    ///   `ro`, `ca`) — Latin is frequently misidentified as the
    ///   nearest descendant.
    /// - `chu` (Old Church Slavonic) ↔ Slavic Cyrillic
    ///   (`ru`, `uk`, `bg`, `sr`).
    static func languageMatches(detected: String, expected: [String]) -> Bool {
        let detectedPrimary = primarySubtag(detected)
        let expectedPrimaries = expected.map(primarySubtag)
        if expectedPrimaries.contains(detectedPrimary) { return true }
        for exp in expectedPrimaries {
            if let allowed = confusableSubstitutes[exp],
               allowed.contains(detectedPrimary) {
                return true
            }
        }
        return false
    }

    /// Lowercased primary subtag of a BCP-47 string. `"en-US"` → `"en"`.
    static func primarySubtag(_ tag: String) -> String {
        let lower = tag.lowercased()
        if let dash = lower.firstIndex(of: "-") {
            return String(lower[..<dash])
        }
        return lower
    }

    /// For each primary subtag, the set of detected primary subtags
    /// that should still count as a match. Asymmetric on purpose:
    /// `grc` accepts `el`, but `el` doesn't accept `grc` — a user
    /// who picked Modern Greek probably actually has Modern Greek.
    static let confusableSubstitutes: [String: Set<String>] = [
        "grc": ["el"],
        "la":  ["it", "es", "fr", "pt", "ro", "ca"],
        "chu": ["ru", "uk", "bg", "sr"],
    ]

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
