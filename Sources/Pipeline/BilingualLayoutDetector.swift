import Foundation
import NaturalLanguage
import OCR
import os

/// Logger so bilingual-detection decisions are visible in Console.app
/// without needing the debug-log sidecar. The body of a positive
/// detection (languages, alternation rate, pair count) is the
/// minimum we'd want to inspect when investigating a false trip on
/// a real book.
private let bilingualLog = Logger(
    subsystem: "com.tcarmody.Humanist",
    category: "BilingualLayoutDetector"
)

/// Detects bilingual facing-page books (Loeb Classical Library style:
/// verso carries the original text, recto carries the English
/// translation, repeating across the body). Output is consumed by
/// the EPUB writer to emit `data-facing-page` attributes on page
/// anchors, and by the (future) reorganization pass that splits the
/// two streams into parallel chapter trees.
///
/// **Conservative by design.** False positives — treating a
/// monolingual book as bilingual — would corrupt navigation and
/// reorganization for an entire book. False negatives just leave
/// the book on the normal path, which is fine. The detector
/// therefore requires:
///   * L1 is one of grc / la / he / el (the classical-source
///     languages this feature targets; el covers both modern and
///     polytonic Greek since `NLLanguageRecognizer` folds them), and
///   * ≥ 80% of adjacent body-page pairs alternate L1/L2.
///
/// Pages that are too short to score reliably (front matter,
/// section dividers, blank pages) are excluded from the
/// alternation count rather than counted as failures.
///
/// **Why NLLanguageRecognizer alone wasn't enough.** Apple's NLR has
/// no Latin classifier; it returns the nearest Romance language
/// (commonly `ca`/`it`/`ro`) with low confidence on classical Latin
/// passages. It also returns `el` indiscriminately for both modern
/// Greek and polytonic ancient Greek. We therefore layer:
///   * Unicode-script ratios for Greek and Hebrew (reliable: both
///     scripts are visually distinct from the surrounding English
///     translation).
///   * A Latin function-word fingerprint that distinguishes
///     classical Latin from the Romance languages NLR misroutes it
///     to.
public enum BilingualLayoutDetector {

    /// Detection result. Nil from `detect(...)` when no bilingual
    /// layout was identified at the required confidence.
    public struct Layout: Sendable, Equatable {
        /// BCP-47 primary subtag of the source-language stream
        /// (e.g. `grc`, `la`, `he`, `el`).
        public let l1Language: String
        /// BCP-47 primary subtag of the translation stream
        /// (typically `en`).
        public let l2Language: String
        /// Symmetric map: `pdfPage → partner pdfPage`. Each entry
        /// appears twice (a→b and b→a). Use this to look up the
        /// facing page from either side.
        public let pagePartners: [Int: Int]
        /// Per-page language assignment. Pages with no confident
        /// assignment are absent — short pages, blanks, etc.
        public let pageLanguage: [Int: String]
        /// Fraction of adjacent body-page pairs that alternated
        /// L1/L2. Always ≥ `alternationThreshold` for a returned
        /// Layout.
        public let alternationRate: Double
    }

    /// Classical source languages eligible to serve as L1. The
    /// targeted use case is Loeb Classical Library and similar
    /// scholarly bilingual editions where the original is one of
    /// these. `el` is included because NLLanguageRecognizer maps
    /// polytonic ancient Greek to it (and modern Greek bilingual
    /// poetry editions are a legitimate target too). Broadening
    /// the set further (e.g. to Russian or French) requires
    /// reconsidering the false-positive risk for normal books that
    /// quote those languages.
    public static let eligibleL1: Set<String> = ["grc", "la", "he", "el"]

    /// Required fraction of adjacent body-page pairs that
    /// alternate L1/L2. 0.80 keeps the gate tight enough that a
    /// quotation-heavy monolingual book (Greek scattered through
    /// an English commentary, etc.) doesn't trip the detector.
    public static let alternationThreshold: Double = 0.80

