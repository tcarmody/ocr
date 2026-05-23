import XCTest
import Document
@testable import Pipeline

/// Pins the markdown → `[Block]` translation in
/// `LandingAIPageOCREngine`. The end-to-end engine path uses
/// `LandingAIDocumentEngine` over a real HTTP transport — these
/// tests stick to the pure parser so the test suite stays offline.
final class LandingAIPageOCREngineTests: XCTestCase {

    // MARK: - ATX headings

    func test_parses_atx_headings() {
        let blocks = LandingAIPageOCREngine.parseMarkdown("""
            # Title

            ## Subhead

            Body paragraph.
            """)
        guard blocks.count == 3 else {
            return XCTFail("expected 3 blocks, got \(blocks.count)")
        }
        if case let .heading(level, runs) = blocks[0] {
            XCTAssertEqual(level, 1)
            XCTAssertEqual(runs.first?.text, "Title")
        } else { XCTFail("first block should be heading") }
        if case let .heading(level, runs) = blocks[1] {
            XCTAssertEqual(level, 2)
            XCTAssertEqual(runs.first?.text, "Subhead")
        } else { XCTFail("second block should be heading") }
        if case let .paragraph(runs) = blocks[2] {
            XCTAssertEqual(runs.first?.text, "Body paragraph.")
        } else { XCTFail("third block should be paragraph") }
    }

    // MARK: - Pipe tables

    func test_parses_pipe_table_with_header_and_body() {
        let blocks = LandingAIPageOCREngine.parseMarkdown("""
            Intro paragraph.

            | Author | Year |
            |---|---|
            | Foucault | 1971 |
            | Derrida | 1967 |

            Outro paragraph.
            """)
        guard blocks.count == 3 else {
            return XCTFail("expected 3 blocks, got \(blocks.count)")
        }
        guard case let .table(rows, _) = blocks[1] else {
            return XCTFail("middle block should be table")
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertTrue(rows[0][0].isHeader)
        XCTAssertEqual(rows[0][0].runs.first?.text, "Author")
        XCTAssertFalse(rows[1][0].isHeader)
        XCTAssertEqual(rows[1][0].runs.first?.text, "Foucault")
        XCTAssertEqual(rows[2][1].runs.first?.text, "1967")
    }

    func test_falls_back_to_paragraph_when_pipe_separator_missing() {
        // `| a | b |` without a `|---|---|` separator on the next
        // line is just paragraph prose that happens to contain
        // pipes (rare but possible in data citations). Don't
        // misinterpret as a table.
        let blocks = LandingAIPageOCREngine.parseMarkdown("""
            | a | b |
            | c | d |
            """)
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph = blocks[0] else {
            return XCTFail("expected paragraph fallback")
        }
    }

    // MARK: - Inline MathML pass-through

    func test_inline_math_block_is_captured_as_rawXHTML() {
        let mathML = #"<math display="block" xmlns="http://www.w3.org/1998/Math/MathML"><mrow><mi>E</mi><mo>=</mo><mi>m</mi><msup><mi>c</mi><mn>2</mn></msup></mrow></math>"#
        let blocks = LandingAIPageOCREngine.parseMarkdown("""
            See \(mathML) for the famous equation.
            """)
        XCTAssertEqual(blocks.count, 1)
        guard case let .paragraph(runs) = blocks[0] else {
            return XCTFail("expected paragraph")
        }
        // Expect at least one run with the raw MathML attached;
        // surrounding prose stays in separate runs.
        let mathRun = runs.first { $0.rawXHTML != nil }
        XCTAssertNotNil(mathRun)
        XCTAssertEqual(mathRun?.rawXHTML, mathML)
        // Plain-text fallback should be the textual content of the
        // math element with tags stripped (for sibling .txt / .md
        // outputs that can't render MathML).
        XCTAssertTrue(
            mathRun?.text.contains("E") == true,
            "expected text fallback to contain math content, got '\(mathRun?.text ?? "")'"
        )
    }

    func test_unclosed_math_open_tag_treated_as_literal_text() {
        // Defensive: a `<math` open without a matching `</math>`
        // doesn't strand a half-captured rawXHTML run.
        let blocks = LandingAIPageOCREngine.parseMarkdown("Some <math broken text.")
        XCTAssertEqual(blocks.count, 1)
        if case let .paragraph(runs) = blocks[0] {
            XCTAssertTrue(runs.allSatisfy { $0.rawXHTML == nil })
        } else { XCTFail("expected paragraph") }
    }

    // MARK: - Emphasis

    func test_parses_bold_and_italic_in_paragraph() {
        let blocks = LandingAIPageOCREngine.parseMarkdown("""
            A line with **bold** and *italic* words.
            """)
        XCTAssertEqual(blocks.count, 1)
        guard case let .paragraph(runs) = blocks[0] else {
            return XCTFail("expected paragraph")
        }
        XCTAssertTrue(runs.contains { $0.isBold && $0.text == "bold" })
        XCTAssertTrue(runs.contains { $0.isItalic && $0.text == "italic" })
    }

    // MARK: - Markdown image syntax

    func test_strips_markdown_image_syntax() {
        // ADE references figures via markdown image syntax; the
        // pipeline gets figures from Surya separately, so we drop
        // these placeholders to avoid emitting broken `<img>` runs.
        let blocks = LandingAIPageOCREngine.parseMarkdown("""
            Caption here ![Figure 1](fig-1.png) more caption.
            """)
        XCTAssertEqual(blocks.count, 1)
        guard case let .paragraph(runs) = blocks[0] else {
            return XCTFail("expected paragraph")
        }
        let joined = runs.map(\.text).joined()
        XCTAssertFalse(joined.contains("!["))
        XCTAssertFalse(joined.contains("]("))
        XCTAssertTrue(joined.contains("Caption here"))
        XCTAssertTrue(joined.contains("more caption"))
    }

    // MARK: - Empty / whitespace input

    func test_empty_input_returns_no_blocks() {
        XCTAssertEqual(LandingAIPageOCREngine.parseMarkdown("").count, 0)
        XCTAssertEqual(LandingAIPageOCREngine.parseMarkdown("\n\n\n").count, 0)
    }
}
