import XCTest
import AI
@testable import Pipeline

/// E-Vision-Modes Manuscript track: verify the engine routes the
/// system prompt + model correctly per `Mode`, and that each
/// `ManuscriptHand` produces a distinct prompt addendum the
/// model can read on the wire.
final class ManuscriptModeTests: XCTestCase {

    // MARK: - Mode routing

    func test_typeset_mode_uses_sonnet_by_default() {
        let mode: ClaudePageOCREngine.Mode = .typeset
        XCTAssertEqual(mode.defaultModel, .sonnet4_6)
    }

    func test_manuscript_mode_uses_opus_by_default() {
        for hand in ManuscriptHand.allCases {
            let mode: ClaudePageOCREngine.Mode = .manuscript(hand: hand)
            XCTAssertEqual(mode.defaultModel, .opus4_7,
                "manuscript \(hand) should default to Opus")
        }
    }

    // MARK: - System prompt composition

    func test_typeset_systemPrompt_matches_baseSystemPrompt() {
        // Typeset mode is the base prompt with no addendum —
        // existing Sonnet path stays byte-identical so its cache
        // key doesn't churn from this refactor.
        let prompt = ClaudePageOCREngine.systemPrompt(for: .typeset)
        XCTAssertEqual(prompt, ClaudePageOCREngine.baseSystemPrompt)
    }

    func test_manuscript_systemPrompt_appends_hand_addendum() {
        // Each manuscript mode = base prompt + hand-specific
        // addendum. The base XHTML schema + reading-order rules
        // are shared; the transcription policy varies.
        for hand in ManuscriptHand.allCases {
            let prompt = ClaudePageOCREngine.systemPrompt(
                for: .manuscript(hand: hand)
            )
            XCTAssertTrue(prompt.hasPrefix(ClaudePageOCREngine.baseSystemPrompt),
                "\(hand) should start with the base prompt")
            XCTAssertTrue(prompt.contains(hand.promptAddendum),
                "\(hand) should contain its addendum")
        }
    }

    // MARK: - Per-hand prompt distinctness

    func test_each_hand_has_distinct_promptAddendum() {
        // Distinct addenda guarantee Claude sees a different
        // transcription posture per sub-mode. If two cases ever
        // collapsed to the same text by accident, this test
        // catches it.
        let addenda = ManuscriptHand.allCases.map(\.promptAddendum)
        XCTAssertEqual(Set(addenda).count, addenda.count,
            "every hand should produce a unique prompt addendum")
    }

    func test_diplomatic_prompt_mentions_secretary_hand() {
        XCTAssertTrue(
            ManuscriptHand.diplomatic.promptAddendum
                .lowercased().contains("secretary hand"),
            "diplomatic prompt should identify the script family"
        )
    }

    func test_roundHand_prompt_mentions_copperplate() {
        XCTAssertTrue(
            ManuscriptHand.roundHand.promptAddendum
                .lowercased().contains("copperplate"),
            "round hand prompt should identify the 18th-c. script"
        )
    }

    func test_diplomatic_prompt_includes_uncertainty_markers() {
        // All sub-modes share the [?word?] / [illegible] /
        // <em>-for-expansions conventions via the
        // sharedConventions block.
        let prompt = ManuscriptHand.diplomatic.promptAddendum
        XCTAssertTrue(prompt.contains("[?word?]"))
        XCTAssertTrue(prompt.contains("[illegible]"))
        XCTAssertTrue(prompt.contains("<em>"))
    }

    func test_contemporary_prompt_uses_friendly_posture() {
        // Sanity-check: contemporary informal isn't asking for
        // diplomatic-style abbreviation expansion (it's
        // user-friendly modern reading, not paleographic
        // edition work).
        let prompt = ManuscriptHand.contemporaryInformal.promptAddendum
            .lowercased()
        XCTAssertTrue(prompt.contains("reading-friendly"))
    }

    // MARK: - Display names

    func test_all_hands_have_human_readable_displayName() {
        for hand in ManuscriptHand.allCases {
            let name = hand.displayName
            XCTAssertFalse(name.isEmpty,
                "\(hand) needs a non-empty displayName for the picker")
            // Not all-lowercase: the user-facing strings should
            // read like UI labels, not enum cases.
            XCTAssertNotEqual(name, hand.rawValue)
        }
    }

    // MARK: - Early Print

    func test_earlyPrint_mode_uses_sonnet_by_default() {
        for face in EarlyPrintTypeface.allCases {
            let mode: ClaudePageOCREngine.Mode = .earlyPrint(typeface: face)
            XCTAssertEqual(mode.defaultModel, .sonnet4_6,
                "early print \(face) should stay on Sonnet (same cost tier as Claude OCR)")
        }
    }

    func test_earlyPrint_systemPrompt_appends_typeface_addendum() {
        for face in EarlyPrintTypeface.allCases {
            let prompt = ClaudePageOCREngine.systemPrompt(
                for: .earlyPrint(typeface: face)
            )
            XCTAssertTrue(prompt.hasPrefix(ClaudePageOCREngine.baseSystemPrompt),
                "\(face) should start with the base prompt")
            XCTAssertTrue(prompt.contains(face.promptAddendum),
                "\(face) should contain its addendum")
        }
    }

    func test_each_typeface_has_distinct_promptAddendum() {
        // Same invariant as the Manuscript hand test: no two
        // typefaces collapse to the same prompt.
        let addenda = EarlyPrintTypeface.allCases.map(\.promptAddendum)
        XCTAssertEqual(Set(addenda).count, addenda.count,
            "every typeface should produce a unique prompt addendum")
    }

    func test_earlyPrint_prompts_call_out_normalization_posture() {
        // The defining contrast between Early Print and Manuscript:
        // fluent normalization vs. diplomatic preservation. Every
        // Early Print prompt should mention long-s normalization.
        for face in EarlyPrintTypeface.allCases {
            XCTAssertTrue(
                face.promptAddendum.lowercased().contains("long-s"),
                "\(face) should mention long-s handling (defining Early Print convention)"
            )
        }
    }

    func test_blackletter_prompt_mentions_german_specific_features() {
        let prompt = ManuscriptHand.diplomatic.promptAddendum  // unrelated comparison just for sanity
        XCTAssertFalse(prompt.contains("eszett"),
            "secretary-hand prompt shouldn't talk about German eszett")
        let blackletter = EarlyPrintTypeface.blackletterFraktur.promptAddendum
        XCTAssertTrue(blackletter.lowercased().contains("eszett")
            || blackletter.contains("ß"),
            "blackletter prompt should cover German-specific characters")
    }

    func test_earlyPrint_typefaces_all_have_displayName() {
        for face in EarlyPrintTypeface.allCases {
            XCTAssertFalse(face.displayName.isEmpty)
            XCTAssertNotEqual(face.displayName, face.rawValue,
                "displayName should read like a UI label, not the enum case")
        }
    }

    // MARK: - Three-way Mode space

    func test_three_modes_are_distinguishable() {
        // The three Mode cases all produce different system
        // prompts. Belt-and-suspenders since the prompt-composition
        // tests above already cover each separately.
        let typeset = ClaudePageOCREngine.systemPrompt(for: .typeset)
        let early = ClaudePageOCREngine.systemPrompt(
            for: .earlyPrint(typeface: .auto)
        )
        let manuscript = ClaudePageOCREngine.systemPrompt(
            for: .manuscript(hand: .auto)
        )
        XCTAssertNotEqual(typeset, early)
        XCTAssertNotEqual(typeset, manuscript)
        XCTAssertNotEqual(early, manuscript)
    }
}
