import XCTest
import CoreGraphics
import Document
import Layout
import OCR
@testable import Pipeline

/// Tests the conservative footnote reclassification heuristic in
/// `RegionAwareReflow.reclassifyLikelyFootnotes`. The heuristic is
/// load-bearing for academic-book conversions because Surya routinely
/// tags long footnote blocks as `.text`. It also has to NOT misfire
/// on numbered lists embedded in body text — those look superficially
/// similar (start with `1.`) but sit close to their preceding paragraph
/// instead of being visually separated like a footnote.
final class RegionAwareReflowReclassifyTests: XCTestCase {

    // Page coordinates: y=0 bottom, y=1 top. (matches Surya output)

    /// Standalone footnote with all three signals firing — should
    /// reclassify.
    func test_classic_bottom_footnote_with_gap_is_reclassified() {
        let bodyTop = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.2),  // top of column
            readingOrder: 0, confidence: 1.0
        )
        let footnote = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.15),  // bottom of column
            readingOrder: 1, confidence: 0.85
        )
        // Body observation
        let bodyObs = TextObservation(
            text: "Body text here.", confidence: 1.0,
            box: CGRect(x: 0.1, y: 0.85, width: 0.4, height: 0.02),
            source: .vision
        )
        // Footnote observation — first line starts with marker
        let footnoteObs = TextObservation(
            text: "1. To this same question, Mendelssohn replied.",
            confidence: 0.9,
            box: CGRect(x: 0.1, y: 0.23, width: 0.4, height: 0.02),
            source: .vision
        )

        let (out, decisions) = RegionAwareReflow.reclassifyLikelyFootnotes(
            regions: [bodyTop, footnote],
            observations: [bodyObs, footnoteObs]
        )
        XCTAssertEqual(out[0].kind, .text, "body region untouched")
        XCTAssertEqual(out[1].kind, .footnote, "footnote region reclassified")
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions[0].regionIndex, 1)
        XCTAssertEqual(decisions[0].newKind, "footnote")
    }

    /// Numbered list in body text — same column, tight spacing,
    /// starts with `1.`. Must NOT be reclassified.
    func test_numbered_list_close_to_body_is_not_reclassified() {
        let body = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.1, y: 0.40, width: 0.4, height: 0.20),  // mid-page
            readingOrder: 0, confidence: 1.0
        )
        let listItem = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.1, y: 0.30, width: 0.4, height: 0.08),  // immediately below
            readingOrder: 1, confidence: 1.0
        )
        let bodyObs = TextObservation(
            text: "It merits attention for several reasons.", confidence: 1.0,
            box: CGRect(x: 0.1, y: 0.55, width: 0.4, height: 0.02),
            source: .vision
        )
        let listObs = TextObservation(
            text: "1. To this same question, Mendelssohn replied.",
            confidence: 1.0,
            box: CGRect(x: 0.1, y: 0.36, width: 0.4, height: 0.02),
            source: .vision
        )

        let (out, decisions) = RegionAwareReflow.reclassifyLikelyFootnotes(
            regions: [body, listItem],
            observations: [bodyObs, listObs]
        )
        XCTAssertEqual(out[1].kind, .text, "tight-spacing list item stays as text")
        XCTAssertEqual(decisions.count, 0)
    }

    /// Footnote at the top of the page (rare but possible) — fails
    /// the position check, should NOT be reclassified.
    func test_top_of_page_marker_is_not_reclassified() {
        let topRegion = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.1, y: 0.85, width: 0.4, height: 0.10),  // top
            readingOrder: 0, confidence: 1.0
        )
        let obs = TextObservation(
            text: "1. This is at the top of the page.", confidence: 1.0,
            box: CGRect(x: 0.1, y: 0.92, width: 0.4, height: 0.02),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.reclassifyLikelyFootnotes(
            regions: [topRegion], observations: [obs]
        )
        XCTAssertEqual(out[0].kind, .text)
        XCTAssertEqual(decisions.count, 0)
    }

    /// Symbolic markers (`*`, `†`, `‡`) also count.
    func test_asterisk_marker_with_gap_is_reclassified() {
        let body = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.2),
            readingOrder: 0, confidence: 1.0
        )
        let footnote = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.1, y: 0.05, width: 0.4, height: 0.10),
            readingOrder: 1, confidence: 1.0
        )
        let bodyObs = TextObservation(
            text: "Body content.", confidence: 1.0,
            box: CGRect(x: 0.1, y: 0.85, width: 0.4, height: 0.02),
            source: .vision
        )
        let footnoteObs = TextObservation(
            text: "* This translation has been amended.", confidence: 1.0,
            box: CGRect(x: 0.1, y: 0.13, width: 0.4, height: 0.02),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.reclassifyLikelyFootnotes(
            regions: [body, footnote],
            observations: [bodyObs, footnoteObs]
        )
        XCTAssertEqual(out[1].kind, .footnote)
        XCTAssertEqual(decisions.count, 1)
    }

    /// Region in different column than the body above — gap check
    /// looks within the same column only.
    func test_different_column_does_not_count_as_preceding_region() {
        // Left column body, top of page.
        let leftBody = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.05, y: 0.6, width: 0.40, height: 0.30),
            readingOrder: 0, confidence: 1.0
        )
        // Right column footnote, bottom of page — different X center.
        let rightFootnote = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.55, y: 0.05, width: 0.40, height: 0.10),
            readingOrder: 1, confidence: 1.0
        )
        let leftObs = TextObservation(
            text: "Left column body.", confidence: 1.0,
            box: CGRect(x: 0.05, y: 0.85, width: 0.40, height: 0.02),
            source: .vision
        )
        let rightObs = TextObservation(
            text: "1. Footnote in right column.", confidence: 1.0,
            box: CGRect(x: 0.55, y: 0.13, width: 0.40, height: 0.02),
            source: .vision
        )
        let (out, _) = RegionAwareReflow.reclassifyLikelyFootnotes(
            regions: [leftBody, rightFootnote],
            observations: [leftObs, rightObs]
        )
        // No preceding region in the right column → gap check
        // passes by default; reclassify.
        XCTAssertEqual(out[1].kind, .footnote,
            "footnote in a column with no preceding region should still reclassify")
    }
}
