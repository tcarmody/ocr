import XCTest
import CoreGraphics
import Document
import Layout
import OCR
@testable import Pipeline

/// Tests the conservative header/footer reclassification heuristic
/// in `RegionAwareReflow.reclassifyLikelyHeadersFooters`. Surya
/// often tags running heads / page numbers as `.text` instead of
/// `.pageHeader`/`.pageFooter`; this heuristic catches them
/// structurally so they don't pollute the body block stream.
///
/// Heuristic gate: top/bottom 10% zone + region height ≤ 5% +
/// total text ≤ 100 chars. All three signals must agree.
final class RegionAwareReflowHeaderFooterTests: XCTestCase {

    // Page coordinates: y=0 bottom, y=1 top. (matches Surya output)

    /// Classic running head — short region near the top edge with
    /// a chapter title and page number. All three signals fire.
    func test_running_head_at_top_is_reclassified_as_pageHeader() {
        let header = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.945, width: 0.80, height: 0.025),
            readingOrder: 0, confidence: 1.0
        )
        let body = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.20, width: 0.80, height: 0.65),
            readingOrder: 1, confidence: 1.0
        )
        let headerObs = TextObservation(
            text: "Chapter 3 — On Power 47", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.955, width: 0.80, height: 0.02),
            source: .vision
        )
        let bodyObs = TextObservation(
            text: "Long body text here.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.02),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.reclassifyLikelyHeadersFooters(
            regions: [header, body],
            observations: [headerObs, bodyObs]
        )
        XCTAssertEqual(out[0].kind, .pageHeader, "header reclassified")
        XCTAssertEqual(out[1].kind, .text, "body untouched")
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions[0].newKind, "pageHeader")
    }

    /// Page number alone at the bottom — short region, very short
    /// text. Should reclassify as `.pageFooter`.
    func test_page_number_at_bottom_is_reclassified_as_pageFooter() {
        let footer = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.45, y: 0.04, width: 0.10, height: 0.02),
            readingOrder: 0, confidence: 1.0
        )
        let footerObs = TextObservation(
            text: "47", confidence: 1.0,
            box: CGRect(x: 0.45, y: 0.05, width: 0.10, height: 0.015),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.reclassifyLikelyHeadersFooters(
            regions: [footer], observations: [footerObs]
        )
        XCTAssertEqual(out[0].kind, .pageFooter)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions[0].newKind, "pageFooter")
    }

    /// Body paragraph that grazes into the top 10% zone — height
    /// signal saves it. Must NOT be reclassified.
    func test_tall_body_in_top_zone_is_not_reclassified() {
        let body = LayoutRegion(
            kind: .text,
            // midY = 0.93 → in top zone, BUT height = 0.40 > 0.05.
            box: CGRect(x: 0.10, y: 0.73, width: 0.80, height: 0.40),
            readingOrder: 0, confidence: 1.0
        )
        let obs = TextObservation(
            text: "A long body paragraph that extends close to the top margin.",
            confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.93, width: 0.80, height: 0.02),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.reclassifyLikelyHeadersFooters(
            regions: [body], observations: [obs]
        )
        XCTAssertEqual(out[0].kind, .text)
        XCTAssertEqual(decisions.count, 0)
    }

    /// Section header sitting near the top with substantial text —
    /// brevity signal protects it (and the height filter would too).
    /// Must NOT reclassify.
    func test_long_text_in_top_zone_is_not_reclassified() {
        let region = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.945, width: 0.80, height: 0.025),
            readingOrder: 0, confidence: 1.0
        )
        // 110 chars — over the 100-char brevity cap.
        let longText = String(repeating: "abcde fghij ", count: 10)
        let obs = TextObservation(
            text: longText, confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.955, width: 0.80, height: 0.02),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.reclassifyLikelyHeadersFooters(
            regions: [region], observations: [obs]
        )
        XCTAssertEqual(out[0].kind, .text, "long text fails brevity check")
        XCTAssertEqual(decisions.count, 0)
    }

    /// Mid-page region — fails position check immediately.
    func test_short_region_in_middle_is_not_reclassified() {
        let region = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.025),
            readingOrder: 0, confidence: 1.0
        )
        let obs = TextObservation(
            text: "Short mid-page text.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.51, width: 0.80, height: 0.02),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.reclassifyLikelyHeadersFooters(
            regions: [region], observations: [obs]
        )
        XCTAssertEqual(out[0].kind, .text)
        XCTAssertEqual(decisions.count, 0)
    }

    /// Section header that Surya already tagged correctly — we must
    /// not touch non-`.text` regions even if they sit in an extreme
    /// zone with short text.
    func test_non_text_region_in_extreme_zone_is_not_reclassified() {
        let header = LayoutRegion(
            kind: .sectionHeader,
            box: CGRect(x: 0.10, y: 0.945, width: 0.80, height: 0.025),
            readingOrder: 0, confidence: 1.0
        )
        let obs = TextObservation(
            text: "I. The Question", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.955, width: 0.80, height: 0.02),
            source: .vision
        )
        let (out, decisions) = RegionAwareReflow.reclassifyLikelyHeadersFooters(
            regions: [header], observations: [obs]
        )
        XCTAssertEqual(out[0].kind, .sectionHeader)
        XCTAssertEqual(decisions.count, 0)
    }

    /// Pipeline ordering check: a 1-line footnote in the bottom 10%
    /// gets reclassified to `.footnote` by the footnote pass first,
    /// and the H/F pass must then leave it alone (so its popup
    /// linking still works downstream).
    func test_footnote_pass_runs_first_protects_short_footnote() {
        // Body region high on the page so the footnote pass sees a
        // big gap above the candidate.
        let body = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.5, width: 0.80, height: 0.40),
            readingOrder: 0, confidence: 1.0
        )
        let footnote = LayoutRegion(
            kind: .text,
            // midY = 0.06 → in bottom zone; height = 0.025 → short;
            // text is short. Without footnote-first ordering, this
            // would be reclassified as .pageFooter.
            box: CGRect(x: 0.10, y: 0.045, width: 0.80, height: 0.025),
            readingOrder: 1, confidence: 1.0
        )
        let bodyObs = TextObservation(
            text: "Body paragraph content.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.7, width: 0.80, height: 0.02),
            source: .vision
        )
        let footnoteObs = TextObservation(
            text: "1. A short footnote.", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.055, width: 0.80, height: 0.02),
            source: .vision
        )
        // Step 1: footnote pass should retag.
        let (afterFootnotes, fnDecisions) = RegionAwareReflow.reclassifyLikelyFootnotes(
            regions: [body, footnote], observations: [bodyObs, footnoteObs]
        )
        XCTAssertEqual(afterFootnotes[1].kind, .footnote, "footnote pass retags first")
        XCTAssertEqual(fnDecisions.count, 1)
        // Step 2: H/F pass should leave the now-`.footnote` region alone.
        let (final, hfDecisions) = RegionAwareReflow.reclassifyLikelyHeadersFooters(
            regions: afterFootnotes, observations: [bodyObs, footnoteObs]
        )
        XCTAssertEqual(final[1].kind, .footnote, "H/F pass leaves footnotes alone")
        XCTAssertEqual(hfDecisions.count, 0)
    }
}
