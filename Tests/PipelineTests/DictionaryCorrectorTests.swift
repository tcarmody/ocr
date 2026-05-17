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

    // MARK: - Classical-vocabulary skip (Guard 6)

    func test_classical_vocab_skips_latin_function_words() {
        XCTAssertTrue(DictionaryCorrector.isClassicalVocabulary(word: "et"))
        XCTAssertTrue(DictionaryCorrector.isClassicalVocabulary(word: "est"))
        XCTAssertTrue(DictionaryCorrector.isClassicalVocabulary(word: "sed"))
    }

    func test_classical_vocab_skips_latin_inflected_forms() {
        // High-frequency nouns / verbs in their classical
        // citation forms — surface in academic English prose.
        XCTAssertTrue(DictionaryCorrector.isClassicalVocabulary(word: "rei"))
        XCTAssertTrue(DictionaryCorrector.isClassicalVocabulary(word: "hominis"))
        XCTAssertTrue(DictionaryCorrector.isClassicalVocabulary(word: "summa"))
    }

    func test_classical_vocab_skips_greek_transliteration() {
        XCTAssertTrue(DictionaryCorrector.isClassicalVocabulary(word: "aletheia"))
        XCTAssertTrue(DictionaryCorrector.isClassicalVocabulary(word: "phronesis"))
        XCTAssertTrue(DictionaryCorrector.isClassicalVocabulary(word: "katharsis"))
    }

    func test_classical_vocab_case_insensitive() {
        XCTAssertTrue(DictionaryCorrector.isClassicalVocabulary(word: "Logos"))
        XCTAssertTrue(DictionaryCorrector.isClassicalVocabulary(word: "POLIS"))
    }

    func test_classical_vocab_lets_normal_english_through() {
        XCTAssertFalse(DictionaryCorrector.isClassicalVocabulary(word: "english"))
        XCTAssertFalse(DictionaryCorrector.isClassicalVocabulary(word: "the"))
        XCTAssertFalse(DictionaryCorrector.isClassicalVocabulary(word: "philosophy"))
    }

    // MARK: - OCR-confusion-pattern gate (Guard 7)

    func test_diff_finds_substitution_position() {
        // "Engiish" vs "English" differ at position 3 (i vs l).
        guard let diff = DictionaryCorrector.diffAtDistanceOne(
            a: "engiish", b: "english"
        ) else {
            return XCTFail("expected distance-1 diff")
        }
        XCTAssertEqual(diff.type, .substitution)
        XCTAssertEqual(diff.position, 3)
        XCTAssertEqual(diff.char, "l")
    }

    func test_diff_finds_insertion_position() {
        // "wel" → "well" is an insertion at position 3.
        guard let diff = DictionaryCorrector.diffAtDistanceOne(
            a: "wel", b: "well"
        ) else {
            return XCTFail("expected distance-1 diff")
        }
        XCTAssertEqual(diff.type, .insertion)
        XCTAssertEqual(diff.position, 3)
        XCTAssertEqual(diff.char, "l")
    }

    func test_diff_finds_deletion_position() {
        // "thaat" → "that" deletes the second 'a'. Common
        // prefix is "tha" (3 chars), common suffix is "t"
        // (1 char), so the diff lands at position 3 in the
        // original.
        guard let diff = DictionaryCorrector.diffAtDistanceOne(
            a: "thaat", b: "that"
        ) else {
            return XCTFail("expected distance-1 diff")
        }
        XCTAssertEqual(diff.type, .deletion)
        XCTAssertEqual(diff.position, 3)
        XCTAssertEqual(diff.char, "a")
    }

    func test_diff_returns_nil_for_distance_two_or_more() {
        // "kitten" → "kitten" is distance 0; "abcde" → "axxde"
        // is distance 2.
        XCTAssertNil(DictionaryCorrector.diffAtDistanceOne(
            a: "abcde", b: "axxde"
        ))
    }

    func test_confusion_gate_accepts_classic_scanner_errors() {
        // `thc → the` (c→e substitution).
        XCTAssertTrue(DictionaryCorrector.isOCRConfusionEdit(
            original: "thc", candidate: "the"
        ))
        // `Engiish → English` (i→l substitution).
        XCTAssertTrue(DictionaryCorrector.isOCRConfusionEdit(
            original: "Engiish", candidate: "English"
        ))
        // `corn → conn` (r→n substitution) — questionable in
        // isolation, but `r↔n` is in the confusable table.
        XCTAssertTrue(DictionaryCorrector.isOCRConfusionEdit(
            original: "corn", candidate: "conn"
        ))
    }

    func test_confusion_gate_accepts_doubled_letter_edits() {
        // `wel → well` (doubled-letter insertion).
        XCTAssertTrue(DictionaryCorrector.isOCRConfusionEdit(
            original: "wel", candidate: "well"
        ))
        // `acros → across` (doubled s insertion).
        XCTAssertTrue(DictionaryCorrector.isOCRConfusionEdit(
            original: "acros", candidate: "across"
        ))
        // `thaat → that` (doubled-letter deletion).
        XCTAssertTrue(DictionaryCorrector.isOCRConfusionEdit(
            original: "thaat", candidate: "that"
        ))
    }

    func test_confusion_gate_rejects_foreign_cognate_edits() {
        // French `salade` → English `salads` (e→s). Not a
        // visual-confusion pair, so the gate refuses to apply
        // — exactly the over-correction this gate exists to
        // block.
        XCTAssertFalse(DictionaryCorrector.isOCRConfusionEdit(
            original: "salade", candidate: "salads"
        ))
        // German `Haus` → `haul` (s→l). Not in the table.
        XCTAssertFalse(DictionaryCorrector.isOCRConfusionEdit(
            original: "Haus", candidate: "haul"
        ))
        // French `idée` → English `idea` involves an accented
        // character → not in confusableLetterPairs (which only
        // lists ASCII letters), so rejected.
        XCTAssertFalse(DictionaryCorrector.isOCRConfusionEdit(
            original: "idée", candidate: "idea"
        ))
    }

    func test_confusion_gate_rejects_non_adjacent_letter_insertion() {
        // Insertion of an arbitrary letter that doesn't duplicate
        // an adjacent char shouldn't pass — that's not what an
        // OCR dropout looks like. Example: "carte" → "carter"
        // (insert 'r' at end where adjacent char is 'e').
        XCTAssertFalse(DictionaryCorrector.isOCRConfusionEdit(
            original: "carte", candidate: "carter"
        ))
    }

    func test_confusion_gate_rejects_arbitrary_final_letter_deletion() {
        // French `carte` → English `cart` deletes a final 'e'
        // with no neighboring 'e'. Not a doubled-letter
        // collapse → rejected.
        XCTAssertFalse(DictionaryCorrector.isOCRConfusionEdit(
            original: "carte", candidate: "cart"
        ))
    }
}
