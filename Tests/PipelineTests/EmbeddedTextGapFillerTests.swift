import XCTest
import CoreGraphics
import OCR
import PDFIngest
@testable import Pipeline

final class EmbeddedTextGapFillerTests: XCTestCase {

    func test_fillsGap_whenVisionMissesALineEntirely() {
        // Three embedded lines stacked vertically. Vision returned only
        // the top and bottom — the middle line is the gap.
        let visionObs = [
            obs("It merits attention for", at: CGRect(x: 0.13, y: 0.725, width: 0.33, height: 0.020), source: .vision),
            obs("1. To this same question",  at: CGRect(x: 0.14, y: 0.692, width: 0.32, height: 0.020), source: .vision),
        ]
        let embedded = [
            line("It merits attention for",  at: CGRect(x: 0.13, y: 0.725, width: 0.33, height: 0.020)),
            line("several reasons.",         at: CGRect(x: 0.13, y: 0.708, width: 0.10, height: 0.020)),
            line("1. To this same question",  at: CGRect(x: 0.14, y: 0.692, width: 0.32, height: 0.020)),
        ]
        let merged = EmbeddedTextGapFiller().fill(
            visionObservations: visionObs,
            embeddedLines: embedded
        )
        XCTAssertEqual(merged.count, 3, "Should add the missing middle line")
        let added = merged.first { $0.source == .embedded }
        XCTAssertNotNil(added)
        XCTAssertEqual(added?.text, "several reasons.")
    }

    func test_doesNotDuplicate_whenVisionAlreadyCoversALine() {
        let visionObs = [
            obs("Vision text for line one", at: CGRect(x: 0.10, y: 0.80, width: 0.50, height: 0.020), source: .vision),
        ]
        let embedded = [
            // Embedded line at the same y position with similar bounds —
            // even though text content differs, vertical overlap means
            // we trust Vision and don't duplicate.
            line("Embedded layer says different", at: CGRect(x: 0.10, y: 0.80, width: 0.50, height: 0.020)),
        ]
        let merged = EmbeddedTextGapFiller().fill(
            visionObservations: visionObs,
            embeddedLines: embedded
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "Vision text for line one")
        XCTAssertEqual(merged[0].source, .vision)
    }

    func test_fillsGap_evenWhenVisionHasObservationsAtOtherYPositions() {
        // Vision has lines at y=0.80 and y=0.60, missing one in between
        // at y=0.70 — that gap should be filled.
        let visionObs = [
            obs("Top line from Vision",    at: CGRect(x: 0.10, y: 0.80, width: 0.40, height: 0.020), source: .vision),
            obs("Bottom line from Vision", at: CGRect(x: 0.10, y: 0.60, width: 0.40, height: 0.020), source: .vision),
        ]
        let embedded = [
            line("Top line from Vision",        at: CGRect(x: 0.10, y: 0.80, width: 0.40, height: 0.020)),
            line("Middle line Vision missed",   at: CGRect(x: 0.10, y: 0.70, width: 0.40, height: 0.020)),
            line("Bottom line from Vision",     at: CGRect(x: 0.10, y: 0.60, width: 0.40, height: 0.020)),
        ]
        let merged = EmbeddedTextGapFiller().fill(
            visionObservations: visionObs,
            embeddedLines: embedded
        )
        XCTAssertEqual(merged.count, 3)
        let embeddedAdds = merged.filter { $0.source == .embedded }
        XCTAssertEqual(embeddedAdds.count, 1)
        XCTAssertEqual(embeddedAdds[0].text, "Middle line Vision missed")
    }

    func test_emptyEmbedded_returnsVisionUnchanged() {
        let visionObs = [
            obs("Vision text", at: CGRect(x: 0.10, y: 0.80, width: 0.40, height: 0.020), source: .vision),
        ]
        let merged = EmbeddedTextGapFiller().fill(
            visionObservations: visionObs,
            embeddedLines: []
        )
        XCTAssertEqual(merged, visionObs)
    }

    func test_emptyVision_returnsAllEmbeddedAsSynthetic() {
        // Vision returned nothing for the page — fall back to embedded
        // entirely, all marked .embedded.
        let embedded = [
            line("first embedded line",  at: CGRect(x: 0.10, y: 0.80, width: 0.40, height: 0.020)),
            line("second embedded line", at: CGRect(x: 0.10, y: 0.75, width: 0.40, height: 0.020)),
        ]
        let merged = EmbeddedTextGapFiller().fill(
            visionObservations: [],
            embeddedLines: embedded
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.allSatisfy { $0.source == .embedded })
    }

    // MARK: helpers

    private func obs(_ text: String, at box: CGRect, source: ObservationSource) -> TextObservation {
        TextObservation(text: text, confidence: 0.95, box: box, source: source)
    }

    private func line(_ text: String, at box: CGRect) -> EmbeddedTextExtractor.Line {
        EmbeddedTextExtractor.Line(text: text, box: box)
    }
}
