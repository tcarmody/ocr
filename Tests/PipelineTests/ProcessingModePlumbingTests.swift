import XCTest
import AI
@testable import Pipeline

/// Phase 2 plumbing: `PDFToEPUBPipeline.Options.processingMode` is
/// the master switch we'll consume in later phases when wiring
/// Claude-backed engines. Today both modes go through the same
/// dispatch arms so a `.cloud` conversion produces identical output
/// to a `.privateLocal` one — these tests pin that contract.
final class ProcessingModePlumbingTests: XCTestCase {

    func test_options_default_to_private_mode() {
        let options = PDFToEPUBPipeline.Options()
        XCTAssertEqual(options.processingMode, .privateLocal,
                       "First-launch / unconfigured callers must default to local-only")
    }

    func test_options_carry_explicit_processing_mode() {
        let cloud = PDFToEPUBPipeline.Options(processingMode: .cloud)
        XCTAssertEqual(cloud.processingMode, .cloud)

        let privateMode = PDFToEPUBPipeline.Options(processingMode: .privateLocal)
        XCTAssertEqual(privateMode.processingMode, .privateLocal)
    }

    /// Other Options fields keep their defaults regardless of mode —
    /// `.cloud` is purely additive infrastructure, not a re-config.
    func test_setting_cloud_does_not_disturb_other_options() {
        let options = PDFToEPUBPipeline.Options(processingMode: .cloud)
        XCTAssertEqual(options.dpi, 400)
        XCTAssertEqual(options.languages, [.en])
        XCTAssertEqual(options.ocrQuality, .accurate)
        XCTAssertFalse(options.emitDebugLog)
        XCTAssertFalse(options.useHighAccuracyOCR)
    }

    // MARK: - Phase 3: ClaudeOCREngine factory

    /// `.privateLocal` mode never constructs a Claude engine, even
    /// if a key were configured. Belt-and-braces: the dispatch
    /// switch in `convert(...)` already gates on mode, but the
    /// factory is a second line of defense.
    func test_privateLocal_mode_never_constructs_claude_engine() async {
        let options = PDFToEPUBPipeline.Options(
            processingMode: .privateLocal,
            anthropicAPIKeyProvider: { "sk-ant-real-looking-key" }
        )
        let budget = ClaudeCallBudget(cap: 10)
        let engine = PDFToEPUBPipeline.makeClaudeOCREngine(
            options: options, budget: budget
        )
        XCTAssertNil(engine)
    }

    /// `.cloud` mode without a key falls back to nil — Cloud-mode
    /// without setup behaves like Private mode. "Fail open" posture.
    func test_cloud_mode_without_api_key_falls_back_to_nil() async {
        let options = PDFToEPUBPipeline.Options(
            processingMode: .cloud,
            anthropicAPIKeyProvider: { nil }
        )
        let budget = ClaudeCallBudget(cap: 10)
        let engine = PDFToEPUBPipeline.makeClaudeOCREngine(
            options: options, budget: budget
        )
        XCTAssertNil(engine)
    }

    /// Cloud mode with key but the per-feature toggle off → nil.
    func test_cloud_mode_with_hardRegionOCR_off_returns_nil() async {
        var features = AISettings.CloudFeatures()
        features.hardRegionOCR = false
        let options = PDFToEPUBPipeline.Options(
            processingMode: .cloud,
            cloudFeatures: features,
            anthropicAPIKeyProvider: { "sk-test" }
        )
        let budget = ClaudeCallBudget(cap: 10)
        let engine = PDFToEPUBPipeline.makeClaudeOCREngine(
            options: options, budget: budget
        )
        XCTAssertNil(engine)
    }

    /// All three conditions met → engine constructed.
    func test_cloud_mode_with_key_and_feature_toggle_constructs_engine() async {
        let options = PDFToEPUBPipeline.Options(
            processingMode: .cloud,
            cloudFeatures: AISettings.CloudFeatures(),  // hardRegionOCR defaults to true
            anthropicAPIKeyProvider: { "sk-test" }
        )
        let budget = ClaudeCallBudget(cap: 10)
        let engine = PDFToEPUBPipeline.makeClaudeOCREngine(
            options: options, budget: budget
        )
        XCTAssertNotNil(engine)
    }
}
