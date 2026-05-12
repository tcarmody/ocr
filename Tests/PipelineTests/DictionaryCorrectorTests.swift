import XCTest
@testable import Pipeline

/// `DictionaryCorrector` tests — focus on the deterministic parts
/// (script classification, casing, language resolution, token
/// guards). The end-to-end `correct(_:)` path goes through
/// NSSpellChecker via IPC; testing that requires the live spell
/// server and would be flaky in CI, so we leave it for manual
/// verification.
final class DictionaryCorrectorTests: XCTestCase {

    // MARK: - Script classification

    func test_latin_script_words_pass() {
        XCTAssertTrue(DictionaryCorrector.isLatinScript("hello"))
        XCTAssertTrue(DictionaryCorrector.isLatinScript("café"))
        XCTAssertTrue(DictionaryCorrector.isLatinScript("naïve"))
        // Latin Extended-A includes Polish, Czech, etc.
        XCTAssertTrue(DictionaryCorrector.isLatinScript("łódź"))
    }

    func test_non_latin_script_words_rejected() {
        XCTAssertFalse(DictionaryCorrector.isLatinScript("δικαιοσύνη"))  // Greek
        XCTAssertFalse(DictionaryCorrector.isLatinScript("שלום"))        // Hebrew
        XCTAssertFalse(DictionaryCorrector.isLatinScript("مرحبا"))       // Arabic
        XCTAssertFalse(DictionaryCorrector.isLatinScript("привет"))      // Cyrillic
        XCTAssertFalse(DictionaryCorrector.isLatinScript("你好"))         // CJK
    }

    func test_mixed_script_word_rejected() {
        XCTAssertFalse(DictionaryCorrector.isLatinScript("helloσ"))
    }

    // MARK: - Letter-only check

    func test_letter_only_accepts_letters_and_apostrophes() {
        XCTAssertTrue(DictionaryCorrector.isLetterOnly("hello"))
        XCTAssertTrue(DictionaryCorrector.isLetterOnly("don't"))
        XCTAssertTrue(DictionaryCorrector.isLetterOnly("don\u{2019}t"))
    }

    func test_letter_only_rejects_digits_and_punctuation() {
        XCTAssertFalse(DictionaryCorrector.isLetterOnly("foo123"))
        XCTAssertFalse(DictionaryCorrector.isLetterOnly("model-x"))
        XCTAssertFalse(DictionaryCorrector.isLetterOnly("a.b"))
    }

    // MARK: - Casing

    func test_match_case_lowercase_target_for_lowercase_original() {
        XCTAssertEqual(
            DictionaryCorrector.matchCase(of: "thc", target: "the"),
            "the"
        )
    }

    func test_match_case_title_case_for_capitalized_original() {
        XCTAssertEqual(
            DictionaryCorrector.matchCase(of: "Thc", target: "the"),
            "The"
        )
    }

    func test_match_case_uppercase_for_all_caps_original() {
        XCTAssertEqual(
            DictionaryCorrector.matchCase(of: "THC", target: "the"),
            "THE"
        )
    }

    func test_match_case_handles_empty_strings() {
        XCTAssertEqual(
            DictionaryCorrector.matchCase(of: "", target: "the"),
            "the"
        )
        XCTAssertEqual(
            DictionaryCorrector.matchCase(of: "thc", target: ""),
            ""
        )
    }

    // MARK: - Primary subtag normalization

    func test_primary_subtag_strips_region() {
        XCTAssertEqual(DictionaryCorrector.primarySubtag("en-US"), "en")
        XCTAssertEqual(DictionaryCorrector.primarySubtag("fr-CA"), "fr")
        XCTAssertEqual(DictionaryCorrector.primarySubtag("EN"), "en")
    }

    func test_primary_subtag_passes_through_bare_codes() {
        XCTAssertEqual(DictionaryCorrector.primarySubtag("la"), "la")
        XCTAssertEqual(DictionaryCorrector.primarySubtag("grc"), "grc")
    }

    // MARK: - Language resolution

    func test_explicit_hint_wins_when_supported() {
        let resolved = DictionaryCorrector.resolveLanguage(
            hint: "fr",
            documentLanguage: "en",
            text: "any text"
        )
        XCTAssertEqual(resolved, "fr")
    }

    func test_unsupported_hint_falls_through_to_document_language() {
        let resolved = DictionaryCorrector.resolveLanguage(
            hint: "grc",  // not in supportedLanguages
            documentLanguage: "en",
            text: "any text"
        )
        XCTAssertEqual(resolved, "en")
    }

    func test_short_text_skips_NLR_and_uses_document_language() {
        // Below 80 chars NLR isn't trusted — fall back to the
        // document hint regardless of what NLR might say.
        let resolved = DictionaryCorrector.resolveLanguage(
            hint: nil,
            documentLanguage: "en",
            text: "Bonjour."
        )
        XCTAssertEqual(resolved, "en")
    }

    func test_unsupported_document_language_returns_nil() {
        // Polytonic Greek isn't in supportedLanguages → resolution
        // returns nil → corrector pass-through.
        let resolved = DictionaryCorrector.resolveLanguage(
            hint: nil,
            documentLanguage: "grc",
            text: "ἀνθρώπινος ζῷον πολιτικόν."
        )
        XCTAssertNil(resolved)
    }

    // MARK: - Pass-through behavior

    func test_correct_passes_through_when_no_supported_language() {
        let corrector = DictionaryCorrector(documentLanguage: "grc")
        let text = "ἀνθρώπινος ζῷον πολιτικόν"
        XCTAssertEqual(corrector.correct(text), text)
    }

    func test_correct_passes_through_when_document_language_is_nil() {
        let corrector = DictionaryCorrector(documentLanguage: nil)
        let text = "this would normally be checked"
        // No language hint and no document language → resolution
        // returns nil → no NSSpellChecker call → input returned.
        XCTAssertEqual(corrector.correct(text), text)
    }

    // MARK: - Q-Italic-Skip cross-language guard

    /// Spell-server tests are normally avoided since
    /// `NSSpellChecker` IPC can be flaky on CI, but the
    /// cross-language guard is the core of the
    /// foreign-word-overcorrection fix. Worth keeping as a small
    /// smoke even though the active-language path is excluded.
    func test_cross_language_check_skips_word_valid_in_other_language() {
        // "vita" is a valid Italian / Latin word; should be
        // flagged by the cross-language guard so the English
        // corrector doesn't replace it.
        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }
        XCTAssertTrue(
            DictionaryCorrector.isValidInOtherSupportedLanguage(
                word: "vita",
                activeLanguage: "en",
                checker: checker,
                documentTag: tag
            ),
            "Italian/Latin 'vita' should validate in another supported language"
        )
    }

    func test_cross_language_check_returns_false_for_pure_gibberish() {
        // Random consonant cluster — shouldn't validate in any
        // supported language. Confirms the guard returns false
        // when the original really is a typo.
        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }
        XCTAssertFalse(
            DictionaryCorrector.isValidInOtherSupportedLanguage(
                word: "xqzwk",
                activeLanguage: "en",
                checker: checker,
                documentTag: tag
            ),
            "Gibberish shouldn't validate in any other language"
        )
    }
}
