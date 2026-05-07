import XCTest
@testable import Pipeline

/// `PDFToEPUBPipeline.Options.shouldForceOCR(forPageIndex:)` —
/// the per-page gate that cascades the global `forceOCR` flag
/// over every per-page check site (cascade verdict, page-OCR
/// E-Routing trust check, batch prep trust check, checkpoint
/// resume guard).
final class OptionsForceOCRTests: XCTestCase {

    func test_global_forceOCR_overrides_every_page() {
        let opts = PDFToEPUBPipeline.Options(forceOCR: true)
        for i in 0...500 {
            XCTAssertTrue(opts.shouldForceOCR(forPageIndex: i),
                "global forceOCR should cover page \(i)")
        }
    }

    func test_no_force_means_no_pages_match() {
        let opts = PDFToEPUBPipeline.Options(forceOCR: false)
        for i in 0...500 {
            XCTAssertFalse(opts.shouldForceOCR(forPageIndex: i))
        }
    }

    func test_per_page_ranges_match_only_listed_pages() {
        let opts = PDFToEPUBPipeline.Options(
            forceOCRPageRanges: [0...19, 149...159]
        )
        // 0-19 inclusive (20 pages) → match
        for i in 0...19 {
            XCTAssertTrue(opts.shouldForceOCR(forPageIndex: i),
                "page \(i) should match the 0...19 range")
        }
        // 20...148 → no match
        XCTAssertFalse(opts.shouldForceOCR(forPageIndex: 20))
        XCTAssertFalse(opts.shouldForceOCR(forPageIndex: 100))
        XCTAssertFalse(opts.shouldForceOCR(forPageIndex: 148))
        // 149...159 inclusive → match
        for i in 149...159 {
            XCTAssertTrue(opts.shouldForceOCR(forPageIndex: i))
        }
        // beyond → no match
        XCTAssertFalse(opts.shouldForceOCR(forPageIndex: 160))
        XCTAssertFalse(opts.shouldForceOCR(forPageIndex: 999))
    }

    func test_global_forceOCR_combines_with_per_page_ranges() {
        // Either signal is sufficient — global true OR in any
        // range. Compose additively.
        let opts = PDFToEPUBPipeline.Options(
            forceOCR: true,
            forceOCRPageRanges: [50...60]
        )
        XCTAssertTrue(opts.shouldForceOCR(forPageIndex: 0),
            "global covers page 0 even when not in per-page ranges")
        XCTAssertTrue(opts.shouldForceOCR(forPageIndex: 55),
            "per-page covers page 55 (also covered by global)")
        XCTAssertTrue(opts.shouldForceOCR(forPageIndex: 999),
            "global covers high pages even when not in per-page ranges")
    }
}
