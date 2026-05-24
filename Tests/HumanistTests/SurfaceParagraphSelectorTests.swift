import XCTest
@testable import Humanist

/// Pins the "worth re-reading" scoring rubric. Touches the
/// boundaries (short, long, heading-prefix, low-TTR) so a
/// future tweak to one filter doesn't silently knock out another.
final class SurfaceParagraphSelectorTests: XCTestCase {

    func test_short_paragraph_scores_zero() {
        XCTAssertEqual(
            SurfaceParagraphSelector.score("Just a tiny fragment."),
            0
        )
    }

    func test_wall_of_text_paragraph_scores_zero() {
        // ~1800 chars of substantive prose exceeds the upper bound;
        // the rubric prefers quote-shaped passages under 1500.
        let unit = "The history of the present is a discipline shaped by the archive. "
        let text = String(repeating: unit, count: 28)
        XCTAssertGreaterThan(text.count, 1500)
        XCTAssertEqual(SurfaceParagraphSelector.score(text), 0)
    }

    func test_heading_like_paragraph_scores_zero() {
        let heading = """
        Chapter 3 — The Politics of Truth. This chapter takes up \
        what Foucault calls the will to truth, tracing it through \
        a sequence of historical formations.
        """
        XCTAssertEqual(SurfaceParagraphSelector.score(heading), 0)
    }

    func test_single_sentence_paragraph_scores_zero() {
        // ~300 chars, one period — fails the "≥ 2 sentences" filter.
        let single = String(
            repeating: "a substantive single-sentence passage continues ",
            count: 7
        ) + "with a final clause"
        XCTAssertTrue(single.count >= 200)
        XCTAssertEqual(SurfaceParagraphSelector.score(single), 0)
    }

    func test_low_ttr_repetition_scores_zero() {
        // Highly repetitive text — TTR drops well under 0.4 and
        // the selector treats this as filler / OCR garbage.
        let repetitive = String(
            repeating: "the cat and the dog and the cat and the dog. ",
            count: 20
        )
        XCTAssertEqual(SurfaceParagraphSelector.score(repetitive), 0)
    }

    func test_well_shaped_paragraph_scores_positive() {
        let good = """
        The mirror stage manifests an affective dynamism by which \
        the subject anticipates in a mirage the maturation of his \
        power. Such is the captation specific to this stage, the \
        meaning of the imaginary function of the imago, namely the \
        establishment of a relationship between an organism and its \
        reality, or between the Innenwelt and the Umwelt. This is \
        the gesture that founds the visible world as one of seen \
        objects, and the seer's relation to those objects.
        """
        let s = SurfaceParagraphSelector.score(good)
        XCTAssertGreaterThan(s, 0, "expected a quote-shaped paragraph to pass")
    }
}
