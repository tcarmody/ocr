import XCTest
import CoreGraphics
import AI
import Document
import OCR
@testable import Pipeline

/// `AppleFoundationModelPostProcessor` — Phase 2.5 of
/// `L-Foundation-Models`. AFM calls into Apple's `FoundationModels`
/// framework directly and isn't mockable from the test suite (the
/// client wrapper is intentionally thin), so coverage focuses on
/// the gating logic that runs *before* AFM is invoked: vision-mode
/// rejection, short-text rejection, clean-text rejection, prompt
/// composition.
///
/// Full round-trip behavior (parse `CorrectedText`, run guardrail,
/// return `Result`) is verified by Cloud-side tests in
/// `ClaudePostProcessorTests` since both impls share the
/// `OCRTextQualityScorer` trigger gate, `OCRChangeGuardrail` accept/
/// reject policy, and `ClaudePostProcessor.Result` return shape —
/// the only thing that differs is the model call itself.
final class AppleFoundationModelPostProcessorTests: XCTestCase {

    // MARK: - vision mode rejection

    func test_correct_returns_nil_in_vision_mode() async {
        let proc = AppleFoundationModelPostProcessor()
        // Vision mode with a non-nil image still returns nil —
        // AFM is text-only, and silently downgrading to passages
        // mode would burn cycles on a region that was flagged for
        // vision specifically.
        let cg = makeImage()
        let result = await proc.correct(
            text: "Some text that's long enough to pass the floor.",
            languages: [.en],
            mode: .vision,
            regionImage: cg
        )
        XCTAssertNil(result)
    }

    func test_correct_returns_nil_in_vision_mode_without_image() async {
        let proc = AppleFoundationModelPostProcessor()
        let result = await proc.correct(
            text: "Some text that's long enough to pass the floor.",
            languages: [.en],
            mode: .vision,
            regionImage: nil
        )
        XCTAssertNil(result)
    }

    // MARK: - short-text rejection

    func test_correct_returns_nil_for_text_below_min_chars() async {
        // Default minCharsToProcess is 30; the floor catches
        // captions / page numbers / short stubs.
        let proc = AppleFoundationModelPostProcessor()
        let result = await proc.correct(
            text: "short",
            languages: [.en],
            mode: .passages,
            regionImage: nil
        )
        XCTAssertNil(result)
    }

    func test_correct_short_floor_applies_after_trimming() async {
        // Whitespace doesn't count toward the floor.
        let padded = "  short  "
        let proc = AppleFoundationModelPostProcessor()
        let result = await proc.correct(
            text: padded, languages: [.en],
            mode: .passages, regionImage: nil
        )
        XCTAssertNil(result)
    }

    // MARK: - clean-text rejection (no AFM call)

    func test_correct_returns_nil_for_clean_text_above_threshold() async {
        // OCRTextQualityScorer assigns a high combined score to
        // ordinary English prose. The trigger gate skips it before
        // AFM is invoked.
        let clean = """
            This is ordinary English prose with no OCR errors, no \
            ligature confusions, no missing diacritics. It should \
            score well above the trigger threshold and bypass the \
            post-processor entirely.
            """
        let proc = AppleFoundationModelPostProcessor()
        let result = await proc.correct(
            text: clean, languages: [.en],
            mode: .passages, regionImage: nil
        )
        XCTAssertNil(result)
    }

    // MARK: - prompt composition

    func test_userPrompt_includes_language_codes_and_text() {
        let prompt = AppleFoundationModelPostProcessor.userPrompt(
            text: "Sample OCR string with rn → m issues",
            languages: [.en, .de]
        )
        XCTAssertTrue(prompt.contains("en, de"))
        XCTAssertTrue(prompt.contains("Sample OCR string"))
        XCTAssertTrue(prompt.contains("Languages expected:"))
    }

    func test_userPrompt_single_language() {
        let prompt = AppleFoundationModelPostProcessor.userPrompt(
            text: "x", languages: [.en]
        )
        XCTAssertTrue(prompt.contains("en"))
        XCTAssertFalse(prompt.contains(","))
    }

    func test_instructions_excludes_no_json_wrapper_clause() {
        // Mirrors the Cloud prompt verbatim except the trailing
        // "Return ONLY the corrected text — no preface, no JSON
        // wrapper" clause. The @Generable schema enforces the
        // output shape natively here; the JSON-wrapper instruction
        // would actively confuse AFM.
        let instructions = AppleFoundationModelPostProcessor.instructions
        XCTAssertFalse(instructions.contains("JSON wrapper"))
        XCTAssertFalse(instructions.contains("no preface"))
        // Spot-check the shared core constraints stayed.
        XCTAssertTrue(instructions.contains("ligature confusions"))
        XCTAssertTrue(instructions.contains("do NOT translate"))
        XCTAssertTrue(instructions.contains("character-level"))
    }

    // MARK: - protocol conformance

    func test_conforms_to_PostOCRProcessor() {
        let proc: any PostOCRProcessor = AppleFoundationModelPostProcessor()
        // Smoke: protocol-typed reference compiles + exists. The
        // pipeline's `makePostProcessor` factory returns this
        // existential type so the cascade doesn't branch on impl.
        _ = proc
    }

    // MARK: - test fixtures

    private func makeImage() -> CGImage {
        let ctx = CGContext(
            data: nil, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }
}
