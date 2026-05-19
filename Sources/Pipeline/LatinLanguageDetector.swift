import Foundation
import Document
import NaturalLanguage

/// P-Verse-Layout. Decides the BCP-47 language tag of a
/// Latin-script text fragment among {French, Spanish, German,
/// Italian, English}. Returns nil for fragments where the
/// signal is insufficient — caller leaves them untagged so the
/// parent block / book language applies (the safe fallback).
///
/// Three-tier detection, in order of confidence:
///
/// 1. **Unique-character signals** (highest confidence; works on
///    single-word fragments). `ñ`/`Ñ`/`¿`/`¡` → Spanish; `ß`/`ẞ`
///    → German; `œ`/`Œ` → French (uniquely French — not used in
///    Italian, Spanish, or German). `ç`/`Ç` defaults to French
///    after the Italian marker-word check (since `ç` is also
///    Catalan/Portuguese but in this app's literary-OCR
///    context French is by far the most common source).
///
/// 2. **Italian short-fragment markers** (`della`, `dello`,
///    `degli`, `delle`, `gli`, `agli`, …). These appear
///    essentially nowhere else and let us tag the canonical
///    Italian fragments that show up in literary verse (Pound,
///    Eliot, art history, opera quotations) even when they're
///    only 2–3 words long.
///
/// 3. **NLLanguageRecognizer fallback** for fragments ≥ 25
///    characters. Apple's recognizer is reliable past that
///    length when constrained to the supported set. Below 25
///    chars, the recognizer is noisy on short literary
///    fragments and we'd rather under-tag than mis-tag.
public enum LatinLanguageDetector {

    /// Minimum trimmed character count before
    /// `NLLanguageRecognizer` is consulted. Below this the
    /// recognizer's accuracy on isolated literary fragments
    /// drops to coin-flip levels.
    static let nlMinChars: Int = 25

    /// Return the BCP-47 tag for `text`, or nil when the signal
    /// isn't strong enough to commit. The caller assigns the
    /// parent block's language on nil.
    public static func detect(_ text: String) -> BCP47? {
        // Tier 1: unique-character signals.
        var sawSpanishMarker = false
        var sawGermanMarker = false
        var sawFrenchOeligMarker = false
        var sawCedilla = false
        for ch in text {
            switch ch {
            case "ñ", "Ñ", "¿", "¡": sawSpanishMarker = true
            case "ß", "ẞ":            sawGermanMarker = true
            case "œ", "Œ":            sawFrenchOeligMarker = true
            case "ç", "Ç":            sawCedilla = true
            default: break
            }
        }
        if sawSpanishMarker { return BCP47("es") }
        if sawGermanMarker  { return BCP47("de") }
        if sawFrenchOeligMarker { return BCP47("fr") }

        // Tier 2: hand-curated short-fragment markers. Word-
        // boundary lookup, case-insensitive. Italian is the
        // canonical case here; the other languages either have
        // unique chars (already caught) or are well-covered by
        // the NL fallback.
        let lower = text.lowercased()
        if containsAnyMarker(lower, markers: Self.italianMarkers) {
            return BCP47("it")
        }

        // Cedilla defaults to French only after Italian markers
        // had their chance — Italian doesn't use `ç` but a few
        // loanwords could otherwise pull a Spanish or Catalan
        // citation into the French bucket unintentionally.
        if sawCedilla { return BCP47("fr") }

        // Tier 3: NLLanguageRecognizer for longer fragments.
        // Constrained to the supported set + English so the
        // recognizer doesn't reach for an exotic match.
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.count >= nlMinChars else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [
            .italian, .french, .spanish, .german, .english
        ]
        recognizer.processString(trimmed)
        guard let dom = recognizer.dominantLanguage else { return nil }
        // Demand a moderate confidence level before committing.
        // The recognizer can return a dominant language with
        // very low probability on borderline input — taking the
        // confidence guards against tagging a 26-char English
        // fragment as French because of one accent.
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        let confidence = hypotheses[dom] ?? 0
        guard confidence >= 0.60 else { return nil }
        switch dom {
        case .italian: return BCP47("it")
        case .french:  return BCP47("fr")
        case .spanish: return BCP47("es")
        case .german:  return BCP47("de")
        // English: deliberate nil. The parent block's language
        // is already English (or whatever the book's primary
        // language is); tagging an English fragment "en" inside
        // an English book is redundant and would clutter the
        // XHTML output.
        case .english: return nil
        default:       return nil
        }
    }

    /// Italian-only short-fragment markers. Each token is
    /// essentially unique to Italian among the languages this
    /// app encounters — definite-article + preposition
    /// contractions (`della`, `dello`, `degli`, `delle`,
    /// `agli`, `dagli`, `negli`), the masculine-plural article
    /// `gli`, common conjugations (`sono`, `siamo`, `siete`),
    /// and the perché/poiché interrogative family.
    static let italianMarkers: Set<String> = [
        "della", "dello", "degli", "delle",
        "agli", "dagli", "negli", "sugli",
        "gli",
        "sono", "siamo", "siete",
        "questo", "questa", "questi", "queste",
        "perché", "poiché", "benché", "sicché",
    ]

    /// True when `text` (already lowercased) contains any of
    /// `markers` as a standalone word — bounded on each side by
    /// whitespace, punctuation, or string boundary. Substring
    /// match would mis-fire on words like "delle" containing
    /// "lle"; this approach matches "della" inside "della casa"
    /// but not inside "modella".
    static func containsAnyMarker(
        _ text: String, markers: Set<String>
    ) -> Bool {
        // Split on whitespace and ASCII punctuation, then strip
        // any leading/trailing punctuation that survived. Set
        // lookup keeps this O(n) over token count.
        let tokens = text
            .components(
                separatedBy: Self.tokenSeparators
            )
            .map { token -> String in
                token.trimmingCharacters(in: Self.tokenStripCharacters)
            }
            .filter { !$0.isEmpty }
        for token in tokens where markers.contains(token) {
            return true
        }
        return false
    }

    private static let tokenSeparators = CharacterSet.whitespacesAndNewlines
    /// Characters stripped from token ends after splitting. Real
    /// punctuation marks plus the curly-quote / dash variants
    /// common in literary text.
    private static let tokenStripCharacters = CharacterSet(
        charactersIn: ".,;:!?\"'\u{201C}\u{201D}\u{2018}\u{2019}()[]{}\u{2014}\u{2013}\u{2026}"
    )
}
