import XCTest
import CoreGraphics
import Document
import Layout
import OCR
@testable import Pipeline

/// When Surya bundles both columns of a 2-column page into a single
/// `.text` region, the in-region Y/X sort produces row-by-row reading
/// across columns ("L0 R0 L1 R1 …"). `RegionAwareReflow` should run
/// `ColumnSplitter` on wide `.text` regions to split a clear gutter
/// into per-column paragraph blocks.
final class RegionAwareReflowColumnSplitTests: XCTestCase {

    /// One wide `.text` region containing both columns. The reflow
    /// should emit two paragraph blocks, left column then right
    /// column, each preserving top-to-bottom order within the column.
    func test_singleWideRegion_with_two_columns_emits_two_paragraphs() {
        let region = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80),
            readingOrder: 0,
            confidence: 1.0
        )
        var obs: [TextObservation] = []
        for i in 0..<10 {
            let y = 0.85 - CGFloat(i) * 0.04
            obs.append(TextObservation(
                text: "L\(i)", confidence: 1.0,
                box: CGRect(x: 0.10, y: y, width: 0.36, height: 0.025),
                source: .vision
            ))
            obs.append(TextObservation(
                text: "R\(i)", confidence: 1.0,
                box: CGRect(x: 0.54, y: y, width: 0.36, height: 0.025),
                source: .vision
            ))
        }
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 612, height: 792),
            observations: obs,
            layoutRegions: [region]
        )
        let result = RegionAwareReflow.reflow(pageResults: [page])
        // Strip the page-anchor block emitted at the head of every page.
        let paras = result.blocks.compactMap { block -> [InlineRun]? in
            if case let .paragraph(runs) = block { return runs }
            return nil
        }
        XCTAssertEqual(paras.count, 2, "Expect one paragraph per column")
        let leftText = paras[0].map(\.text).joined()
        let rightText = paras[1].map(\.text).joined()
        XCTAssertTrue(leftText.contains("L0"))
        XCTAssertTrue(leftText.contains("L9"))
        XCTAssertFalse(leftText.contains("R0"),
            "Left column paragraph must not contain right column observations")
        XCTAssertTrue(rightText.contains("R0"))
        XCTAssertTrue(rightText.contains("R9"))
        XCTAssertFalse(rightText.contains("L0"),
            "Right column paragraph must not contain left column observations")
    }

    /// A narrow single-column `.text` region must not be split — the
    /// width gate (region.box.width > 0.6) should keep ColumnSplitter
    /// off legitimate per-column regions.
    func test_narrow_singleColumn_region_is_not_split() {
        let region = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.10, width: 0.36, height: 0.80),
            readingOrder: 0,
            confidence: 1.0
        )
        var obs: [TextObservation] = []
        for i in 0..<10 {
            obs.append(TextObservation(
                text: "L\(i)", confidence: 1.0,
                box: CGRect(x: 0.10, y: 0.85 - CGFloat(i) * 0.04,
                            width: 0.34, height: 0.025),
                source: .vision
            ))
        }
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 612, height: 792),
            observations: obs,
            layoutRegions: [region]
        )
        let result = RegionAwareReflow.reflow(pageResults: [page])
        let paras = result.blocks.compactMap { block -> [InlineRun]? in
            if case let .paragraph(runs) = block { return runs }
            return nil
        }
        XCTAssertEqual(paras.count, 1,
            "Narrow region should stay as one block")
    }
}
