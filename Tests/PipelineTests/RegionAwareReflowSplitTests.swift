import XCTest
import CoreGraphics
import Document
import Layout
import OCR
@testable import Pipeline

/// Tests `RegionAwareReflow.splitTextRegionsAtFootnoteGap` and the
/// page-number bypass added to
/// `RegionAwareReflow.reclassifyLikelyHeadersFooters`.
///
/// The split heuristic targets a real-world failure mode — Surya
/// merging body text + the footnotes beneath it into a single
/// `.text` region (the horizontal-rule separator didn't break it).
/// The dual gate is `gap ≥ 2.5 × medianLineHeight` AND
/// `belowGap.startsWithFootnoteMarker`.
final class RegionAwareReflowSplitTests: XCTestCase {

    // Page coordinates: y=0 bottom, y=1 top. (matches Surya output)

    /// Body text + numeric footnote at the bottom, all merged into
    /// one Surya `.text` region. Should split into upper `.text`
    /// (body) + lower `.footnote`.
    func test_body_with_trailing_footnote_is_split() {
        let merged = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80),
            readingOrder: 0, confidence: 1.0
        )
        // 3 body lines packed close together near the top.
        let body1 = TextObservation(
            text: "First body line.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.85, width: 0.80, height: 0.02),
            source: .vision
        )
        let body2 = TextObservation(
            text: "Second body line.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.82, width: 0.80, height: 0.02),
            source: .vision
        )
        let body3 = TextObservation(
            text: "Third body line.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.79, width: 0.80, height: 0.02),
            source: .vision
        )
        // Footnote at the bottom, separated by a large gap (~10% of
        // page) → 5× the 0.02 line height → above the 2.5× threshold.
        let footnoteObs = TextObservation(
            text: "1 Allan Sica, Max Weber: A Comprehensive Bibliography.",
            confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.15, width: 0.80, height: 0.02),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.splitTextRegionsAtFootnoteGap(
            regions: [merged],
            observations: [body1, body2, body3, footnoteObs]
        )
        XCTAssertEqual(decisions.count, 1, "split should fire")
        XCTAssertEqual(out.count, 2, "one region in → two regions out")
        XCTAssertEqual(out[0].kind, .text, "upper stays as body text")
        XCTAssertEqual(out[1].kind, .footnote, "lower becomes footnote")
        XCTAssertGreaterThan(out[0].box.minY, out[1].box.maxY,
            "upper bbox sits above lower bbox")
    }

    /// Plain paragraph with no footnote-like content beneath it —
    /// even if there's a wide gap, the marker check fails so no split.
    func test_plain_paragraph_no_marker_below_is_not_split() {
        let region = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80),
            readingOrder: 0, confidence: 1.0
        )
        let above = TextObservation(
            text: "Top of paragraph.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.85, width: 0.80, height: 0.02),
            source: .vision
        )
        // Big gap, but the lower text doesn't start with a marker.
        let below = TextObservation(
            text: "Continuation prose.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.30, width: 0.80, height: 0.02),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.splitTextRegionsAtFootnoteGap(
            regions: [region], observations: [above, below]
        )
        XCTAssertEqual(decisions.count, 0)
        XCTAssertEqual(out.count, 1)
    }

    /// Paragraph with normal line spacing (gap ~1× line height) and
    /// footnote-marker text below — gap signal fails, no split.
    /// Protects mid-paragraph "1." that's actually body content.
    func test_tight_spacing_with_marker_below_is_not_split() {
        let region = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.20),
            readingOrder: 0, confidence: 1.0
        )
        let line1 = TextObservation(
            text: "It merits attention for the following reasons.",
            confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.66, width: 0.80, height: 0.02),
            source: .vision
        )
        // Gap ~0.02 — same as line height → not large enough.
        let line2 = TextObservation(
            text: "1. The first point made here.",
            confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.62, width: 0.80, height: 0.02),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.splitTextRegionsAtFootnoteGap(
            regions: [region], observations: [line1, line2]
        )
        XCTAssertEqual(decisions.count, 0)
        XCTAssertEqual(out.count, 1)
    }

    /// Already a `.footnote` region → never split (only `.text`
    /// regions are candidates).
    func test_already_footnote_region_is_not_split() {
        let region = LayoutRegion(
            kind: .footnote,
            box: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.20),
            readingOrder: 0, confidence: 1.0
        )
        let obs = TextObservation(
            text: "1 An existing footnote.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.20, width: 0.80, height: 0.02),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.splitTextRegionsAtFootnoteGap(
            regions: [region], observations: [obs]
        )
        XCTAssertEqual(decisions.count, 0)
        XCTAssertEqual(out, [region])
    }

    /// Page-number bypass: a `.text` region in the bottom 10% whose
    /// content is nothing but "1" gets reclassified as `.pageFooter`
    /// even though height (Surya bundled the rule) would normally
    /// fail the furniture-height gate.
    func test_pageNumber_bypass_reclassifies_tall_pageNumber_region() {
        // Region is taller than the 0.05 furniture cap because Surya
        // bundled the horizontal rule with the page number.
        let region = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.40, y: 0.02, width: 0.20, height: 0.07),
            readingOrder: 0, confidence: 1.0
        )
        let obs = TextObservation(
            text: "1", confidence: 1.0,
            box: CGRect(x: 0.45, y: 0.05, width: 0.10, height: 0.015),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.reclassifyLikelyHeadersFooters(
            regions: [region], observations: [obs]
        )
        XCTAssertEqual(out[0].kind, .pageFooter,
            "standalone page number in bottom zone should reclassify regardless of height")
        XCTAssertEqual(decisions.count, 1)
        XCTAssertTrue(decisions[0].signals.contains { $0.contains("page-number bypass") })
    }

    /// Bypass must NOT fire for non-numeric content even if it's
    /// short — protects against "Note." or other short labels at
    /// the bottom that aren't page numbers.
    func test_pageNumber_bypass_does_not_fire_on_non_numeric_short_text() {
        let region = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.40, y: 0.02, width: 0.20, height: 0.07),  // tall
            readingOrder: 0, confidence: 1.0
        )
        let obs = TextObservation(
            text: "Note.", confidence: 1.0,
            box: CGRect(x: 0.45, y: 0.05, width: 0.10, height: 0.015),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.reclassifyLikelyHeadersFooters(
            regions: [region], observations: [obs]
        )
        // Non-numeric → falls back to standard path; height exceeds
        // 0.05 → standard path rejects.
        XCTAssertEqual(out[0].kind, .text)
        XCTAssertEqual(decisions.count, 0)
    }
}
