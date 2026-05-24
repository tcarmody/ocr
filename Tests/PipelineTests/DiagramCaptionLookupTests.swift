import XCTest
import CoreGraphics
import Layout
import OCR
@testable import Pipeline

/// `PDFToEPUBPipeline.lookupCaptionText` — used by the post-
/// cascade diagram-extraction phase (P-Diagram-Description
/// Option B) to resolve a figure's printed caption text from the
/// book-wide `CaptionAssociator.Associations` map. Caption text
/// flows into Sonnet's prompt so the generated alt text /
/// description stay consistent with what the caption says.
final class DiagramCaptionLookupTests: XCTestCase {

    // MARK: - Helpers

    private func picture(x: CGFloat, y: CGFloat,
                        w: CGFloat = 0.5, h: CGFloat = 0.3) -> LayoutRegion {
        LayoutRegion(
            kind: .picture,
            box: CGRect(x: x, y: y, width: w, height: h),
            readingOrder: 0, confidence: 0.95
        )
    }

    private func caption(x: CGFloat, y: CGFloat,
                        w: CGFloat = 0.5, h: CGFloat = 0.03) -> LayoutRegion {
        LayoutRegion(
            kind: .caption,
            box: CGRect(x: x, y: y, width: w, height: h),
            readingOrder: 1, confidence: 0.95
        )
    }

    private func obs(_ text: String,
                     x: CGFloat, y: CGFloat,
                     w: CGFloat = 0.4, h: CGFloat = 0.02) -> TextObservation {
        TextObservation(
            text: text, confidence: 1,
            box: CGRect(x: x, y: y, width: w, height: h),
            source: .vision
        )
    }

    // MARK: - Tests

    func test_resolves_caption_text_for_associated_figure() {
        // Page layout: picture occupies upper-middle, caption sits
        // just below it. CaptionAssociator pairs them; lookup
        // should return the OCR'd caption text.
        let pic = picture(x: 0.25, y: 0.55)
        let cap = caption(x: 0.25, y: 0.50)
        let regions = [pic, cap]
        let regionsByPage = [0: regions]
        let associations = CaptionAssociator.associate(
            regionsByPage: regionsByPage
        )
        let figureKey = CaptionAssociator.PageRegionKey(
            pageIndex: 0, regionIndex: 0
        )
        // Confirm the associator actually paired them; otherwise
        // the test would silently pass for the wrong reason.
        XCTAssertNotNil(associations.captionByFigure[figureKey])
        let observations = [
            obs("Figure 3.1: Marriage market dynamics",
                x: 0.25, y: 0.51, w: 0.5, h: 0.02),
        ]
        let result = PDFToEPUBPipeline.lookupCaptionText(
            forFigure: figureKey,
            associations: associations,
            regionsByPage: regionsByPage,
            observationsByPage: [0: observations]
        )
        XCTAssertEqual(
            result, "Figure 3.1: Marriage market dynamics"
        )
    }

    func test_returns_nil_when_figure_has_no_associated_caption() {
        // A `.picture` with nothing nearby — orientation vote may
        // still happen but no pairing assignment for this one.
        // Lookup returns nil; the extractor prompt then skips the
        // caption header.
        let regions = [picture(x: 0.25, y: 0.5)]
        let associations = CaptionAssociator.associate(
            regionsByPage: [0: regions]
        )
        let key = CaptionAssociator.PageRegionKey(
            pageIndex: 0, regionIndex: 0
        )
        let result = PDFToEPUBPipeline.lookupCaptionText(
            forFigure: key,
            associations: associations,
            regionsByPage: [0: regions],
            observationsByPage: [0: []]
        )
        XCTAssertNil(result)
    }

    func test_joins_multi_observation_caption_text_in_reading_order() {
        // Caption that OCR returned as two observations — should
        // join them top-down / left-right into one string.
        let pic = picture(x: 0.25, y: 0.55)
        let cap = caption(x: 0.25, y: 0.50, h: 0.04)
        let regions = [pic, cap]
        let associations = CaptionAssociator.associate(
            regionsByPage: [0: regions]
        )
        let figureKey = CaptionAssociator.PageRegionKey(
            pageIndex: 0, regionIndex: 0
        )
        // Two observations stacked inside the caption bbox.
        // Higher Y = top of page → first in reading order.
        let observations = [
            obs("Figure 3.1:", x: 0.25, y: 0.52, w: 0.2, h: 0.02),
            obs("Marriage market dynamics",
                x: 0.30, y: 0.50, w: 0.3, h: 0.02),
        ]
        let result = PDFToEPUBPipeline.lookupCaptionText(
            forFigure: figureKey,
            associations: associations,
            regionsByPage: [0: regions],
            observationsByPage: [0: observations]
        )
        XCTAssertEqual(
            result,
            "Figure 3.1: Marriage market dynamics"
        )
    }

    func test_returns_nil_when_caption_region_has_no_observations() {
        // The associator paired a figure with a caption region,
        // but Vision didn't OCR any text inside that region
        // (rare, but happens for low-confidence captions).
        // Lookup returns nil so the extractor still runs but
        // without the caption-consistency anchor.
        let pic = picture(x: 0.25, y: 0.55)
        let cap = caption(x: 0.25, y: 0.50)
        let regions = [pic, cap]
        let associations = CaptionAssociator.associate(
            regionsByPage: [0: regions]
        )
        let figureKey = CaptionAssociator.PageRegionKey(
            pageIndex: 0, regionIndex: 0
        )
        // Observation lives outside the caption bbox.
        let observations = [
            obs("body text", x: 0.25, y: 0.20, w: 0.5, h: 0.02),
        ]
        let result = PDFToEPUBPipeline.lookupCaptionText(
            forFigure: figureKey,
            associations: associations,
            regionsByPage: [0: regions],
            observationsByPage: [0: observations]
        )
        XCTAssertNil(result)
    }
}
