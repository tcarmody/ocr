import XCTest
import PDFIngest

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
}
