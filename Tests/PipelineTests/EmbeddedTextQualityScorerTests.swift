import XCTest
@testable import PDFIngest

final class EmbeddedTextQualityScorerTests: XCTestCase {

    func test_clean_english_prose_scores_trust() {
        let text = """
        This is a paragraph of clean English prose. It contains a couple of \
        sentences with proper words, normal punctuation, and a length sufficient \
        to give the language recognizer something solid to work with. We expect \
        the scorer to mark this page as trustworthy and skip Vision OCR.
        """
        let score = EmbeddedTextQualityScorer().score(text: text)

        XCTAssertEqual(score.verdict, .trust)
        XCTAssertGreaterThan(score.combined, 0.75)
        XCTAssertEqual(score.mojibakeRatio, 0)
        // Natural English contains some single-char words ("a", "I"); keep
        // the bar realistic.
        XCTAssertLessThan(score.singleCharWordRatio, 0.10)
        XCTAssertGreaterThan(score.languageConfidence, 0.85)
        XCTAssertEqual(score.dominantLanguage, "en")
    }

    func test_empty_string_scores_zero_and_reocrs() {
        let score = EmbeddedTextQualityScorer().score(text: "")
        XCTAssertEqual(score.verdict, .reocr)
        XCTAssertEqual(score.combined, 0)
    }

    func test_mojibake_dominated_text_scores_reocr() {
        // Half the chars are U+FFFD — what you get from a PDF with a
        // broken ToUnicode mapping where PDFKit returned glyph indices
        // it couldn't map.
        let text = String(repeating: "\u{FFFD}", count: 100) + " hello world"
        let score = EmbeddedTextQualityScorer().score(text: text)
        XCTAssertEqual(score.verdict, .reocr)
        XCTAssertGreaterThan(score.mojibakeRatio, 0.5)
        XCTAssertLessThan(score.combined, 0.4)
    }

    func test_pua_chars_count_as_mojibake() {
        // Private Use Area chars (E000-F8FF) are the OTHER classic
        // sign of a broken encoding — PDF rendered fine but the text
        // stream points into a custom font's PUA region.
        let pua: Character = Character(UnicodeScalar(0xE000)!)
        let text = String(repeating: String(pua), count: 50) + " " + String(repeating: "x ", count: 50)
        let score = EmbeddedTextQualityScorer().score(text: text)
        XCTAssertGreaterThan(score.mojibakeRatio, 0.0)
        XCTAssertEqual(score.verdict, .reocr)
    }

    func test_glyph_by_glyph_extraction_scores_reocr() {
        // Single-char tokens are what you get when the extractor split
        // by glyph rather than by word. Lots of standalone letters →
        // very high single-char ratio → drops below trust.
        let text = String(repeating: "a b c d e f g h i j k l m n o p ",
                          count: 30)
        let score = EmbeddedTextQualityScorer().score(text: text)
        XCTAssertGreaterThan(score.singleCharWordRatio, 0.9)
        XCTAssertEqual(score.verdict, .reocr)
    }

    func test_short_text_below_minChars_does_not_trust_even_if_clean() {
        // Even crystal-clear prose — if there's barely any of it,
        // we don't have enough signal to confidently skip OCR.
        let text = "Short clean text."
        let score = EmbeddedTextQualityScorer(minCharsForTrust: 200).score(text: text)
        XCTAssertEqual(score.verdict, .reocr)
        // Combined score itself can be high — verdict gates on length.
        XCTAssertGreaterThan(score.combined, 0.0)
    }

    // MARK: - Language gates

    func test_language_mismatch_downgrades_trust_to_reocr() {
        // Clean English prose, but the user said the document is Turkish.
        // Either their hint is wrong or the embedded text is from an
        // earlier bad-OCR pass that picked the wrong language. Either
        // way, re-OCR.
        let text = """
        This is a paragraph of clean English prose. It contains a couple of \
        sentences with proper words, normal punctuation, and a length sufficient \
        to give the language recognizer something solid to work with.
        """
        let score = EmbeddedTextQualityScorer().score(
            text: text, expectedLanguages: ["tr"]
        )
        XCTAssertEqual(score.verdict, .reocr)
        XCTAssertEqual(score.dominantLanguage, "en")
    }

    func test_language_match_preserves_trust() {
        // Same text, matching hint — trust path stays.
        let text = """
        This is a paragraph of clean English prose. It contains a couple of \
        sentences with proper words, normal punctuation, and a length sufficient \
        to give the language recognizer something solid to work with.
        """
        let score = EmbeddedTextQualityScorer().score(
            text: text, expectedLanguages: ["en"]
        )
        XCTAssertEqual(score.verdict, .trust)
    }

