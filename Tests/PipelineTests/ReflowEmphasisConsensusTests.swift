import XCTest
import CoreGraphics
import Document
import Layout
import OCR
@testable import Pipeline

/// Reflow propagates the observation-level italic / bold flags
/// (set by Tesseract when a whole line came back italic / bold)
/// into `InlineRun.isItalic` / `.isBold` only when **every**
/// observation in the paragraph or region agrees. This is the
/// strict-consensus semantic — avoids accidentally bolding/
/// italicizing a whole paragraph when one Tesseract word came
/// back styled (per-word font detection isn't perfect).
final class ReflowEmphasisConsensusTests: XCTestCase {

    // MARK: - ParagraphReflow

    func test_paragraph_inherits_italic_when_all_observations_italic() {
        let lines = [
            italicObs("Et nunc videns,", at: 0.85),
            italicObs("ergo cogito.", at: 0.81)
        ]
        let blocks = ParagraphReflow().reflow(lines)
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let runs) = blocks[0] else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(runs[0].isItalic)
        XCTAssertFalse(runs[0].isBold)
    }

    func test_paragraph_drops_italic_when_observations_disagree() {
        let lines = [
            italicObs("italic line", at: 0.85),
            plainObs("plain follow", at: 0.81)
        ]
        let blocks = ParagraphReflow().reflow(lines)
        guard case .paragraph(let runs) = blocks[0] else {
            return XCTFail("expected paragraph")
        }
        XCTAssertFalse(runs[0].isItalic)
    }

    func test_paragraph_inherits_bold_when_all_observations_bold() {
        let lines = [
            boldObs("STRONG WARNING", at: 0.85)
        ]
        let blocks = ParagraphReflow().reflow(lines)
        guard case .paragraph(let runs) = blocks[0] else {
            return XCTFail("expected paragraph")
        }
        XCTAssertTrue(runs[0].isBold)
    }

    func test_plain_observations_produce_plain_runs() {
        let lines = [
            plainObs("plain body line one", at: 0.85),
            plainObs("plain body line two", at: 0.81)
        ]
        let blocks = ParagraphReflow().reflow(lines)
        guard case .paragraph(let runs) = blocks[0] else {
            return XCTFail("expected paragraph")
        }
        XCTAssertFalse(runs[0].isItalic)
        XCTAssertFalse(runs[0].isBold)
    }

    // MARK: - Helpers

    private func plainObs(_ text: String, at midY: CGFloat) -> TextObservation {
        TextObservation(
            text: text,
            confidence: 1.0,
            box: CGRect(x: 0.10, y: midY - 0.01, width: 0.80, height: 0.02),
            source: .tesseract
        )
    }

    private func italicObs(_ text: String, at midY: CGFloat) -> TextObservation {
        TextObservation(
            text: text,
            confidence: 1.0,
            box: CGRect(x: 0.10, y: midY - 0.01, width: 0.80, height: 0.02),
            source: .tesseract,
            isItalic: true
        )
    }

    private func boldObs(_ text: String, at midY: CGFloat) -> TextObservation {
        TextObservation(
            text: text,
            confidence: 1.0,
            box: CGRect(x: 0.10, y: midY - 0.01, width: 0.80, height: 0.02),
            source: .tesseract,
            isBold: true
        )
    }
}
