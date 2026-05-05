import XCTest
import CoreGraphics
import Document
import OCR
@testable import Pipeline

/// Tests `TableHeuristic.extract` — Y-clustering into rows then
/// left-to-right ordering into cells. Quality bar is 60-70% accuracy
/// on a first-pass scan, so these cover the simple regular-grid
/// case + a couple of edge cases.
final class TableHeuristicTests: XCTestCase {

    /// Fabricate an observation. Page coords y=0 bottom, y=1 top.
    private func obs(_ text: String, x: CGFloat, y: CGFloat,
                     w: CGFloat = 0.10, h: CGFloat = 0.02) -> TextObservation {
        TextObservation(
            text: text, confidence: 1.0,
            box: CGRect(x: x, y: y, width: w, height: h),
            source: .vision
        )
    }

    // MARK: - regular grid

    func test_three_by_two_regular_grid_yields_three_rows_two_cols() {
        // Row 0 (top): "Author", "Year"
        // Row 1: "Foucault", "1971"
        // Row 2: "Weber", "1922"
        let observations = [
            obs("Author",   x: 0.10, y: 0.80),
            obs("Year",     x: 0.50, y: 0.80),
            obs("Foucault", x: 0.10, y: 0.70),
            obs("1971",     x: 0.50, y: 0.70),
            obs("Weber",    x: 0.10, y: 0.60),
            obs("1922",     x: 0.50, y: 0.60),
        ]
        guard let rows = TableHeuristic.extract(observations: observations) else {
            XCTFail("Expected the heuristic to produce rows"); return
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.count), [2, 2, 2])
        // Top-to-bottom row order with left-to-right cells.
        XCTAssertEqual(rows[0][0].runs.map(\.text).joined(), "Author")
        XCTAssertEqual(rows[0][1].runs.map(\.text).joined(), "Year")
        XCTAssertEqual(rows[1][0].runs.map(\.text).joined(), "Foucault")
        XCTAssertEqual(rows[1][1].runs.map(\.text).joined(), "1971")
        XCTAssertEqual(rows[2][0].runs.map(\.text).joined(), "Weber")
        XCTAssertEqual(rows[2][1].runs.map(\.text).joined(), "1922")
    }

    func test_heuristic_emits_all_data_cells_no_header_flag() {
        let observations = [
            obs("Col A", x: 0.10, y: 0.80),
            obs("Col B", x: 0.50, y: 0.80),
            obs("a",     x: 0.10, y: 0.70),
            obs("b",     x: 0.50, y: 0.70),
        ]
        guard let rows = TableHeuristic.extract(observations: observations) else {
            XCTFail("Expected rows"); return
        }
        // Heuristic doesn't auto-detect headers — Path A (Surya
        // table model) is the path that sets isHeader correctly.
        for row in rows {
            for cell in row {
                XCTAssertFalse(cell.isHeader,
                               "Heuristic should leave isHeader=false")
                XCTAssertEqual(cell.rowspan, 1)
                XCTAssertEqual(cell.colspan, 1)
            }
        }
    }

    // MARK: - rejection cases

    func test_too_few_observations_returns_nil() {
        // 3 obs is below the minRows × minCols floor of 2 × 2 = 4.
        let observations = [
            obs("A", x: 0.10, y: 0.80),
            obs("B", x: 0.50, y: 0.80),
            obs("C", x: 0.10, y: 0.70),
        ]
        XCTAssertNil(TableHeuristic.extract(observations: observations))
    }

    func test_single_row_returns_nil() {
        // 4 obs but all on one line — fails the 2-row floor.
        let observations = [
            obs("A", x: 0.10, y: 0.80),
            obs("B", x: 0.30, y: 0.80),
            obs("C", x: 0.50, y: 0.80),
            obs("D", x: 0.70, y: 0.80),
        ]
        XCTAssertNil(TableHeuristic.extract(observations: observations))
    }

    func test_single_column_returns_nil() {
        // 4 obs on 4 separate rows but only one column — fails the
        // 2-col floor.
        let observations = [
            obs("A", x: 0.10, y: 0.80),
            obs("B", x: 0.10, y: 0.70),
            obs("C", x: 0.10, y: 0.60),
            obs("D", x: 0.10, y: 0.50),
        ]
        XCTAssertNil(TableHeuristic.extract(observations: observations))
    }

    // MARK: - irregular rows

    func test_row_with_missing_cell_emits_short_row() {
        // Row 0: A, B, C   Row 1: D (only),   Row 2: E, F, G
        let observations = [
            obs("A", x: 0.10, y: 0.80),
            obs("B", x: 0.40, y: 0.80),
            obs("C", x: 0.70, y: 0.80),
            obs("D", x: 0.10, y: 0.70),
            obs("E", x: 0.10, y: 0.60),
            obs("F", x: 0.40, y: 0.60),
            obs("G", x: 0.70, y: 0.60),
        ]
        guard let rows = TableHeuristic.extract(observations: observations) else {
            XCTFail("Expected rows"); return
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].count, 3)
        XCTAssertEqual(rows[1].count, 1, "Missing-cell rows are shorter")
        XCTAssertEqual(rows[2].count, 3)
    }
}
