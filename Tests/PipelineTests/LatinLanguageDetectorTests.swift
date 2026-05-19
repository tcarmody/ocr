import XCTest
import Document
@testable import Pipeline

/// P-Verse-Layout. Per-fragment language detection for Latin-
/// script text among {French, Spanish, German, Italian, English}.
/// Designed to under-tag (return nil) rather than mis-tag —
/// false positives in lang attributes have no visible cost in
/// most readers but mess up screen-reader pronunciation and
/// would clutter the entity index for chat retrieval.
final class LatinLanguageDetectorTests: XCTestCase {

    // MARK: - Unique-character signals

    func test_spanish_detected_by_n_with_tilde() {
        XCTAssertEqual(
            LatinLanguageDetector.detect("España"), BCP47("es")
        )
        XCTAssertEqual(
            LatinLanguageDetector.detect("año"), BCP47("es")
        )
    }

    func test_spanish_detected_by_inverted_punctuation() {
        XCTAssertEqual(
            LatinLanguageDetector.detect("¿Cómo estás?"), BCP47("es")
        )
        XCTAssertEqual(
            LatinLanguageDetector.detect("¡Hola!"), BCP47("es")
        )
    }

    func test_german_detected_by_eszett() {
        XCTAssertEqual(
            LatinLanguageDetector.detect("Straße"), BCP47("de")
        )
        XCTAssertEqual(
            LatinLanguageDetector.detect("ich heiße"), BCP47("de")
        )
    }

    func test_french_detected_by_oe_ligature() {
        XCTAssertEqual(
            LatinLanguageDetector.detect("œuvre"), BCP47("fr")
        )
    }

    func test_french_detected_by_cedilla() {
        XCTAssertEqual(
            LatinLanguageDetector.detect("ça"), BCP47("fr")
        )
        XCTAssertEqual(
            LatinLanguageDetector.detect("français"), BCP47("fr")
        )
    }

    // MARK: - Italian markers

    func test_italian_detected_by_della_marker() {
        XCTAssertEqual(
            LatinLanguageDetector.detect("della Repubblica"),
            BCP47("it")
        )
    }

    func test_italian_detected_by_degli_marker() {
        XCTAssertEqual(
            LatinLanguageDetector.detect("degli uomini"),
            BCP47("it")
        )
    }

    func test_italian_detected_by_gli_marker() {
        // Pound-shaped short fragment.
        XCTAssertEqual(
            LatinLanguageDetector.detect("gli occhi"), BCP47("it")
        )
    }

    func test_italian_perche_with_accent() {
        XCTAssertEqual(
            LatinLanguageDetector.detect("non so perché"),
            BCP47("it")
        )
    }

    func test_marker_match_is_word_bounded() {
        // "modello" contains "dello" as a substring — must not
        // tag as Italian.
        XCTAssertNil(LatinLanguageDetector.detect("modello"))
    }

    // MARK: - Longer fragments via NLLanguageRecognizer

    func test_long_french_sentence() {
        let text = "Il était une fois une petite fille qui voulait voir le monde."
        XCTAssertEqual(LatinLanguageDetector.detect(text), BCP47("fr"))
    }

    func test_long_german_sentence() {
        let text = "Es war einmal ein Mann der wollte die ganze Welt sehen."
        XCTAssertEqual(LatinLanguageDetector.detect(text), BCP47("de"))
    }

    func test_long_spanish_sentence() {
        let text = "Era una vez una pequeña que quería ver el mundo entero."
        XCTAssertEqual(LatinLanguageDetector.detect(text), BCP47("es"))
    }

    func test_long_italian_sentence() {
        let text = "Era una volta una piccola che voleva vedere il mondo intero."
        XCTAssertEqual(LatinLanguageDetector.detect(text), BCP47("it"))
    }

    func test_long_english_returns_nil() {
        // English fragments stay untagged so the parent block's
        // English lang attribute applies. Tagging English inside
        // an English book is redundant + clutters output.
        let text = "It was the best of times it was the worst of times."
        XCTAssertNil(LatinLanguageDetector.detect(text))
    }

    // MARK: - Under-tag bias

    func test_short_ambiguous_fragment_returns_nil() {
        // Just "le monde" — could be French. Below 25 chars, no
        // unique chars, no Italian markers. Under-tag.
        XCTAssertNil(LatinLanguageDetector.detect("le monde"))
    }

    func test_pure_ascii_short_fragment_returns_nil() {
        XCTAssertNil(LatinLanguageDetector.detect("the cat"))
    }

    func test_empty_string_returns_nil() {
        XCTAssertNil(LatinLanguageDetector.detect(""))
    }
}

/// Polytonic vs monotonic Greek distinction in VerseDetector.
final class GreekVariantTests: XCTestCase {

    func test_polytonic_promotes_to_grc() {
        // αὖθις contains ὖ (U+1F56, Greek Extended).
        XCTAssertEqual(
            VerseDetector.greekVariant(of: "αὖθις"), BCP47("grc")
        )
    }

    func test_monotonic_defaults_to_el() {
        // αυθις with no polytonic marks — would-be ancient
        // Greek with diacritics stripped, OR genuine modern
        // Greek. Detector defaults to el; the OCR-dropped-
        // diacritics case is a known caveat (PLANS).
        XCTAssertEqual(
            VerseDetector.greekVariant(of: "αυθις"), BCP47("el")
        )
    }

    func test_modern_greek_with_tonos_only_is_el() {
        // Καλημέρα — modern Greek; the tonos accent on έ lives
        // in the base Greek block (U+0370–U+03FF), so no
        // polytonic chars trigger the grc upgrade.
        XCTAssertEqual(
            VerseDetector.greekVariant(of: "Καλημέρα"), BCP47("el")
        )
    }

    func test_mixed_greek_with_any_polytonic_char_is_grc() {
        // Even one polytonic char in the segment promotes.
        XCTAssertEqual(
            VerseDetector.greekVariant(of: "Σίγα μαλ αὖθις"),
            BCP47("grc")
        )
    }
}
