import XCTest
import Document
@testable import EPUB

/// `MarkdownWriter` produces a Markdown representation of a
/// `Book` — preserves heading levels, image references, table
/// grids, and `[^N]` footnote syntax.
final class MarkdownWriterTests: XCTestCase {

    func test_renders_title_as_h1() {
        let book = Book(title: "Origins", chapters: [])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.hasPrefix("# Origins\n"),
            "book title should be H1")
    }

    func test_renders_author_in_italics() {
        let book = Book(title: "X", author: "A. Author", chapters: [])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("*by A. Author*"))
    }

    func test_renders_year_and_publisher_metadata_line() {
        let book = Book(
            title: "X", author: "Y",
            chapters: [],
            year: "2003", publisher: "Press"
        )
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("*2003 · Press*"))
    }

    func test_renders_chapter_as_h2() {
        let book = Book(title: "X", chapters: [
            Chapter(title: "Chapter 1", blocks: []),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("## Chapter 1\n"))
    }

    func test_renders_in_chapter_headings_at_h3_and_below() {
        // The chapter title is H2; in-chapter headings shift by
        // 1 level (level=2 → ###, level=3 → ####).
        let book = Book(title: "X", chapters: [
            Chapter(title: "C", blocks: [
                .heading(level: 2, runs: [InlineRun("Section")]),
                .heading(level: 3, runs: [InlineRun("Subsection")]),
            ]),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("### Section"))
        XCTAssertTrue(out.contains("#### Subsection"))
    }

    func test_renders_paragraphs() {
        let book = Book(title: "X", chapters: [
            Chapter(title: "C", blocks: [
                .paragraph(runs: [InlineRun("Body text.")]),
            ]),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("Body text."))
    }

    func test_renders_figure_as_image_link() {
        let book = Book(title: "X", chapters: [
            Chapter(title: "C", blocks: [
                .figure(assetId: "fig-001", alt: "Foo", caption: []),
            ]),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("![Foo](images/fig-001.png)"))
    }

    func test_renders_figure_caption_as_italic() {
        let book = Book(title: "X", chapters: [
            Chapter(title: "C", blocks: [
                .figure(assetId: "fig-002", alt: "alt", caption: [
                    InlineRun("Figure 2: Diagram of foo")
                ]),
            ]),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("![Figure 2: Diagram of foo](images/fig-002.png)"))
        XCTAssertTrue(out.contains("*Figure 2: Diagram of foo*"))
    }

    func test_renders_table_with_header() {
        let book = Book(title: "X", chapters: [
            Chapter(title: "C", blocks: [
                .table(
                    rows: [
                        [
                            TableCell(runs: [InlineRun("Author")], isHeader: true),
                            TableCell(runs: [InlineRun("Year")], isHeader: true),
                        ],
                        [
                            TableCell(runs: [InlineRun("Foucault")]),
                            TableCell(runs: [InlineRun("1971")]),
                        ],
                    ],
                    caption: []
                ),
            ]),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("| Author | Year |"))
        XCTAssertTrue(out.contains("| --- | --- |"))
        XCTAssertTrue(out.contains("| Foucault | 1971 |"))
    }

    func test_renders_table_caption_as_bold() {
        let book = Book(title: "X", chapters: [
            Chapter(title: "C", blocks: [
                .table(
                    rows: [
                        [
                            TableCell(runs: [InlineRun("a")], isHeader: true),
                        ],
                        [TableCell(runs: [InlineRun("b")])],
                    ],
                    caption: [InlineRun("Table 1: Sample")]
                ),
            ]),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("**Table 1: Sample**"))
    }

    func test_renders_footnotes_as_inline_definitions() {
        let book = Book(title: "X", chapters: [
            Chapter(
                title: "C",
                blocks: [.paragraph(runs: [InlineRun("Body.")])],
                footnotes: [
                    Footnote(id: "fn-1", marker: "1", runs: [InlineRun("First note.")]),
                ]
            ),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("[^1]: First note."))
    }

    func test_skips_anchor_blocks() {
        let book = Book(title: "X", chapters: [
            Chapter(title: "C", blocks: [
                .anchor(id: "hu-page-0", label: "Page 1"),
                .paragraph(runs: [InlineRun("Body.")]),
            ]),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertFalse(out.contains("hu-page-0"))
        XCTAssertTrue(out.contains("Body."))
    }

    func test_escapes_pipe_in_table_cells() {
        // Pipe inside a cell breaks Markdown table syntax —
        // must be backslash-escaped.
        let book = Book(title: "X", chapters: [
            Chapter(title: "C", blocks: [
                .table(
                    rows: [[
                        TableCell(runs: [InlineRun("a|b")], isHeader: true),
                        TableCell(runs: [InlineRun("c|d")], isHeader: true),
                    ]],
                    caption: []
                ),
            ]),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("a\\|b"))
        XCTAssertTrue(out.contains("c\\|d"))
    }

    // MARK: - P-Math-LaTeX-Siblings

    func test_inline_math_renders_as_single_dollar_latex() {
        let book = Book(title: "X", chapters: [
            Chapter(title: "C", blocks: [
                .paragraph(runs: [
                    InlineRun("see "),
                    InlineRun(
                        "x",
                        rawXHTML: #"<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>"#,
                        latexFallback: "x"
                    ),
                    InlineRun(" for the variable"),
                ]),
            ]),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("see $x$ for the variable"),
            "expected inline LaTeX delimiters; got:\n\(out)")
    }

    func test_display_math_renders_as_double_dollar_latex() {
        let book = Book(title: "X", chapters: [
            Chapter(title: "C", blocks: [
                .paragraph(runs: [
                    InlineRun(
                        "E = mc^2",
                        rawXHTML: #"<math display="block" xmlns="http://www.w3.org/1998/Math/MathML"><mrow><mi>E</mi><mo>=</mo><mi>m</mi><msup><mi>c</mi><mn>2</mn></msup></mrow></math>"#,
                        latexFallback: "E = mc^{2}"
                    ),
                ]),
            ]),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("$$E = mc^{2}$$"),
            "expected display-math `$$…$$` delimiters; got:\n\(out)")
    }

    func test_math_without_latex_falls_back_to_plain_text() {
        // InlineRun with rawXHTML but no latexFallback (e.g. from
        // Surya inline-math rescue via InlineMathSplitter) emits
        // the plain-text `text` field — better than an empty
        // gap or the raw MathML markup in a .md file.
        let book = Book(title: "X", chapters: [
            Chapter(title: "C", blocks: [
                .paragraph(runs: [
                    InlineRun("ratio "),
                    InlineRun(
                        "w_m/w_f",
                        rawXHTML: "<math><mi>w_m/w_f</mi></math>",
                        latexFallback: nil
                    ),
                ]),
            ]),
        ])
        let out = MarkdownWriter.render(book)
        XCTAssertTrue(out.contains("ratio w_m/w_f"))
        XCTAssertFalse(out.contains("$"),
            "no LaTeX delimiters should appear when latexFallback is nil")
    }
}
