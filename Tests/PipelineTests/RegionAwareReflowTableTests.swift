import XCTest
import CoreGraphics
import Document
import Layout
import OCR
@testable import Pipeline

/// Tests the `.table` emission path through `RegionAwareReflow`.
/// The heuristic produces grid rows, the reflow wraps them in a
/// `Block.table`, and the table's observations get marked claimed
/// so the body path doesn't double-emit them.
final class RegionAwareReflowTableTests: XCTestCase {

    private func region(_ kind: LayoutRegion.Kind, _ box: CGRect, _ ord: Int) -> LayoutRegion {
        LayoutRegion(kind: kind, box: box, readingOrder: ord, confidence: 1.0)
    }

    private func obs(_ text: String, x: CGFloat, y: CGFloat,
                     w: CGFloat = 0.10, h: CGFloat = 0.02) -> TextObservation {
        TextObservation(
            text: text, confidence: 1.0,
            box: CGRect(x: x, y: y, width: w, height: h),
            source: .vision
        )
    }

    func test_table_region_with_grid_emits_block_table() {
        let tableBox = CGRect(x: 0.05, y: 0.30, width: 0.90, height: 0.40)
        let regions = [region(.table, tableBox, 0)]
        let observations = [
            obs("Author",   x: 0.10, y: 0.65),
            obs("Year",     x: 0.50, y: 0.65),
            obs("Foucault", x: 0.10, y: 0.55),
            obs("1971",     x: 0.50, y: 0.55),
            obs("Weber",    x: 0.10, y: 0.45),
            obs("1922",     x: 0.50, y: 0.45),
        ]
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 800, height: 1000),
            observations: observations,
            layoutRegions: regions
        )
        let result = RegionAwareReflow.reflow(pageResults: [page])
        let nonAnchorBlocks = result.blocks.filter {
            if case .anchor = $0 { return false } else { return true }
        }
        XCTAssertEqual(nonAnchorBlocks.count, 1,
                       "Single .table region should yield exactly one block")
        guard case let .table(rows, caption) = nonAnchorBlocks[0] else {
            XCTFail("Expected .table block, got \(nonAnchorBlocks[0])"); return
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.count), [2, 2, 2])
        XCTAssertEqual(rows[0][0].runs.map(\.text).joined(), "Author")
        XCTAssertEqual(rows[2][1].runs.map(\.text).joined(), "1922")
        XCTAssertTrue(caption.isEmpty)
    }

    func test_table_with_caption_below_absorbs_caption() {
        // Table at top, caption directly below it.
        let tableBox = CGRect(x: 0.05, y: 0.40, width: 0.90, height: 0.40)
        let captionBox = CGRect(x: 0.05, y: 0.32, width: 0.90, height: 0.05)
        let regions = [
            region(.table, tableBox, 0),
            region(.caption, captionBox, 1),
        ]
        let observations = [
            // Table cells (must fall inside tableBox: y in 0.40..0.80)
            obs("A", x: 0.10, y: 0.75),
            obs("B", x: 0.50, y: 0.75),
            obs("1", x: 0.10, y: 0.65),
            obs("2", x: 0.50, y: 0.65),
            // Caption text (inside captionBox: y in 0.32..0.37)
            obs("Table 1: Sample.", x: 0.10, y: 0.34, w: 0.5, h: 0.03),
        ]
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 800, height: 1000),
            observations: observations,
            layoutRegions: regions
        )
        let associations = CaptionAssociator.associate(regionsByPage: [0: regions])
        XCTAssertEqual(associations.captionByFigure.count, 1,
                       "Sanity: caption should pair with the table")

        let result = RegionAwareReflow.reflow(
            pageResults: [page],
            captionAssociations: associations
        )
        let nonAnchorBlocks = result.blocks.filter {
            if case .anchor = $0 { return false } else { return true }
        }
        XCTAssertEqual(nonAnchorBlocks.count, 1,
                       "Caption should be absorbed into the table block")
        guard case let .table(_, caption) = nonAnchorBlocks[0] else {
            XCTFail("Expected .table block"); return
        }
        XCTAssertEqual(caption.map(\.text).joined(), "Table 1: Sample.")
    }

    func test_table_observations_are_not_double_emitted_as_paragraph() {
        // A body region also overlaps the table area to verify the
        // first-claimant logic protects the cells.
        let tableBox = CGRect(x: 0.05, y: 0.30, width: 0.90, height: 0.40)
        let regions = [region(.table, tableBox, 0)]
        let observations = [
            obs("X", x: 0.10, y: 0.65),
            obs("Y", x: 0.50, y: 0.65),
            obs("1", x: 0.10, y: 0.55),
            obs("2", x: 0.50, y: 0.55),
        ]
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 800, height: 1000),
            observations: observations,
            layoutRegions: regions
        )
        let result = RegionAwareReflow.reflow(pageResults: [page])
        // No paragraph blocks should appear — the cells live only
        // inside the table block.
        let paragraphBlocks = result.blocks.filter {
            if case .paragraph = $0 { return true } else { return false }
        }
        XCTAssertTrue(paragraphBlocks.isEmpty,
                      "Table cells should not also emit as a paragraph")
    }

    // MARK: - Path A priority

    /// When a Surya-derived row set is supplied for a `.table`
    /// region, reflow uses it verbatim — including any header flags
    /// and merged-cell spans the heuristic could never produce —
    /// instead of running the heuristic.
    func test_surya_table_extraction_takes_priority_over_heuristic() {
        let tableBox = CGRect(x: 0.05, y: 0.30, width: 0.90, height: 0.40)
        let regions = [region(.table, tableBox, 0)]
        // The same cells the heuristic would also detect — but we'll
        // confirm Surya's structure (with isHeader + colspan) wins.
        let observations = [
            obs("Author",   x: 0.10, y: 0.65),
            obs("Year",     x: 0.50, y: 0.65),
            obs("Foucault", x: 0.10, y: 0.55),
            obs("1971",     x: 0.50, y: 0.55),
        ]
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 800, height: 1000),
            observations: observations,
            layoutRegions: regions
        )
        // Pre-cooked Path A output: header row + a merged-spanning cell.
        let suryaRows: [[TableCell]] = [
            [
                TableCell(runs: [InlineRun("Author")], isHeader: true),
                TableCell(runs: [InlineRun("Year")], isHeader: true),
            ],
            [
                TableCell(runs: [InlineRun("Foucault")], colspan: 2),
            ],
        ]
        let key = CaptionAssociator.PageRegionKey(pageIndex: 0, regionIndex: 0)
        let result = RegionAwareReflow.reflow(
            pageResults: [page],
            tableExtractions: [key: suryaRows]
        )
        let nonAnchorBlocks = result.blocks.filter {
            if case .anchor = $0 { return false } else { return true }
        }
        XCTAssertEqual(nonAnchorBlocks.count, 1)
        guard case let .table(rows, _) = nonAnchorBlocks[0] else {
            XCTFail("Expected .table"); return
        }
        // Surya rows used verbatim — heuristic would have produced
        // a different shape (no isHeader, no colspan).
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0][0].isHeader)
        XCTAssertTrue(rows[0][1].isHeader)
        XCTAssertEqual(rows[1].count, 1)
        XCTAssertEqual(rows[1][0].colspan, 2)
    }

    /// When `tableExtractions` doesn't include this region (e.g.
    /// sidecar wasn't available), reflow still falls through to the
    /// heuristic. Belt-and-braces test of the fallback path.
    func test_no_surya_extraction_still_uses_heuristic() {
        let tableBox = CGRect(x: 0.05, y: 0.30, width: 0.90, height: 0.40)
        let regions = [region(.table, tableBox, 0)]
        let observations = [
            obs("A", x: 0.10, y: 0.65),
            obs("B", x: 0.50, y: 0.65),
            obs("1", x: 0.10, y: 0.55),
            obs("2", x: 0.50, y: 0.55),
        ]
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 800, height: 1000),
            observations: observations,
            layoutRegions: regions
        )
        let result = RegionAwareReflow.reflow(
            pageResults: [page],
            tableExtractions: [:]  // no Surya output
        )
        let tableBlocks = result.blocks.filter {
            if case .table = $0 { return true } else { return false }
        }
        XCTAssertEqual(tableBlocks.count, 1,
                       "Heuristic should still fire when Surya output absent")
    }

    func test_degenerate_table_falls_back_to_paragraph() {
        // Only 2 observations on the same row — heuristic rejects.
        // The region should fall through to paragraph emission so
        // the user doesn't lose the text.
        let tableBox = CGRect(x: 0.05, y: 0.50, width: 0.90, height: 0.10)
        let regions = [region(.table, tableBox, 0)]
        let observations = [
            obs("A", x: 0.10, y: 0.55),
            obs("B", x: 0.50, y: 0.55),
        ]
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 800, height: 1000),
            observations: observations,
            layoutRegions: regions
        )
        let result = RegionAwareReflow.reflow(pageResults: [page])
        // Paragraph block emitted, no table block.
        let kinds: [String] = result.blocks.compactMap {
            switch $0 {
            case .anchor:    return nil
            case .heading:   return "h"
            case .paragraph: return "p"
            case .figure:    return "f"
            case .table:     return "t"
            case .verse:     return "v"
            }
        }
        XCTAssertFalse(kinds.contains("t"),
                       "Degenerate grid should not emit Block.table")
        XCTAssertTrue(kinds.contains("p"),
                      "Fallback should emit at least a paragraph")
    }
}
