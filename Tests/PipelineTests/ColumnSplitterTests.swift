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

    private func obs(_ text: String, at box: CGRect) -> TextObservation {
        TextObservation(text: text, confidence: 0.95, box: box)
    }
}
