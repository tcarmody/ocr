import XCTest
import CoreGraphics
import Document
import Layout
import OCR
@testable import Pipeline

/// Tests `RegionAwareReflow.classifyTopRegionsByRecurrence` —
/// document-level pass that distinguishes section headers (unique
/// to one page → `.sectionHeader`) from running heads (recurring
/// across many pages → `.pageHeader`) when Surya tagged both as
/// `.text`.
///
/// Conservative defaults: the pass requires a 3-page minimum
/// document and a 3-page recurrence threshold; below those it does
/// nothing (insufficient signal to discriminate).
final class RegionAwareReflowCrossPageTests: XCTestCase {

    // Page coordinates: y=0 bottom, y=1 top. (matches Surya output)

    /// Three pages, same normalized running-head text appears in the
    /// top zone of every page → all should be reclassified as
    /// `.pageHeader`.
    func test_recurring_top_text_across_pages_becomes_pageHeader() {
        let pages = (0..<3).map { pageIdx in
            makePage(
                pageIndex: pageIdx,
                topText: "Chapter 3 — Foo \(pageIdx + 47)"
            )
        }
        let result = RegionAwareReflow.classifyTopRegionsByRecurrence(
            pageResults: pages
        )
        XCTAssertEqual(result.overridesByPage.count, 3)
        for pageIdx in 0..<3 {
            XCTAssertEqual(result.overridesByPage[pageIdx]?[0], .pageHeader,
                "page \(pageIdx) top region should become pageHeader")
        }
    }

    /// Three pages where only ONE has a top-zone heading; the other
    /// two have body content only. The unique heading should be
    /// promoted to `.sectionHeader`.
    func test_unique_top_text_on_one_page_becomes_sectionHeader() {
        let withHeading = makePage(
            pageIndex: 0, topText: "Weber's Personality Type"
        )
        // Body-only pages (no top-zone candidate region).
        let plain1 = makeBodyOnlyPage(pageIndex: 1)
        let plain2 = makeBodyOnlyPage(pageIndex: 2)
        let result = RegionAwareReflow.classifyTopRegionsByRecurrence(
            pageResults: [withHeading, plain1, plain2]
        )
        XCTAssertEqual(result.overridesByPage[0]?[0], .sectionHeader,
            "unique top text should be promoted to sectionHeader")
        XCTAssertNil(result.overridesByPage[1])
        XCTAssertNil(result.overridesByPage[2])
    }

    /// Documents under the 3-page threshold get no overrides — too
    /// little signal to safely distinguish section vs running header.
    func test_two_page_document_skips_pass_entirely() {
        let p0 = makePage(pageIndex: 0, topText: "Title")
        let p1 = makePage(pageIndex: 1, topText: "Title")
        let result = RegionAwareReflow.classifyTopRegionsByRecurrence(
            pageResults: [p0, p1]
        )
        XCTAssertTrue(result.overridesByPage.isEmpty)
    }

