import XCTest
import CoreGraphics
import Document
import OCR
@testable import Pipeline

final class ParagraphReflowTests: XCTestCase {

    func test_consecutive_lines_at_normal_spacing_form_one_paragraph() {
        let lines = stack(
            startY: 0.85,
            lineHeight: 0.025,
            lineGap: 0.005,
            ["The first line of the paragraph",
             "continues onto a second line",
             "and then a third."]
        )
        let blocks = ParagraphReflow().reflow(lines)
        XCTAssertEqual(blocks.count, 1)
        let text = paragraphText(blocks[0])
        XCTAssertEqual(text, "The first line of the paragraph continues onto a second line and then a third.")
    }

    func test_large_vertical_gap_starts_new_paragraph() {
        var lines = stack(
            startY: 0.85, lineHeight: 0.025, lineGap: 0.005,
            ["First paragraph line one.", "First paragraph line two."]
        )
        // Big gap — equivalent to ~3 line heights — then second paragraph.
        let secondStart = 0.85 - 0.025*2 - 0.005 - 0.10
        lines.append(contentsOf: stack(
            startY: secondStart, lineHeight: 0.025, lineGap: 0.005,
            ["Second paragraph line."]
        ))
        let blocks = ParagraphReflow().reflow(lines)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(paragraphText(blocks[0]), "First paragraph line one. First paragraph line two.")
        XCTAssertEqual(paragraphText(blocks[1]), "Second paragraph line.")
    }

    func test_indent_starts_new_paragraph() {
        // Two lines flush left, then an indented line at the next normal
        // vertical slot → new paragraph (first-line indent style).
        var lines = stack(
            startY: 0.85, lineHeight: 0.025, lineGap: 0.005,
            ["Body left margin line one.", "Body left margin line two."]
        )
        // Bottom of nth line: startY - n*lineHeight - (n-1)*lineGap.
        let indentY = 0.85 - 3*0.025 - 2*0.005
        lines.append(TextObservation(
            text: "Indented start of next paragraph.",
            confidence: 0.95,
            box: CGRect(x: 0.15, y: indentY, width: 0.6, height: 0.025)
        ))
        let blocks = ParagraphReflow().reflow(lines)
        XCTAssertEqual(blocks.count, 2)
    }

    func test_soft_hyphen_dehyphenates_within_paragraph() {
        let lines = stack(
            startY: 0.85, lineHeight: 0.025, lineGap: 0.005,
            ["the encounter of the German philosophical movement with the new development of Jew-",
             "ish culture does not date from this moment."]
        )
        let blocks = ParagraphReflow().reflow(lines)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(paragraphText(blocks[0]).contains("Jewish"),
                      "Expected dehyphenated 'Jewish'; got: \(paragraphText(blocks[0]))")
    }

    func test_empty_input_returns_no_blocks() {
        XCTAssertEqual(ParagraphReflow().reflow([]).count, 0)
    }

    func test_listMarkerLine_starts_new_paragraph_at_normal_spacing() {
        // "...attention for" then "1. To this same question..." — at
        // normal line spacing the geometry would join them. The list
        // marker on the second line must force a paragraph break.
        let lines = stack(
            startY: 0.85, lineHeight: 0.025, lineGap: 0.005,
            ["the argument merits attention for",
             "1. To this same question Mendelssohn replied."]
        )
        let blocks = ParagraphReflow().reflow(lines)
        XCTAssertEqual(blocks.count, 2,
                       "List-marker line should open a new paragraph even at normal line spacing")
        XCTAssertEqual(paragraphText(blocks[1]),
                       "1. To this same question Mendelssohn replied.")
    }

    func test_startsWithListMarker_recognizes_common_forms() {
        XCTAssertTrue(ParagraphReflow.startsWithListMarker("1. Foo"))
        XCTAssertTrue(ParagraphReflow.startsWithListMarker("12. Foo"))
        XCTAssertTrue(ParagraphReflow.startsWithListMarker("1) Foo"))
        XCTAssertTrue(ParagraphReflow.startsWithListMarker("  3. Bar"))
        XCTAssertFalse(ParagraphReflow.startsWithListMarker("1.5 km"))
        XCTAssertFalse(ParagraphReflow.startsWithListMarker("1789 was"))
        XCTAssertFalse(ParagraphReflow.startsWithListMarker("Foo bar"))
        XCTAssertFalse(ParagraphReflow.startsWithListMarker("1."))  // no space after
    }

