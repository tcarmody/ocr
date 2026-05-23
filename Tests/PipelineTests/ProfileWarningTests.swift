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
        imageXObjectsPerPage: Double = 0,
        useHighAccuracyOCR: Bool = false,
        useWholePageOCR: Bool = false,
        processingMode: ProcessingMode = .privateLocal,
        cloudFeatures: AISettings.CloudFeatures = AISettings.CloudFeatures(
            hardRegionOCR: false, tableExtraction: false,
            postOCRCleanup: false, semanticClassification: false, tocParsing: false
        ),
        hasAPIKey: Bool = false,
        hasGeminiKey: Bool = false,
        suryaAvailable: Bool = false,
        pickerSupportedLanguages: [String] = ["en", "fr", "grc"]
    ) -> ProfileWarningInputs {
        let profile = DocumentProfile(
            primaryLanguage: primaryLanguage,
            confidence: confidence,
            isLikelyScan: isLikelyScan,
            pageCount: 100,
            imageXObjectsPerPage: imageXObjectsPerPage
        )
        return ProfileWarningInputs(
            profile: profile,
            useHighAccuracyOCR: useHighAccuracyOCR,
            useWholePageOCR: useWholePageOCR,
            processingMode: processingMode,
            cloudFeatures: cloudFeatures,
            hasAPIKey: hasAPIKey,
            hasGeminiKey: hasGeminiKey,
            suryaAvailable: suryaAvailable,
            pickerSupportedLanguages: pickerSupportedLanguages
        )
    }

    // MARK: - Complex-layout warning matrix

    /// `CloudFeatures` with at least one feature on — used in
    /// complex-layout tests so the orthogonal
    /// `cloudModeButNoFeaturesEnabled` doesn't fire and obscure
    /// what we're checking.
    private var cloudWithFeatureOn: AISettings.CloudFeatures {
        AISettings.CloudFeatures(
            hardRegionOCR: true, tableExtraction: false,
            postOCRCleanup: false,
            semanticClassification: false, tocParsing: false
        )
    }

    func test_likely_scan_with_cloud_page_OCR_available_recommends_cloud() {
        // Cloud mode + Anthropic key → recommend page OCR.
        let inputs = make(
            isLikelyScan: true,
            processingMode: .cloud,
            cloudFeatures: cloudWithFeatureOn,
            hasAPIKey: true
        )
        XCTAssertEqual(
            ProfileWarningEvaluator.evaluate(inputs),
            [.complexLayoutRecommendCloudPageOCR]
        )
    }

    func test_likely_scan_with_gemini_key_recommends_cloud() {
        // Gemini key alone (no Anthropic) is enough — both are
        // valid page-OCR providers.
        let inputs = make(
            isLikelyScan: true,
            processingMode: .cloud,
            cloudFeatures: cloudWithFeatureOn,
            hasAPIKey: false,
            hasGeminiKey: true
        )
        // Note: the cloud-without-Anthropic-key warning still
        // fires because the existing `cloudModeButNoAPIKey`
        // check looks for the Anthropic key specifically. The
        // complex-layout path correctly recommends cloud page
        // OCR; the noisy-second-warning is an existing concern
        // orthogonal to this matrix change.
        let warnings = ProfileWarningEvaluator.evaluate(inputs)
        XCTAssertTrue(warnings.contains(.complexLayoutRecommendCloudPageOCR))
    }

    func test_likely_scan_in_private_mode_with_surya_recommends_surya() {
        let inputs = make(
            isLikelyScan: true,
            processingMode: .privateLocal,
            suryaAvailable: true
        )
        XCTAssertEqual(
            ProfileWarningEvaluator.evaluate(inputs),
            [.complexLayoutRecommendSurya]
        )
    }

    func test_likely_scan_with_no_upgrade_path_surfaces_install_hint() {
        let inputs = make(
            isLikelyScan: true,
            processingMode: .privateLocal,
            suryaAvailable: false
        )
        XCTAssertEqual(
            ProfileWarningEvaluator.evaluate(inputs),
            [.complexLayoutNoUpgradePathAvailable]
        )
    }

    func test_figure_dense_layout_triggers_same_warning_as_likely_scan() {
        // Born-digital art book with ≥ 1 figure every 3 pages.
        // No likely-scan flag, but the figure density alone
        // earns the complex-layout warning.
        let inputs = make(
            isLikelyScan: false,
            imageXObjectsPerPage: 0.5,
            processingMode: .cloud,
            cloudFeatures: cloudWithFeatureOn,
            hasAPIKey: true
        )
        XCTAssertEqual(
            ProfileWarningEvaluator.evaluate(inputs),
            [.complexLayoutRecommendCloudPageOCR]
        )
    }

    func test_figure_density_below_threshold_does_not_warn() {
        // 1 figure every ~10 pages — below the 0.3 floor.
        let inputs = make(
            isLikelyScan: false,
            imageXObjectsPerPage: 0.1,
            processingMode: .cloud,
            cloudFeatures: cloudWithFeatureOn,
            hasAPIKey: true
        )
        XCTAssertEqual(ProfileWarningEvaluator.evaluate(inputs), [])
    }

    func test_high_accuracy_already_picked_suppresses_complex_layout_warning() {
        let inputs = make(
            isLikelyScan: true,
            useHighAccuracyOCR: true,
            processingMode: .privateLocal,
            suryaAvailable: true
        )
        XCTAssertEqual(ProfileWarningEvaluator.evaluate(inputs), [])
    }

    func test_cloud_page_OCR_already_picked_suppresses_complex_layout_warning() {
        let inputs = make(
            isLikelyScan: true,
            useWholePageOCR: true,
            processingMode: .cloud,
            cloudFeatures: cloudWithFeatureOn,
            hasAPIKey: true
        )
        XCTAssertEqual(ProfileWarningEvaluator.evaluate(inputs), [])
    }

    func test_born_digital_clean_layout_emits_no_complex_layout_warning() {
        let inputs = make(
            isLikelyScan: false,
            imageXObjectsPerPage: 0,
            processingMode: .privateLocal
        )
        let warnings = ProfileWarningEvaluator.evaluate(inputs)
        XCTAssertFalse(warnings.contains(.complexLayoutRecommendCloudPageOCR))
        XCTAssertFalse(warnings.contains(.complexLayoutRecommendSurya))
        XCTAssertFalse(warnings.contains(.complexLayoutNoUpgradePathAvailable))
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
        // Scan + Cloud mode without key → complex-layout (no
        // upgrade path since cloud unavailable + surya off) +
        // the no-API-key cloud-mode warning.
        let inputs = make(
            isLikelyScan: true,
            useHighAccuracyOCR: false,
            processingMode: .cloud,
            hasAPIKey: false
        )
        let warnings = ProfileWarningEvaluator.evaluate(inputs)
        XCTAssertTrue(warnings.contains(.complexLayoutNoUpgradePathAvailable))
        XCTAssertTrue(warnings.contains(.cloudModeButNoAPIKey))
    }
}
