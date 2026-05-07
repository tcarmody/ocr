import XCTest
import Document
@testable import EPUB

/// `PlainTextWriter` produces a flat UTF-8 representation of a
/// `Book` — useful for piping into search / archival pipelines
/// without unzipping the EPUB.
final class PlainTextWriterTests: XCTestCase {

    func test_renders_title_and_author() {
        let book = Book(
            title: "Origins",
            author: "A. Author",
            language: .en,
            chapters: []
        )
        let out = PlainTextWriter.render(book)
        XCTAssertTrue(out.hasPrefix("Origins\nby A. Author\n"),
            "title + author should head the document")
    }

    func test_omits_author_line_when_nil() {
        let book = Book(title: "Anon", chapters: [])
        let out = PlainTextWriter.render(book)
        XCTAssertTrue(out.hasPrefix("Anon\n"))
        XCTAssertFalse(out.contains("by "),
            "missing author should produce no `by` line")
    }

    func test_renders_chapter_with_body_paragraphs() {
        let book = Book(
            title: "Test",
            chapters: [
                Chapter(title: "Chapter 1", blocks: [
                    .paragraph(runs: [InlineRun("First paragraph.")]),
                    .paragraph(runs: [InlineRun("Second paragraph.")]),
                ]),
            ]
        )
        let out = PlainTextWriter.render(book)
        XCTAssertTrue(out.contains("Chapter 1"))
        XCTAssertTrue(out.contains("First paragraph."))
        XCTAssertTrue(out.contains("Second paragraph."))
    }

    func test_renders_chapter_title_underlined() {
        let book = Book(
            title: "X",
            chapters: [Chapter(title: "Hello", blocks: [
                .paragraph(runs: [InlineRun("Body.")]),
            ])]
        )
        let out = PlainTextWriter.render(book)
        XCTAssertTrue(out.contains("Hello\n====="),
            "chapter title should have an `=` underline")
    }

    func test_skips_anchor_blocks() {
        let book = Book(
            title: "X",
            chapters: [Chapter(title: "C", blocks: [
                .anchor(id: "hu-page-0", label: "Page 1"),
                .paragraph(runs: [InlineRun("Body.")]),
            ])]
        )
        let out = PlainTextWriter.render(book)
        XCTAssertFalse(out.contains("hu-page-0"))
        XCTAssertTrue(out.contains("Body."))
    }

    func test_summarizes_figure_blocks() {
        let book = Book(
            title: "X",
            chapters: [Chapter(title: "C", blocks: [
                .figure(assetId: "fig-1", alt: "Figure 1", caption: [
                    InlineRun("A diagram of foo")
                ]),
            ])]
        )
        let out = PlainTextWriter.render(book)
        XCTAssertTrue(out.contains("[Figure: A diagram of foo]"),
            "figure with caption should render as bracketed line")
    }

    func test_summarizes_figure_without_caption() {
        let book = Book(
            title: "X",
            chapters: [Chapter(title: "C", blocks: [
                .figure(assetId: "fig-1", alt: "Figure 1", caption: []),
            ])]
        )
        let out = PlainTextWriter.render(book)
        XCTAssertTrue(out.contains("[Figure: Figure 1]"))
    }

    func test_summarizes_table_blocks() {
        let book = Book(
            title: "X",
            chapters: [Chapter(title: "C", blocks: [
                .table(rows: [
                    [TableCell(runs: [InlineRun("a")])],
                    [TableCell(runs: [InlineRun("b")])],
                ], caption: [InlineRun("Authors and years")]),
            ])]
        )
        let out = PlainTextWriter.render(book)
        XCTAssertTrue(out.contains("[Table: Authors and years"),
            "table with caption should render as bracketed line")
    }

    func test_renders_chapter_footnotes_at_end() {
        let book = Book(
            title: "X",
            chapters: [Chapter(
                title: "C",
                blocks: [.paragraph(runs: [InlineRun("Body.")])],
                footnotes: [
                    Footnote(id: "fn-1", marker: "1", runs: [InlineRun("First note.")]),
                    Footnote(id: "fn-2", marker: "*", runs: [InlineRun("Second note.")]),
                ]
            )]
        )
        let out = PlainTextWriter.render(book)
        XCTAssertTrue(out.contains("Notes\n-----"))
        XCTAssertTrue(out.contains("1. First note."))
        XCTAssertTrue(out.contains("*. Second note."))
    }

    func test_separates_chapters_with_blank_lines() {
        let book = Book(
            title: "X",
            chapters: [
                Chapter(title: "One", blocks: [.paragraph(runs: [InlineRun("a")])]),
                Chapter(title: "Two", blocks: [.paragraph(runs: [InlineRun("b")])]),
            ]
        )
        let out = PlainTextWriter.render(book)
        // Both chapter titles present.
        XCTAssertTrue(out.contains("One"))
        XCTAssertTrue(out.contains("Two"))
        // Two should appear after One.
        let oneIdx = out.range(of: "One")!.lowerBound
        let twoIdx = out.range(of: "Two")!.lowerBound
        XCTAssertTrue(oneIdx < twoIdx)
    }
}
