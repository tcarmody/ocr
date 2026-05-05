import XCTest
import AI
import PDFIngest
@testable import Pipeline

/// `ProfileWarningEvaluator` tests. Pure-function table tests over
/// representative input shapes — exercises every emitted case plus
/// the negative cases (when each warning is *not* emitted).
final class ProfileWarningTests: XCTestCase {

    // MARK: - Helpers

    private func make(
        isLikelyScan: Bool = false,
        primaryLanguage: String? = nil,
        confidence: Double = 0,
        useHighAccuracyOCR: Bool = false,
        processingMode: ProcessingMode = .privateLocal,
        cloudFeatures: AISettings.CloudFeatures = AISettings.CloudFeatures(
            hardRegionOCR: false, tableExtraction: false,
            postOCRCleanup: false, semanticClassification: false, tocParsing: false
        ),
        hasAPIKey: Bool = false,
        pickerSupportedLanguages: [String] = ["en", "fr", "grc"]
    ) -> ProfileWarningInputs {
        let profile = DocumentProfile(
            primaryLanguage: primaryLanguage,
            confidence: confidence,
            isLikelyScan: isLikelyScan,
            pageCount: 100
        )
        return ProfileWarningInputs(
            profile: profile,
            useHighAccuracyOCR: useHighAccuracyOCR,
            processingMode: processingMode,
            cloudFeatures: cloudFeatures,
            hasAPIKey: hasAPIKey,
            pickerSupportedLanguages: pickerSupportedLanguages
        )
    }

    // MARK: - likelyScanButHighAccuracyOff

    func test_likely_scan_with_high_accuracy_off_emits_warning() {
        let inputs = make(isLikelyScan: true, useHighAccuracyOCR: false)
        XCTAssertTrue(
            ProfileWarningEvaluator.evaluate(inputs)
                .contains(.likelyScanButHighAccuracyOff)
        )
    }

    func test_likely_scan_with_high_accuracy_on_does_not_emit_warning() {
        let inputs = make(isLikelyScan: true, useHighAccuracyOCR: true)
        XCTAssertFalse(
            ProfileWarningEvaluator.evaluate(inputs)
                .contains(.likelyScanButHighAccuracyOff)
        )
    }

    func test_born_digital_does_not_emit_scan_warning() {
        let inputs = make(isLikelyScan: false, useHighAccuracyOCR: false)
        XCTAssertFalse(
            ProfileWarningEvaluator.evaluate(inputs)
                .contains(.likelyScanButHighAccuracyOff)
        )
    }

    // MARK: - detectedLanguageUnsupported

    func test_unsupported_language_with_high_confidence_emits_warning() {
        // Welsh detected, picker only has English/French/Greek.
        let inputs = make(
            primaryLanguage: "cy", confidence: 0.85,
            pickerSupportedLanguages: ["en", "fr", "grc"]
        )
        XCTAssertTrue(
            ProfileWarningEvaluator.evaluate(inputs)
                .contains(.detectedLanguageUnsupported)
        )
    }

    func test_supported_language_does_not_emit_warning() {
        // Greek detected, picker has Greek — no mismatch.
        let inputs = make(
            primaryLanguage: "grc", confidence: 0.85,
            pickerSupportedLanguages: ["en", "fr", "grc"]
        )
        XCTAssertFalse(
            ProfileWarningEvaluator.evaluate(inputs)
                .contains(.detectedLanguageUnsupported)
        )
    }

    func test_low_confidence_does_not_emit_unsupported_warning() {
        // Confidence below the 0.7 threshold — even if the language
        // isn't in the picker, we don't warn (we don't trust the
        // detection enough).
        let inputs = make(
            primaryLanguage: "cy", confidence: 0.5,
            pickerSupportedLanguages: ["en", "fr", "grc"]
        )
        XCTAssertFalse(
            ProfileWarningEvaluator.evaluate(inputs)
                .contains(.detectedLanguageUnsupported)
        )
    }

    // MARK: - cloudModeButNoAPIKey / cloudModeButNoFeaturesEnabled

    func test_cloud_mode_without_key_emits_warning() {
        let inputs = make(processingMode: .cloud, hasAPIKey: false)
        XCTAssertTrue(
            ProfileWarningEvaluator.evaluate(inputs)
                .contains(.cloudModeButNoAPIKey)
        )
    }

    func test_cloud_mode_with_key_but_no_features_emits_warning() {
        let inputs = make(
            processingMode: .cloud,
            cloudFeatures: AISettings.CloudFeatures(
                hardRegionOCR: false, tableExtraction: false,
                postOCRCleanup: false,
                semanticClassification: false, tocParsing: false
            ),
            hasAPIKey: true
        )
        XCTAssertTrue(
            ProfileWarningEvaluator.evaluate(inputs)
                .contains(.cloudModeButNoFeaturesEnabled)
        )
    }

    func test_cloud_mode_with_key_and_one_feature_does_not_emit_warning() {
        let inputs = make(
            processingMode: .cloud,
            cloudFeatures: AISettings.CloudFeatures(
                hardRegionOCR: true, tableExtraction: false,
                postOCRCleanup: false,
                semanticClassification: false, tocParsing: false
            ),
            hasAPIKey: true
        )
        let warnings = ProfileWarningEvaluator.evaluate(inputs)
        XCTAssertFalse(warnings.contains(.cloudModeButNoAPIKey))
        XCTAssertFalse(warnings.contains(.cloudModeButNoFeaturesEnabled))
    }

    func test_private_mode_never_emits_cloud_warnings() {
        let inputs = make(
            processingMode: .privateLocal, hasAPIKey: false
        )
        let warnings = ProfileWarningEvaluator.evaluate(inputs)
        XCTAssertFalse(warnings.contains(.cloudModeButNoAPIKey))
        XCTAssertFalse(warnings.contains(.cloudModeButNoFeaturesEnabled))
    }

    // MARK: - Empty / multi case

    func test_clean_config_emits_no_warnings() {
        let inputs = make(
            isLikelyScan: false,
            primaryLanguage: "en", confidence: 0.95,
            useHighAccuracyOCR: false,
            processingMode: .privateLocal,
            pickerSupportedLanguages: ["en"]
        )
        XCTAssertEqual(ProfileWarningEvaluator.evaluate(inputs), [])
    }

    func test_multiple_warnings_can_fire_together() {
        // Scan + high-accuracy off + Cloud mode without key.
        let inputs = make(
            isLikelyScan: true,
            useHighAccuracyOCR: false,
            processingMode: .cloud,
            hasAPIKey: false
        )
        let warnings = ProfileWarningEvaluator.evaluate(inputs)
        XCTAssertTrue(warnings.contains(.likelyScanButHighAccuracyOff))
        XCTAssertTrue(warnings.contains(.cloudModeButNoAPIKey))
    }
}