    // MARK: cross-page bridging

    func test_bridgeBoundaries_merges_split_word_across_paragraphs() {
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun("the encounter of Men-")]),
            .paragraph(runs: [InlineRun("delssohn at the crossroads.")]),
        ]
        let merged = PDFToEPUBPipeline.bridgeBoundaries(blocks)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(paragraphText(merged[0]),
                       "the encounter of Mendelssohn at the crossroads.")
    }

    func test_bridgeBoundaries_leaves_unhyphenated_paragraphs_alone() {
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun("End of paragraph one.")]),
            .paragraph(runs: [InlineRun("Start of paragraph two.")]),
        ]
        let merged = PDFToEPUBPipeline.bridgeBoundaries(blocks)
        XCTAssertEqual(merged.count, 2)
    }

    // MARK: mid-sentence column/page bridge

    func test_bridgeBoundaries_merges_midSentence_when_prev_lacks_terminator_and_next_starts_lowercase() {
        // Column-boundary case from the Foucault PDF: prev paragraph ends
        // with "consequences that" (no terminator), next starts with
        // "may ensue." (lowercase) → should merge into one paragraph.
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun(
                "Thus, the interlocutors recognize that they belong to one of " +
                "those revolutions of the world in which the world is turning " +
                "backward, with all the negative consequences that"
            )]),
            .paragraph(runs: [InlineRun("may ensue. The present may be interrogated.")]),
        ]
        let merged = PDFToEPUBPipeline.bridgeBoundaries(blocks)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(paragraphText(merged[0]).contains("consequences that may ensue"),
                      "Cross-boundary mid-sentence merge should produce continuous prose")
    }

    func test_bridgeBoundaries_does_not_merge_when_next_starts_uppercase() {
        // Heading or new paragraph following a label-style line — keep separate.
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun("Section heading without trailing period")]),
            .paragraph(runs: [InlineRun("New paragraph after the heading begins here.")]),
        ]
        let merged = PDFToEPUBPipeline.bridgeBoundaries(blocks)
        XCTAssertEqual(merged.count, 2)
    }

    func test_bridgeBoundaries_merges_numeric_start_paragraphs_at_boundaries() {
        // A legitimate body paragraph starting with a digit (a year, a
        // numbered point) that was split mid-sentence across a column
        // boundary should bridge normally. The H/F classifier handles
        // running heads upstream — bridging stays geometry/grammar based.
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun(
                "1789 was a momentous year for the philosophy of revolution and"
            )]),
            .paragraph(runs: [InlineRun("subsequent reflection on what enlightenment requires.")]),
        ]
        let merged = PDFToEPUBPipeline.bridgeBoundaries(blocks)
        XCTAssertEqual(merged.count, 1,
                       "Body paragraphs starting with a digit must still bridge across boundaries")
    }

    func test_bridgeBoundaries_does_not_merge_short_prev_paragraphs() {
        // Short label / heading shouldn't get sucked into the next paragraph,
        // even when next starts lowercase. Length guard is the safety net.
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun("note")]),
            .paragraph(runs: [InlineRun("the whole next paragraph starts in lowercase.")]),
        ]
        let merged = PDFToEPUBPipeline.bridgeBoundaries(blocks)
        XCTAssertEqual(merged.count, 2)
    }

    // MARK: helpers

    /// Build a vertical stack of single-line observations (each occupying
    /// the full body width). Origin is bottom-left per Vision convention.
    private func stack(
        startY: CGFloat, lineHeight: CGFloat, lineGap: CGFloat, _ texts: [String]
    ) -> [TextObservation] {
        var out: [TextObservation] = []
        var topY = startY
        for text in texts {
            let bottomY = topY - lineHeight
            out.append(TextObservation(
                text: text,
                confidence: 0.95,
                box: CGRect(x: 0.10, y: bottomY, width: 0.80, height: lineHeight)
            ))
            topY = bottomY - lineGap
        }
        return out
    }

    private func paragraphText(_ block: Block) -> String {
        guard case let .paragraph(runs) = block else {
            XCTFail("Expected paragraph"); return ""
        }
        return runs.map(\.text).joined()
    }
}
