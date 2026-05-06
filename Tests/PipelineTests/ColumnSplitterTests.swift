import XCTest
import CoreGraphics
import OCR
@testable import Pipeline

final class ColumnSplitterTests: XCTestCase {

    func test_singleColumn_returnsOneGroup() {
        // 10 lines spanning the full body width — no gutter.
        let lines = (0..<10).map { i in
            obs("body line \(i)", at: CGRect(x: 0.10, y: 0.85 - CGFloat(i)*0.04, width: 0.80, height: 0.025))
        }
        let groups = ColumnSplitter().split(lines)
        XCTAssertEqual(groups.count, 1)
    }

    func test_twoColumn_splitsLeftRight() {
        // Two stacks of 8 lines each, with a clear gutter at x ≈ 0.5.
        var lines: [TextObservation] = []
        for i in 0..<8 {
            let y = 0.85 - CGFloat(i)*0.04
            lines.append(obs("L\(i)", at: CGRect(x: 0.10, y: y, width: 0.36, height: 0.025)))
            lines.append(obs("R\(i)", at: CGRect(x: 0.54, y: y, width: 0.36, height: 0.025)))
        }
        let groups = ColumnSplitter().split(lines)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].map(\.text), (0..<8).map { "L\($0)" })
        XCTAssertEqual(groups[1].map(\.text), (0..<8).map { "R\($0)" })
    }

    func test_falseGutter_fromCentralFigure_doesNotSplit() {
        // Single column of body text, but a tall figure region in the
        // middle that creates a wide x-band with no text. Both the
        // "left" and "right" sides won't span the page vertically →
        // splitter must refuse to split.
        var lines: [TextObservation] = []
        // Wide body lines at top
        for i in 0..<3 {
            lines.append(obs("top \(i)", at: CGRect(x: 0.10, y: 0.85 - CGFloat(i)*0.04, width: 0.80, height: 0.025)))
        }
        // Caption only on the left side, mid-page
        lines.append(obs("caption left", at: CGRect(x: 0.10, y: 0.50, width: 0.30, height: 0.025)))
        // Body lines at bottom
        for i in 0..<3 {
            lines.append(obs("bot \(i)", at: CGRect(x: 0.10, y: 0.20 - CGFloat(i)*0.04, width: 0.80, height: 0.025)))
        }
        let groups = ColumnSplitter().split(lines)
        XCTAssertEqual(groups.count, 1, "Figure-induced fake gutter should not split a single column")
    }

    func test_tooFewObservations_doesNotSplit() {
        let lines = (0..<5).map { i in
            obs("L\(i)", at: CGRect(x: 0.10, y: 0.85 - CGFloat(i)*0.04, width: 0.36, height: 0.025))
        }
        let groups = ColumnSplitter().split(lines)
        XCTAssertEqual(groups.count, 1)
    }

    func test_spanningHeader_aboveTwoColumns_emitsSpansFirst() {
        // Banner heading + epigraph at the top spanning both columns,
        // then an 8-deep stack in each column. Without span-aware
        // detection the header lights up the gutter histogram and the
        // splitter degrades to a single group.
        var lines: [TextObservation] = []
        // Two spanning observations at the top (full-width).
        lines.append(obs("INTRODUCTION",
            at: CGRect(x: 0.10, y: 0.93, width: 0.80, height: 0.04)))
        lines.append(obs("Subtitle banner",
            at: CGRect(x: 0.10, y: 0.88, width: 0.80, height: 0.025)))
        // 8 lines in each column below.
        for i in 0..<8 {
            let y = 0.80 - CGFloat(i)*0.04
            lines.append(obs("L\(i)", at: CGRect(x: 0.10, y: y, width: 0.36, height: 0.025)))
            lines.append(obs("R\(i)", at: CGRect(x: 0.54, y: y, width: 0.36, height: 0.025)))
        }
        let groups = ColumnSplitter().split(lines)
        XCTAssertEqual(groups.count, 3, "Expect [spans-above, left, right]")
        XCTAssertEqual(groups[0].map(\.text), ["INTRODUCTION", "Subtitle banner"])
        XCTAssertEqual(groups[1].map(\.text), (0..<8).map { "L\($0)" })
        XCTAssertEqual(groups[2].map(\.text), (0..<8).map { "R\($0)" })
    }

    func test_spanningFooter_belowTwoColumns_emitsSpansLast() {
        var lines: [TextObservation] = []
        // 8 lines in each column at the top.
        for i in 0..<8 {
            let y = 0.85 - CGFloat(i)*0.04
            lines.append(obs("L\(i)", at: CGRect(x: 0.10, y: y, width: 0.36, height: 0.025)))
            lines.append(obs("R\(i)", at: CGRect(x: 0.54, y: y, width: 0.36, height: 0.025)))
        }
        // A page-spanning footer sentence below the columns.
        lines.append(obs("Spanning footer",
            at: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.025)))
        let groups = ColumnSplitter().split(lines)
        XCTAssertEqual(groups.count, 3, "Expect [left, right, spans-below]")
        XCTAssertEqual(groups[0].map(\.text), (0..<8).map { "L\($0)" })
        XCTAssertEqual(groups[1].map(\.text), (0..<8).map { "R\($0)" })
        XCTAssertEqual(groups[2].map(\.text), ["Spanning footer"])
    }

    func test_singleColumn_withSpanningHeader_stillReturnsOneGroup() {
        // Banner heading above a single full-width column should NOT
        // be detected as 2-column. The candidate (non-span)
        // observations only paint one wide stripe, no gutter.
        var lines: [TextObservation] = []
        lines.append(obs("Banner",
            at: CGRect(x: 0.10, y: 0.93, width: 0.80, height: 0.04)))
        for i in 0..<10 {
            lines.append(obs("body \(i)",
                at: CGRect(x: 0.10, y: 0.85 - CGFloat(i)*0.04,
                          width: 0.80, height: 0.025)))
        }
        let groups = ColumnSplitter().split(lines)
        XCTAssertEqual(groups.count, 1, "Banner-over-single-column shouldn't split")
    }

    private func obs(_ text: String, at box: CGRect) -> TextObservation {
        TextObservation(text: text, confidence: 0.95, box: box)
    }
}
