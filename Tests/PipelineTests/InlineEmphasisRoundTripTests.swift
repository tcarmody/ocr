import XCTest
import Document
@testable import EPUB
@testable import Pipeline

/// Italic / bold preservation through the pipeline: Claude page-OCR
/// emits `<em>` / `<strong>`, the parser captures them as
/// `InlineRun.isItalic` / `.isBold`, and the EPUB / Markdown writers
/// re-emit them in their respective formats.
final class InlineEmphasisRoundTripTests: XCTestCase {

    // MARK: - Parser captures emphasis

    func test_em_tag_sets_isItalic_on_inner_run() {
        let xhtml = "<p>plain <em>italicized</em> after</p>"
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        let runs = paragraphRuns(in: result.blocks)
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].text, "plain ")
        XCTAssertFalse(runs[0].isItalic)
        XCTAssertEqual(runs[1].text, "italicized")
        XCTAssertTrue(runs[1].isItalic)
        XCTAssertFalse(runs[1].isBold)
        XCTAssertEqual(runs[2].text, " after")
        XCTAssertFalse(runs[2].isItalic)
    }

    func test_strong_tag_sets_isBold_on_inner_run() {
        let xhtml = "<p>plain <strong>bold</strong> after</p>"
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        let runs = paragraphRuns(in: result.blocks)
        XCTAssertEqual(runs.count, 3)
        XCTAssertTrue(runs[1].isBold)
        XCTAssertFalse(runs[1].isItalic)
    }

    func test_b_and_i_tags_aliased_to_strong_and_em() {
        let xhtml = "<p><b>bold</b> and <i>italic</i></p>"
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        let runs = paragraphRuns(in: result.blocks)
        XCTAssertTrue(runs.first { $0.text == "bold" }?.isBold ?? false)
        XCTAssertTrue(runs.first { $0.text == "italic" }?.isItalic ?? false)
    }

    func test_nested_em_inside_strong_is_both() {
        let xhtml = "<p><strong>bold <em>italic-too</em></strong></p>"
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        let runs = paragraphRuns(in: result.blocks)
        let inner = runs.first { $0.text == "italic-too" }
        XCTAssertNotNil(inner)
        XCTAssertTrue(inner?.isBold ?? false)
        XCTAssertTrue(inner?.isItalic ?? false)
    }

    // MARK: - XHTMLWriter emits emphasis

    func test_xhtmlWriter_wraps_italic_run_in_em() {
        let chapter = Chapter(
            title: nil,
            blocks: [
                .paragraph(runs: [
                    InlineRun("plain "),
                    InlineRun("italic", isItalic: true),
                    InlineRun(" after")
                ])
            ]
        )
        let writer = XHTMLWriter(cssPath: "../css/book.css")
        let xhtml = writer.render(
            chapter, defaultLanguage: .en, fallbackTitle: "x"
        )
        XCTAssertTrue(xhtml.contains("plain <em>italic</em> after"))
    }

    func test_xhtmlWriter_wraps_bold_run_in_strong() {
        let chapter = Chapter(
            title: nil,
            blocks: [
                .paragraph(runs: [
                    InlineRun("a "),
                    InlineRun("b", isBold: true),
                    InlineRun(" c")
                ])
            ]
        )
        let writer = XHTMLWriter(cssPath: "../css/book.css")
        let xhtml = writer.render(
            chapter, defaultLanguage: .en, fallbackTitle: "x"
        )
        XCTAssertTrue(xhtml.contains("a <strong>b</strong> c"))
    }

    func test_xhtmlWriter_nests_strong_outside_em_for_bold_italic() {
        let chapter = Chapter(
            title: nil,
            blocks: [
                .paragraph(runs: [
                    InlineRun("strong-italic", isItalic: true, isBold: true)
                ])
            ]
        )
        let writer = XHTMLWriter(cssPath: "../css/book.css")
        let xhtml = writer.render(
            chapter, defaultLanguage: .en, fallbackTitle: "x"
        )
        XCTAssertTrue(xhtml.contains("<strong><em>strong-italic</em></strong>"))
    }

    // MARK: - MarkdownWriter renders emphasis

    func test_markdownWriter_wraps_italic_in_asterisks() {
        let book = Book(
            title: "Test", language: .en,
            chapters: [
                Chapter(title: nil, blocks: [
                    .paragraph(runs: [
                        InlineRun("plain "),
                        InlineRun("italic", isItalic: true),
                        InlineRun(" after")
                    ])
                ])
            ]
        )
        let md = MarkdownWriter.render(book)
        XCTAssertTrue(md.contains("plain *italic* after"))
    }

    func test_markdownWriter_wraps_bold_in_double_asterisks() {
        let book = Book(
            title: "Test", language: .en,
            chapters: [
                Chapter(title: nil, blocks: [
                    .paragraph(runs: [InlineRun("x", isBold: true)])
                ])
            ]
        )
        let md = MarkdownWriter.render(book)
        XCTAssertTrue(md.contains("**x**"))
    }

    func test_markdownWriter_wraps_bold_italic_in_triple_asterisks() {
        let book = Book(
            title: "Test", language: .en,
            chapters: [
                Chapter(title: nil, blocks: [
                    .paragraph(runs: [
                        InlineRun("both", isItalic: true, isBold: true)
                    ])
                ])
            ]
        )
        let md = MarkdownWriter.render(book)
        XCTAssertTrue(md.contains("***both***"))
    }

    // MARK: - Helpers

    private func paragraphRuns(in blocks: [Block]) -> [InlineRun] {
        for block in blocks {
            if case .paragraph(let runs) = block { return runs }
        }
        return []
    }
}
