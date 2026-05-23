import XCTest
import AI
import PDFIngest
@testable import Pipeline

/// `CostEstimator` tests. Coarse estimator → coarse assertions:
/// the math is intentionally approximate, so we check
/// orders-of-magnitude and feature-toggle behavior rather than
/// exact dollar amounts.
final class CostEstimatorTests: XCTestCase {

    // MARK: - Empty / disabled cases

    func test_zero_pages_returns_empty_estimate() {
        let profile = DocumentProfile()
        let estimate = CostEstimator.estimate(
            profile: profile,
            cloudFeatures: AISettings.CloudFeatures(
                hardRegionOCR: true, postOCRCleanup: true
            ),
            perBookCallCap: 200
        )
        XCTAssertEqual(estimate, .empty)
    }

    func test_no_features_enabled_returns_zero_calls() {
        let profile = DocumentProfile(isLikelyScan: true, pageCount: 200)
        let estimate = CostEstimator.estimate(
            profile: profile,
            cloudFeatures: AISettings.CloudFeatures(
                hardRegionOCR: false,
                tableExtraction: false,
                postOCRCleanup: false
            ),
            perBookCallCap: 200
        )
        XCTAssertEqual(estimate.estimatedCalls, 0)
        XCTAssertEqual(estimate.estimatedCostUSD, 0)
        XCTAssertTrue(estimate.perFeature.isEmpty)
    }

    // MARK: - Per-feature behavior

    func test_hard_region_ocr_costs_more_on_scans_than_born_digital() {
        let scanProfile = DocumentProfile(isLikelyScan: true, pageCount: 200)
        let bornDigitalProfile = DocumentProfile(isLikelyScan: false, pageCount: 200)
        let features = AISettings.CloudFeatures(
            hardRegionOCR: true,
            tableExtraction: false,
            postOCRCleanup: false
        )
        let scanEst = CostEstimator.estimate(
            profile: scanProfile, cloudFeatures: features, perBookCallCap: 1_000_000
        )
        let bornEst = CostEstimator.estimate(
            profile: bornDigitalProfile, cloudFeatures: features, perBookCallCap: 1_000_000
        )
        // Scans should generate at least ~10× more Claude calls
        // than born-digital (10% rate vs 0.5%).
        XCTAssertGreaterThan(scanEst.estimatedCalls, bornEst.estimatedCalls * 5)
    }

    func test_vision_mode_costs_more_per_call_than_passages() {
        let profile = DocumentProfile(isLikelyScan: true, pageCount: 200)
        let passages = AISettings.CloudFeatures(
            hardRegionOCR: false,
            tableExtraction: false,
            postOCRCleanup: true,
            postOCRCleanupVisionMode: false
        )
        let vision = AISettings.CloudFeatures(
            hardRegionOCR: false,
            tableExtraction: false,
            postOCRCleanup: true,
            postOCRCleanupVisionMode: true
        )
        let passEst = CostEstimator.estimate(
            profile: profile, cloudFeatures: passages, perBookCallCap: 1_000_000
        )
        let visionEst = CostEstimator.estimate(
            profile: profile, cloudFeatures: vision, perBookCallCap: 1_000_000
        )
        // Same trigger rate → same call count.
        XCTAssertEqual(visionEst.estimatedCalls, passEst.estimatedCalls)
        // Vision should cost meaningfully more per call.
        XCTAssertGreaterThan(visionEst.estimatedCostUSD, passEst.estimatedCostUSD * 2)
    }

    func test_per_feature_breakdown_includes_each_enabled_feature() {
        let profile = DocumentProfile(isLikelyScan: true, pageCount: 200)
        let features = AISettings.CloudFeatures(
            hardRegionOCR: true,
            tableExtraction: true,
            postOCRCleanup: true
        )
        let est = CostEstimator.estimate(
            profile: profile, cloudFeatures: features, perBookCallCap: 1_000_000
        )
        let labels = est.perFeature.map(\.label)
        XCTAssertTrue(labels.contains(where: { $0.contains("Hard-region OCR") }))
        XCTAssertTrue(labels.contains(where: { $0.contains("Post-OCR cleanup") }))
        XCTAssertTrue(labels.contains(where: { $0.contains("Table extraction") }))
    }

    // MARK: - Cap clamping

