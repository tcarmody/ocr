import XCTest
import CoreGraphics
import Document
import Layout
import OCR
@testable import Pipeline

/// Tests `RegionAwareReflow.correctHeadingReadingOrder` — fixes for
/// Surya's reading-order glitches where it correctly identifies a
/// heading region but assigns it an order index that places the
/// heading after the body content beneath it.
///
/// The promotion is conservative on purpose: only fires when the
/// heading sits visually above ALL body regions. Mid-page section
/// breaks (heading legitimately after some body) must not be moved.
final class RegionAwareReflowHeadingOrderTests: XCTestCase {

    // Page coordinates: y=0 bottom, y=1 top. (matches Surya output)

    /// Classic case: heading at top, body below, Surya assigned the
    /// heading reading-order index AFTER the body. Heading should
    /// be promoted to a smaller (earlier-sorting) index.
    func test_top_heading_after_body_in_order_is_promoted() {
        let body = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.20, width: 0.80, height: 0.60),
            readingOrder: 0, confidence: 1.0
        )
        let heading = LayoutRegion(
            kind: .sectionHeader,
            box: CGRect(x: 0.30, y: 0.88, width: 0.40, height: 0.04),
            readingOrder: 1, confidence: 1.0
        )
        let bodyObs = TextObservation(
            text: "Body line.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.02),
            source: .vision
        )
        let headingObs = TextObservation(
            text: "MAX WEBER", confidence: 1.0,
            box: CGRect(x: 0.30, y: 0.89, width: 0.40, height: 0.02),
            source: .vision
        )
        let (out, promotions) = RegionAwareReflow.correctHeadingReadingOrder(
            regions: [body, heading], observations: [bodyObs, headingObs]
        )
        XCTAssertEqual(promotions.count, 1)
        XCTAssertEqual(promotions[0].kind, "sectionHeader")
        // After promotion, heading sorts before body.
        XCTAssertLessThan(out[1].readingOrder, out[0].readingOrder,
            "promoted heading must sort before body")
    }

    /// Heading sitting above body and ALREADY ordered first — no-op.
    func test_top_heading_already_ordered_first_is_left_alone() {
        let heading = LayoutRegion(
            kind: .sectionHeader,
            box: CGRect(x: 0.30, y: 0.88, width: 0.40, height: 0.04),
            readingOrder: 0, confidence: 1.0
        )
        let body = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.20, width: 0.80, height: 0.60),
            readingOrder: 1, confidence: 1.0
        )
        let bodyObs = TextObservation(
            text: "Body.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.02),
            source: .vision
        )
        let headingObs = TextObservation(
            text: "TITLE", confidence: 1.0,
            box: CGRect(x: 0.30, y: 0.89, width: 0.40, height: 0.02),
            source: .vision
        )
        let (out, promotions) = RegionAwareReflow.correctHeadingReadingOrder(
            regions: [heading, body], observations: [bodyObs, headingObs]
        )
        XCTAssertEqual(promotions.count, 0)
        XCTAssertEqual(out[0].readingOrder, 0)
        XCTAssertEqual(out[1].readingOrder, 1)
    }

    /// Mid-page section break — heading is BELOW some body and ABOVE
    /// other body. The "above all body" gate should leave it alone
    /// even if its order looks weird.
    func test_mid_page_heading_with_body_above_is_not_promoted() {
        let bodyAbove = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.65, width: 0.80, height: 0.30),
            readingOrder: 0, confidence: 1.0
        )
        let heading = LayoutRegion(
            kind: .sectionHeader,
            box: CGRect(x: 0.30, y: 0.50, width: 0.40, height: 0.04),
            readingOrder: 1, confidence: 1.0
        )
        let bodyBelow = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.30),
            readingOrder: 2, confidence: 1.0
        )
        let obs: [TextObservation] = []  // Position-only logic; obs not needed for the gate
        let (out, promotions) = RegionAwareReflow.correctHeadingReadingOrder(
            regions: [bodyAbove, heading, bodyBelow], observations: obs
        )
        XCTAssertEqual(promotions.count, 0,
            "mid-page heading with body above must not be promoted")
        XCTAssertEqual(out[1].readingOrder, 1)
    }

    /// Multiple top-of-page headings (e.g. a title + a section
    /// header) should all be promoted, preserving their visual
    /// top-down order.
    func test_multiple_stacked_top_headings_preserve_visual_order() {
        let title = LayoutRegion(
            kind: .title,
            box: CGRect(x: 0.30, y: 0.92, width: 0.40, height: 0.04),
            readingOrder: 2, confidence: 1.0
        )
        let subhead = LayoutRegion(
            kind: .sectionHeader,
            box: CGRect(x: 0.30, y: 0.85, width: 0.40, height: 0.04),
            readingOrder: 1, confidence: 1.0
        )
        let body = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.20, width: 0.80, height: 0.60),
            readingOrder: 0, confidence: 1.0
        )
        let titleObs = TextObservation(
            text: "TITLE", confidence: 1.0,
            box: CGRect(x: 0.30, y: 0.93, width: 0.40, height: 0.02),
            source: .vision
        )
        let subObs = TextObservation(
            text: "Subtitle", confidence: 1.0,
            box: CGRect(x: 0.30, y: 0.86, width: 0.40, height: 0.02),
            source: .vision
        )
        let bodyObs = TextObservation(
            text: "Body.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.02),
            source: .vision
        )
        let (out, promotions) = RegionAwareReflow.correctHeadingReadingOrder(
            regions: [title, subhead, body],
            observations: [titleObs, subObs, bodyObs]
        )
        XCTAssertEqual(promotions.count, 2)
        // Title (higher midY) must sort before subhead.
        XCTAssertLessThan(out[0].readingOrder, out[1].readingOrder)
        // Both before body.
        XCTAssertLessThan(out[1].readingOrder, out[2].readingOrder)
    }

    /// A page with no body anchors (e.g. all headings + figures) —
    /// no comparison point exists, so the function leaves order alone.
    func test_no_body_anchors_returns_regions_unchanged() {
        let title = LayoutRegion(
            kind: .title,
            box: CGRect(x: 0.30, y: 0.92, width: 0.40, height: 0.04),
            readingOrder: 1, confidence: 1.0
        )
        let figure = LayoutRegion(
            kind: .picture,
            box: CGRect(x: 0.10, y: 0.20, width: 0.80, height: 0.60),
            readingOrder: 0, confidence: 1.0
        )
        let (out, promotions) = RegionAwareReflow.correctHeadingReadingOrder(
            regions: [title, figure], observations: []
        )
        XCTAssertEqual(promotions.count, 0)
        XCTAssertEqual(out[0].readingOrder, 1)
        XCTAssertEqual(out[1].readingOrder, 0)
    }

    /// Non-heading region in the top zone (e.g. a `.text` region
    /// that happens to be tall and starts at the top) must not be
    /// promoted — only `.title` / `.sectionHeader` are eligible.
    func test_non_heading_top_region_is_not_promoted() {
        let topText = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.85, width: 0.80, height: 0.10),
            readingOrder: 5, confidence: 1.0
        )
        let body = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.20, width: 0.80, height: 0.60),
            readingOrder: 0, confidence: 1.0
        )
        let (out, promotions) = RegionAwareReflow.correctHeadingReadingOrder(
            regions: [topText, body], observations: []
        )
        XCTAssertEqual(promotions.count, 0)
        XCTAssertEqual(out[0].readingOrder, 5)
    }

    /// End-to-end check via the real reflow path: the heading must
    /// emit BEFORE the body paragraph in the block stream.
    func test_reflow_emits_promoted_heading_before_body() {
        let body = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.20, width: 0.80, height: 0.60),
            readingOrder: 0, confidence: 1.0
        )
        let heading = LayoutRegion(
            kind: .sectionHeader,
            box: CGRect(x: 0.30, y: 0.88, width: 0.40, height: 0.04),
            readingOrder: 1, confidence: 1.0
        )
        let bodyObs = TextObservation(
            text: "Body line one.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.02),
            source: .vision
        )
        let headingObs = TextObservation(
            text: "MAX WEBER", confidence: 1.0,
            box: CGRect(x: 0.30, y: 0.89, width: 0.40, height: 0.02),
            source: .vision
        )
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 600, height: 800),
            observations: [bodyObs, headingObs],
            layoutRegions: [body, heading]
        )
        let result = RegionAwareReflow.reflow(pageResults: [page])

        // Find the heading and the paragraph in the resulting blocks.
        var headingPos: Int? = nil
        var bodyPos: Int? = nil
        for (i, block) in result.blocks.enumerated() {
            switch block {
            case .heading(_, let runs):
                if runs.first?.text.contains("MAX WEBER") == true { headingPos = i }
            case .paragraph(let runs):
                if runs.first?.text.contains("Body line one") == true { bodyPos = i }
            default:
                break
            }
        }
        XCTAssertNotNil(headingPos, "heading must appear in output")
        XCTAssertNotNil(bodyPos, "body paragraph must appear in output")
        XCTAssertLessThan(headingPos!, bodyPos!,
            "heading must emit before body in the block stream")
    }
}