    /// Below this many characters a page is considered too short
    /// to score reliably and is excluded from the alternation
    /// count. Matches `DocumentProfiler.minSampleChars`.
    public static let minPageChars: Int = 100

    /// Minimum confidence from `NLLanguageRecognizer` for a page
    /// to count as a confident English-or-modern classification.
    /// Greek / Hebrew / Latin use their own gates below.
    public static let minPageConfidence: Double = 0.55

    /// Minimum number of confidently-classified body pages
    /// before the detector will even attempt to emit a result.
    /// A two- or three-page sample is too small to trust.
    public static let minBodyPages: Int = 10

    /// Minimum fraction of letter characters in the Greek or
    /// Hebrew Unicode block for the page to be classified as
    /// `grc` / `he`. 0.30 leaves room for embedded English page
    /// numbers, headers, and apparatus marks while still firing
    /// on a substantially-Greek (or substantially-Hebrew) page.
    static let minScriptRatio: Double = 0.30

    /// Run detection across the OCR'd `pageResults`. Returns nil
    /// when the book doesn't meet the facing-page criteria; the
    /// caller should fall through to the normal monolingual path.
    static func detect(
        pageResults: [PageObservations]
    ) -> Layout? {
        guard pageResults.count >= minBodyPages else { return nil }

        // 1. Classify each page's dominant language. Pages too
        //    short to score reliably remain absent from the map.
        var pageLanguage: [Int: String] = [:]
        for page in pageResults {
            let joined = page.observations
                .map(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard joined.count >= minPageChars else { continue }
            if let lang = classifyPage(text: joined) {
                pageLanguage[page.pageIndex] = lang
            }
        }

        // 2. Tally counts per language so we can identify L1 + L2
        //    candidates by frequency.
        var counts: [String: Int] = [:]
        for lang in pageLanguage.values {
            counts[lang, default: 0] += 1
        }
        // Need a classical L1 with substantial presence.
        let classicalCandidates = counts
            .filter { eligibleL1.contains($0.key) }
            .sorted { $0.value > $1.value }
        guard let (l1, l1Count) = classicalCandidates.first else { return nil }
        // The classical stream must be ≥ ~25% of confidently-
        // classified body pages. Catches the case where a long
        // English book has one Greek chapter — that's not a
        // facing-page bilingual.
        let confidentTotal = pageLanguage.count
        guard Double(l1Count) >= 0.25 * Double(confidentTotal) else {
            return nil
        }
        // L2 = most common non-L1 language, restricted to
        // non-classical to avoid the (grc, la) case where both
        // sides are classical (vanishingly rare for facing-page
        // bilinguals; if encountered, we can revisit).
        let l2Candidates = counts
            .filter { $0.key != l1 && !eligibleL1.contains($0.key) }
            .sorted { $0.value > $1.value }
        guard let (l2, _) = l2Candidates.first else { return nil }

        // 3. Walk adjacent pairs of confidently-classified body
        //    pages and count alternations. We restrict to pages
        //    that classified as either L1 or L2 (a Greek-Greek-
        //    English run from a long preface shouldn't pollute
        //    the rate).
        let sortedPages = pageLanguage.keys.sorted()
            .filter { pageLanguage[$0] == l1 || pageLanguage[$0] == l2 }
        guard sortedPages.count >= minBodyPages else { return nil }

        // Tally alternation, and decide which orientation
        // (L1→L2 vs L2→L1) is dominant. The dominant orientation
        // is the layout's "spread" direction — facing-page
        // editions almost always pair verso (L1) with the
        // recto immediately following (L2), but a few editions
        // invert this so we let the data decide.
        var alternatingPairs = 0
        var totalPairs = 0
        var l1FirstPairs = 0
        var l2FirstPairs = 0
        for i in 0..<(sortedPages.count - 1) {
            let a = sortedPages[i]
            let b = sortedPages[i + 1]
            // Only count pairs that are adjacent in the PDF
            // (consecutive page indices). A gap usually means
            // an unscored page sat between — those are likely
            // front matter / blank inserts / section dividers
            // and shouldn't drive the rate either way.
            guard b == a + 1 else { continue }
            totalPairs += 1
            let la = pageLanguage[a]!
            let lb = pageLanguage[b]!
            if la != lb {
                alternatingPairs += 1
                if la == l1 { l1FirstPairs += 1 } else { l2FirstPairs += 1 }
            }
        }
        guard totalPairs >= minBodyPages else { return nil }
        let rate = Double(alternatingPairs) / Double(totalPairs)
        guard rate >= alternationThreshold else { return nil }
        // l1OnVerso = true when the dominant spread starts with L1
        // (the Loeb convention). When inverted, the recto carries
        // the original and the verso the translation.
        let l1OnVerso = l1FirstPairs >= l2FirstPairs

        // Build symmetric partners by walking the spreads. Each
        // spread is two consecutive pages; we step by 2 so a page
        // can only belong to one spread (no chains, no overlap).
        var partners: [Int: Int] = [:]
        var i = 0
        while i < sortedPages.count - 1 {
            let a = sortedPages[i]
            let b = sortedPages[i + 1]
            guard b == a + 1 else { i += 1; continue }
            let la = pageLanguage[a]!
            let lb = pageLanguage[b]!
            guard la != lb else { i += 1; continue }
            // Honor the dominant spread orientation. A pair that
            // matches it forms a spread; a pair in the wrong
            // direction is an off-by-one artifact (e.g. an inserted
            // blank page) and is left unpaired so the spread grid
            // realigns at the next valid pair.
            let matchesOrientation = l1OnVerso
                ? (la == l1 && lb == l2)
                : (la == l2 && lb == l1)
            if matchesOrientation {
                partners[a] = b
                partners[b] = a
                i += 2
            } else {
                i += 1
            }
        }

        let layout = Layout(
            l1Language: l1,
            l2Language: l2,
            pagePartners: partners,
            pageLanguage: pageLanguage,
            alternationRate: rate
        )
        bilingualLog.info("""
            facing-page bilingual detected: \
            L1=\(l1, privacy: .public) (\(l1Count) pages), \
            L2=\(l2, privacy: .public), \
            alternation=\(rate, format: .fixed(precision: 2), privacy: .public), \
            pairs=\(alternatingPairs)/\(totalPairs, privacy: .public)
            """)
        return layout
    }

    /// Layered language classifier for one page of OCR text.
    /// Returns a BCP-47 primary subtag or nil when no classifier
    /// fires confidently. Order matters: script-based gates run
    /// before NLR because NLR returns `el` for any Greek input
    /// (so we'd lose the Greek/Hebrew distinction otherwise) and
    /// returns a confused Romance-language guess for Latin.
    static func classifyPage(text: String) -> String? {
        // Greek script — polytonic ancient + monotonic modern
        // both land here. Reliable when ≥30% of letter chars
        // are in the Greek block.
        if scriptRatio(text, in: greekRange) >= minScriptRatio {
            return "grc"
        }
        // Hebrew script — same gate.
        if scriptRatio(text, in: hebrewRange) >= minScriptRatio {
            return "he"
        }
        // Latin alphabet path. We use a function-word fingerprint
        // before NLR because NLR misroutes Latin to Catalan /
        // Italian / Romanian (no Latin classifier in the model).
        if isLikelyLatin(text) {
            return "la"
        }
        // Fall through to NLR for English and other modern
        // languages. The threshold here applies only to this
        // path; the script gates above don't use it.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let conf = recognizer.languageHypotheses(withMaximum: 5)[dominant] ?? 0
        guard conf >= minPageConfidence else { return nil }
        return dominant.rawValue
    }

    /// Fraction of letter characters in `text` that fall inside
    /// the given Unicode scalar range. Non-letter characters
    /// (digits, punctuation, whitespace) are excluded from the
    /// denominator so a few embedded page numbers don't push
    /// the ratio under threshold.
    static func scriptRatio(
        _ text: String,
        in range: ClosedRange<Unicode.Scalar>
    ) -> Double {
        var letters = 0
        var inRange = 0
        for scalar in text.unicodeScalars {
            // CharacterSet.letters covers Greek, Hebrew, Latin,
            // Cyrillic — anything Unicode classifies as a letter.
            guard CharacterSet.letters.contains(scalar) else { continue }
            letters += 1
            if range.contains(scalar) { inRange += 1 }
        }
        guard letters > 0 else { return 0 }
        return Double(inRange) / Double(letters)
    }

    /// Greek + Greek Extended Unicode blocks (covers monotonic,
    /// polytonic, archaic). Excludes Coptic which shares a Unicode
    /// neighborhood — Coptic editions aren't currently a target.
    private static let greekRange: ClosedRange<Unicode.Scalar> =
        Unicode.Scalar(0x0370)!...Unicode.Scalar(0x03FF)!

    /// Hebrew + Hebrew presentation forms (covers Biblical + Modern
    /// Hebrew, vocalized + unvocalized).
    private static let hebrewRange: ClosedRange<Unicode.Scalar> =
        Unicode.Scalar(0x0590)!...Unicode.Scalar(0x05FF)!

    /// Recognize classical Latin via a function-word fingerprint.
    /// We need this because NLLanguageRecognizer has no Latin
    /// classifier — Caesar's `Bello Gallico` opening comes back
    /// as `ca` (Catalan) at ~50% confidence.
    ///
    /// Heuristic: count distinct function words present + count
    /// nominal-ending tokens. A page that hits ≥4 distinct
    /// function words OR has ≥10% of its tokens matching the
    /// nominal-ending set is called Latin. The two-gate design
    /// catches both prose-heavy passages (many function words)
    /// and noun-heavy passages (catalogs, lists) where function
    /// words are sparse but inflection is dense.
    ///
    /// Verified to not trip on the English / French / Italian /
    /// Spanish equivalents of test passages.
    static func isLikelyLatin(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let tokens = lowered.split { !$0.isLetter }
        guard tokens.count >= 20 else { return false }

        var fwHits: Set<String> = []
        var inflectionHits = 0
        for token in tokens {
            let s = String(token)
            if latinFunctionWords.contains(s) {
                fwHits.insert(s)
            }
            for suffix in latinNominalEndings {
                if s.count > suffix.count + 1, s.hasSuffix(suffix) {
                    inflectionHits += 1
                    break
                }
            }
        }
        let inflectionRate = Double(inflectionHits) / Double(tokens.count)
        return fwHits.count >= 4 || inflectionRate >= 0.10
    }

    /// Closed set of classical Latin function words. Chosen for
    /// being (a) extremely common in classical prose, (b) not
    /// also frequent in modern English, French, Italian, Spanish.
    /// `et` and `in` overlap with French / English respectively
    /// but the *combination* of multiple hits is what gates the
    /// classifier.
    private static let latinFunctionWords: Set<String> = [
        "et", "est", "in", "ad", "qui", "quae", "quod", "non", "sed",
        "cum", "ab", "ex", "atque", "neque", "sunt", "esse", "ut",
        "autem", "enim", "vel", "aut", "nec", "ipsa", "ipsum", "ipse",
        "hic", "haec", "hoc", "ille", "illa", "illud", "tamen",
        "etiam", "quoque", "inter", "per", "post", "ante", "ex", "de",
    ]

    /// Latin nominal / verbal endings rarely seen in modern
    /// Romance languages or English. The classifier counts tokens
    /// ending in any of these (with at least one character of
    /// stem to avoid matching the suffix as the whole word).
    private static let latinNominalEndings: [String] = [
        "us", "um", "is", "ae", "am", "em", "is", "os", "orum",
        "arum", "ibus", "ius", "ium", "ere", "isse", "atur",
        "antur", "untur",
    ]
}