    /// Mid-page section breaks (region's midY is not in the top zone)
    /// are NOT candidates — only top-of-page text gets considered.
    func test_mid_page_text_not_classified() {
        let region = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.04),
            readingOrder: 0, confidence: 1.0
        )
        let obs = TextObservation(
            text: "Mid-page text", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.51, width: 0.80, height: 0.02),
            source: .vision
        )
        let pages = [
            PageObservations(
                pageIndex: 0, pageBounds: .init(width: 600, height: 800),
                observations: [obs], layoutRegions: [region]
            ),
            makeBodyOnlyPage(pageIndex: 1),
            makeBodyOnlyPage(pageIndex: 2),
        ]
        let result = RegionAwareReflow.classifyTopRegionsByRecurrence(
            pageResults: pages
        )
        XCTAssertTrue(result.overridesByPage.isEmpty,
            "mid-page text must not be picked up by the cross-page pass")
    }

    /// Tall regions (body paragraphs that graze the top zone) are
    /// not candidates — height filter excludes them.
    func test_tall_top_region_not_classified() {
        let region = LayoutRegion(
            kind: .text,
            // midY = 0.93 → in top zone, BUT height = 0.50 way over 0.06.
            box: CGRect(x: 0.10, y: 0.68, width: 0.80, height: 0.50),
            readingOrder: 0, confidence: 1.0
        )
        let obs = TextObservation(
            text: "A long body paragraph", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.92, width: 0.80, height: 0.02),
            source: .vision
        )
        let pages = [
            PageObservations(
                pageIndex: 0, pageBounds: .init(width: 600, height: 800),
                observations: [obs], layoutRegions: [region]
            ),
            makeBodyOnlyPage(pageIndex: 1),
            makeBodyOnlyPage(pageIndex: 2),
        ]
        let result = RegionAwareReflow.classifyTopRegionsByRecurrence(
            pageResults: pages
        )
        XCTAssertTrue(result.overridesByPage.isEmpty)
    }

    /// Already-classified `.sectionHeader` / `.title` are untouched —
    /// the pass only operates on `.text` regions.
    func test_already_classified_heading_is_not_touched() {
        let alreadyHeader = LayoutRegion(
            kind: .sectionHeader,
            box: CGRect(x: 0.10, y: 0.92, width: 0.80, height: 0.04),
            readingOrder: 0, confidence: 1.0
        )
        let obs = TextObservation(
            text: "Heading", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.93, width: 0.80, height: 0.02),
            source: .vision
        )
        let pages = [
            PageObservations(
                pageIndex: 0, pageBounds: .init(width: 600, height: 800),
                observations: [obs], layoutRegions: [alreadyHeader]
            ),
            makeBodyOnlyPage(pageIndex: 1),
            makeBodyOnlyPage(pageIndex: 2),
        ]
        let result = RegionAwareReflow.classifyTopRegionsByRecurrence(
            pageResults: pages
        )
        XCTAssertTrue(result.overridesByPage.isEmpty)
    }

    /// End-to-end via the real reflow path: a top-of-page text region
    /// unique to a single page in a multi-page document should emit
    /// as a `<h2>` heading block, not `<p>`.
    func test_reflow_emits_unique_top_text_as_heading() {
        let p0 = makePage(pageIndex: 0, topText: "Weber's Personality Type")
        let p1 = makeBodyOnlyPage(pageIndex: 1)
        let p2 = makeBodyOnlyPage(pageIndex: 2)
        let result = RegionAwareReflow.reflow(pageResults: [p0, p1, p2])

        var sawHeading = false
        for block in result.blocks {
            if case .heading(_, let runs) = block,
               runs.first?.text.contains("Weber's Personality Type") == true {
                sawHeading = true
                break
            }
        }
        XCTAssertTrue(sawHeading,
            "unique top text in 3-page doc should emit as a heading")
    }

    // MARK: - fixture helpers

    /// Build a page with a single top-zone short text region whose
    /// observation carries `topText`, plus a generic body paragraph
    /// below.
    private func makePage(pageIndex: Int, topText: String) -> PageObservations {
        let topRegion = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.92, width: 0.80, height: 0.03),
            readingOrder: 0, confidence: 1.0
        )
        let body = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.70),
            readingOrder: 1, confidence: 1.0
        )
        let topObs = TextObservation(
            text: topText, confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.93, width: 0.80, height: 0.02),
            source: .vision
        )
        let bodyObs = TextObservation(
            text: "Body content for page \(pageIndex).", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.02),
            source: .vision
        )
        return PageObservations(
            pageIndex: pageIndex,
            pageBounds: .init(width: 600, height: 800),
            observations: [topObs, bodyObs],
            layoutRegions: [topRegion, body]
        )
    }

    /// Page with only a body region (no top-zone candidate).
    private func makeBodyOnlyPage(pageIndex: Int) -> PageObservations {
        let body = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.70),
            readingOrder: 0, confidence: 1.0
        )
        let bodyObs = TextObservation(
            text: "Body content for page \(pageIndex).", confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.50, width: 0.80, height: 0.02),
            source: .vision
        )
        return PageObservations(
            pageIndex: pageIndex,
            pageBounds: .init(width: 600, height: 800),
            observations: [bodyObs],
            layoutRegions: [body]
        )
    }
}