    func test_estimate_above_cap_is_clamped_and_flagged() {
        // 1000 pages × 5 regions × 10% trigger = 500 calls.
        // Cap at 100 → estimate clamps and `clampedByCap` flips on.
        let profile = DocumentProfile(isLikelyScan: true, pageCount: 1000)
        let features = AISettings.CloudFeatures(
            hardRegionOCR: true,
            tableExtraction: false,
            postOCRCleanup: false
        )
        let est = CostEstimator.estimate(
            profile: profile, cloudFeatures: features, perBookCallCap: 100
        )
        XCTAssertEqual(est.estimatedCalls, 100)
        XCTAssertTrue(est.clampedByCap)
    }

    func test_estimate_below_cap_is_not_flagged() {
        let profile = DocumentProfile(isLikelyScan: true, pageCount: 50)
        let features = AISettings.CloudFeatures(
            hardRegionOCR: true,
            tableExtraction: false,
            postOCRCleanup: false
        )
        let est = CostEstimator.estimate(
            profile: profile, cloudFeatures: features, perBookCallCap: 200
        )
        XCTAssertGreaterThan(est.estimatedCalls, 0)
        XCTAssertFalse(est.clampedByCap)
    }

    // MARK: - Page-OCR mode (Phase 4c)

    /// When `useWholePageOCR: true`, the per-region hard-region-OCR
    /// estimate is replaced with a single per-page Sonnet line item,
    /// and post-OCR cleanup line items are suppressed (the page-OCR
    /// path produces clean output without a separate cleanup pass).
    func test_pageOCR_mode_emits_per_page_line_only() {
        let profile = DocumentProfile(isLikelyScan: true, pageCount: 400)
        let features = AISettings.CloudFeatures(
            hardRegionOCR: true,
            tableExtraction: false,
            postOCRCleanup: true
        )
        let est = CostEstimator.estimate(
            profile: profile,
            cloudFeatures: features,
            perBookCallCap: 1_000_000,
            useWholePageOCR: true
        )
        XCTAssertEqual(est.estimatedCalls, 400, "one call per page")
        let labels = est.perFeature.map(\.label)
        XCTAssertTrue(labels.contains(where: { $0.contains("Page OCR") }))
        XCTAssertFalse(
            labels.contains(where: { $0.contains("Hard-region OCR") }),
            "page OCR replaces hard-region OCR"
        )
        XCTAssertFalse(
            labels.contains(where: { $0.contains("Post-OCR cleanup") }),
            "page OCR replaces post-OCR cleanup"
        )
    }

    /// Page-OCR mode keeps the table-extraction line item — table
    /// extraction is a separate cloud feature that operates on
    /// Surya-detected `.table` regions and runs even when the body
    /// text comes from the page-OCR path.
    func test_pageOCR_mode_keeps_table_extraction_line() {
        let profile = DocumentProfile(isLikelyScan: true, pageCount: 200)
        let features = AISettings.CloudFeatures(
            hardRegionOCR: true,
            tableExtraction: true,
            postOCRCleanup: true
        )
        let est = CostEstimator.estimate(
            profile: profile,
            cloudFeatures: features,
            perBookCallCap: 1_000_000,
            useWholePageOCR: true
        )
        let labels = est.perFeature.map(\.label)
        XCTAssertTrue(labels.contains(where: { $0.contains("Page OCR") }))
        XCTAssertTrue(labels.contains(where: { $0.contains("Table extraction") }))
    }

    /// 400-page book in page-OCR mode should land in the
    /// $15-25/book ballpark we documented in the toggle help text.
    func test_pageOCR_400_page_book_in_expected_cost_range() {
        let profile = DocumentProfile(isLikelyScan: true, pageCount: 400)
        let features = AISettings.CloudFeatures(hardRegionOCR: true)
        let est = CostEstimator.estimate(
            profile: profile,
            cloudFeatures: features,
            perBookCallCap: 1_000_000,
            useWholePageOCR: true
        )
        XCTAssertGreaterThan(est.estimatedCostUSD, 5,
            "400 pages at ~$0.04/page should be > $5")
        XCTAssertLessThan(est.estimatedCostUSD, 30,
            "400 pages at ~$0.04/page should be < $30")
    }

    // MARK: - Codable

    func test_estimate_round_trips_through_json() throws {
        let original = CostEstimator.Estimate(
            estimatedCalls: 47,
            estimatedCostUSD: 0.234,
            perFeature: [
                .init(label: "Hard-region OCR", model: "claude-sonnet-4-6",
                      calls: 30, costUSD: 0.18),
                .init(label: "Post-OCR cleanup", model: "claude-haiku-4-5",
                      calls: 17, costUSD: 0.054),
            ],
            clampedByCap: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            CostEstimator.Estimate.self, from: data
        )
        XCTAssertEqual(original, decoded)
    }
}
