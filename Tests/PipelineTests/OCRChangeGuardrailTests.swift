import XCTest
@testable import Pipeline

/// `OCRChangeGuardrail` decides whether to replace a prior tier's
/// OCR output with Claude's candidate. False rejections (we keep
/// degraded prior text when Claude was right) are acceptable —
/// degraded text is at worst what the user would have without
/// Cloud mode. False accepts (we ship hallucinated content) are
/// not. These tests pin both directions.
final class OCRChangeGuardrailTests: XCTestCase {

    private typealias Guardrail = OCRChangeGuardrail

    // MARK: - Edit distance

    func test_minor_correction_is_accepted() {
        // Long-s → s correction across a typical 18thC reprint passage.
        let prior = "Of the original contract of fociety. The right of "
            + "kingdoms is governed by laws and cuſtoms."
        let candidate = "Of the original contract of society. The right of "
            + "kingdoms is governed by laws and customs."
        let decision = Guardrail.accept(prior: prior, candidate: candidate)
        XCTAssertTrue(decision.accepted)
    }

    func test_translation_is_rejected_for_excessive_edits() {
        let prior = "ἐν ἀρχῇ ἦν ὁ λόγος καὶ ὁ λόγος ἦν πρὸς τὸν θεόν "
            + "καὶ θεὸς ἦν ὁ λόγος."
        let candidate = "In the beginning was the Word, and the Word was "
            + "with God, and the Word was God."
        let decision = Guardrail.accept(prior: prior, candidate: candidate)
        XCTAssertFalse(decision.accepted)
        // Script-drift fires before edit-distance because Greek →
        // Latin trips the script check first.
        XCTAssertEqual(decision.rejectionReason, .scriptDrift)
    }

    func test_paraphrase_is_rejected() {
        let prior = "The said John Doe, being of sound mind and body, "
            + "doth hereby bequeath his entire estate to his eldest son."
        let candidate = "John Doe leaves everything he owns to his oldest "
            + "kid in this will document signed today."
        let decision = Guardrail.accept(prior: prior, candidate: candidate)
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejectionReason, .excessiveEditDistance)
    }

    // MARK: - Length

    func test_truncated_response_is_rejected_for_length() {
        let prior = "This is a fairly long passage of body text that "
            + "Claude is supposed to transcribe verbatim from the page."
        let candidate = "This is a fairly long passage"
        let decision = Guardrail.accept(prior: prior, candidate: candidate)
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejectionReason, .lengthExplosion)
    }

    func test_hallucinated_expansion_is_rejected_for_length() {
        let prior = "The committee deliberated for some hours on the matter."
        let candidate = "The committee, comprising a most distinguished "
            + "assembly of learned gentlemen and notable scholars from "
            + "across the realm, deliberated at considerable length, "
            + "for what was reported to be the better part of an entire "
            + "afternoon, on the matter at hand."
        let decision = Guardrail.accept(prior: prior, candidate: candidate)
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejectionReason, .lengthExplosion)
    }

    // MARK: - Empty

    func test_empty_candidate_is_rejected_when_prior_had_text() {
        let decision = Guardrail.accept(prior: "Some real text.", candidate: "")
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejectionReason, .emptyResult)
    }

    func test_empty_candidate_against_empty_prior_is_accepted() {
        let decision = Guardrail.accept(prior: "", candidate: "")
        XCTAssertTrue(decision.accepted)
    }

    func test_whitespace_only_candidate_treated_as_empty() {
        let decision = Guardrail.accept(prior: "Body text.", candidate: "   \n\t  ")
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejectionReason, .emptyResult)
    }

    // MARK: - Short-prior bypass

    func test_short_prior_skips_edit_distance_check() {
        // 5-char prior — the edit-distance threshold would trip on
        // any single-character correction. Below the floor we skip
        // the check.
        let decision = Guardrail.accept(prior: "Pari", candidate: "Paris")
        XCTAssertTrue(decision.accepted)
    }

    func test_short_prior_still_catches_script_drift() {
        let decision = Guardrail.accept(prior: "δευτ", candidate: "deut")
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejectionReason, .scriptDrift)
    }

    // MARK: - Script detection

    func test_script_drift_rejects_greek_to_latin() {
        let greek = "δικαιοσύνη καὶ ἀλήθεια ἐν τῇ πόλει τῶν Ἀθηνῶν"
        let latin = "justice and truth in the city of the Athenians"
        let decision = Guardrail.accept(prior: greek, candidate: latin)
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejectionReason, .scriptDrift)
    }

    func test_script_drift_rejects_hebrew_to_latin() {
        let hebrew = "בראשית ברא אלהים את השמים ואת הארץ"
        let latin = "In the beginning God created the heavens and the earth"
        let decision = Guardrail.accept(prior: hebrew, candidate: latin)
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejectionReason, .scriptDrift)
    }

    func test_same_script_passes_script_check() {
        let prior = "The cat sat on the mat in the morning sunshine."
        let candidate = "The cat sat on the mat in the morning sunshine."
        let decision = Guardrail.accept(prior: prior, candidate: candidate)
        XCTAssertTrue(decision.accepted)
    }

    // MARK: - Levenshtein primitive

    func test_levenshtein_basic_distances() {
        XCTAssertEqual(Guardrail.levenshtein("", ""), 0)
        XCTAssertEqual(Guardrail.levenshtein("abc", "abc"), 0)
        XCTAssertEqual(Guardrail.levenshtein("abc", "abd"), 1)
        XCTAssertEqual(Guardrail.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(Guardrail.levenshtein("", "abc"), 3)
        XCTAssertEqual(Guardrail.levenshtein("abc", ""), 3)
    }

    func test_dominant_script_classification() {
        XCTAssertEqual(Guardrail.dominantScript("Hello world"), .latin)
        XCTAssertEqual(Guardrail.dominantScript("γεια σου κόσμε"), .greek)
        XCTAssertEqual(Guardrail.dominantScript("שלום עולם"), .hebrew)
        XCTAssertEqual(Guardrail.dominantScript("Привет мир"), .cyrillic)
        // Mixed script: majority wins. 5 Latin letters outvote 2 CJK
        // ideographs (punctuation isn't counted).
        XCTAssertEqual(Guardrail.dominantScript("Hello, 世界!"), .latin)
    }
}