    func test_grc_hint_with_modern_greek_detection_still_trusts() {
        // Polytonic (Ancient) Greek is consistently identified as
        // Modern Greek (`el`) by NLLanguageRecognizer because they
        // share the same script. The confusable allowlist keeps these
        // pages on the trust path when the user hinted `grc`.
        // Use a long-enough modern Greek passage (which is what the
        // recognizer will see) so we cross minCharsForTrust.
        let text = """
        Αυτή είναι μια παράγραφος καθαρού ελληνικού κειμένου με αρκετές \
        προτάσεις, σωστή στίξη και επαρκές μήκος ώστε ο αναγνωριστής \
        γλώσσας να έχει σταθερά στοιχεία για να αποφανθεί. Περιμένουμε \
        ο βαθμολογητής να εμπιστευτεί αυτό το αντίγραφο και να παρακάμψει \
        την οπτική αναγνώριση χαρακτήρων.
        """
        let score = EmbeddedTextQualityScorer().score(
            text: text, expectedLanguages: ["grc"]
        )
        XCTAssertEqual(score.dominantLanguage, "el")
        XCTAssertEqual(score.verdict, .trust)
    }

    func test_el_hint_does_not_accept_other_languages() {
        // Allowlist is asymmetric: `grc` accepts `el`, but `el` does
        // not accept anything other than itself (or its own primary
        // subtag variants). A user who hinted Modern Greek and got a
        // page identified as English is a real mismatch.
        let text = """
        This is a paragraph of clean English prose. It contains a couple of \
        sentences with proper words, normal punctuation, and a length sufficient \
        to give the language recognizer something solid to work with.
        """
        let score = EmbeddedTextQualityScorer().score(
            text: text, expectedLanguages: ["el"]
        )
        XCTAssertEqual(score.verdict, .reocr)
    }

    func test_la_hint_accepts_romance_descendants() {
        // Latin is frequently misidentified as Italian / Spanish by
        // NLLanguageRecognizer — the allowlist treats Romance descendants
        // as a match so genuine Latin pages aren't pushed off the trust
        // path. Italian text stands in here for what NLR returns on a
        // Latin passage; the point is the allowlist mapping.
        let text = """
        Questo è un paragrafo di prosa pulita, con frasi complete, una \
        punteggiatura adeguata e una lunghezza sufficiente perché il \
        riconoscitore di lingua disponga di segnali stabili. Ci aspettiamo \
        che il punteggio confermi la fiducia e salti l'OCR.
        """
        let score = EmbeddedTextQualityScorer().score(
            text: text, expectedLanguages: ["la"]
        )
        // Whatever NLR detects, allowlist should let the verdict through.
        XCTAssertEqual(score.verdict, .trust)
    }

    func test_empty_expected_languages_disables_mismatch_gate() {
        // No hints → mismatch gate does nothing; the language-confidence
        // floor remains the only language-aware check.
        let text = """
        This is a paragraph of clean English prose. It contains a couple of \
        sentences with proper words, normal punctuation, and a length sufficient \
        to give the language recognizer something solid to work with.
        """
        let score = EmbeddedTextQualityScorer().score(
            text: text, expectedLanguages: []
        )
        XCTAssertEqual(score.verdict, .trust)
    }

    func test_no_arg_score_method_is_equivalent_to_empty_expected() {
        // Backwards-compatible overload should produce the same verdict
        // and combined score as passing an empty expected list.
        let text = """
        This is a paragraph of clean English prose. It contains a couple of \
        sentences with proper words, normal punctuation, and a length sufficient \
        to give the language recognizer something solid to work with.
        """
        let scorer = EmbeddedTextQualityScorer()
        let a = scorer.score(text: text)
        let b = scorer.score(text: text, expectedLanguages: [])
        XCTAssertEqual(a.verdict, b.verdict)
        XCTAssertEqual(a.combined, b.combined)
    }

    func test_language_match_uses_primary_subtag() {
        // Both detected and expected get normalized to primary subtag,
        // so "en-US" hint matches detected "en".
        XCTAssertTrue(
            EmbeddedTextQualityScorer.languageMatches(
                detected: "en", expected: ["en-US"]
            )
        )
        XCTAssertTrue(
            EmbeddedTextQualityScorer.languageMatches(
                detected: "EN", expected: ["en"]
            )
        )
    }
}
