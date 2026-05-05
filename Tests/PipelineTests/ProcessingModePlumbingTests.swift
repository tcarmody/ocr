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
}
