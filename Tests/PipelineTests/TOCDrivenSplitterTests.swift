import XCTest
import Document
import EPUB  // ParsedTOC
@testable import Pipeline

/// Coverage for `TOCDrivenSplitter` — the primary chapter splitter
/// when a printed TOC has been parsed. The fixture shape mirrors
/// what the pipeline hands the splitter at conversion time: a flat
/// `[Block]` stream with `.anchor` page-break blocks, a parallel
/// `[PageAnchor]` table, and a `ParsedTOC` extracted by Haiku from
/// the front matter.
final class TOCDrivenSplitterTests: XCTestCase {

    // MARK: - happy path

    /// 3-essay book, TOC entries on pages 1 / 10 / 20, page anchors
    /// at the matching block indices. Expect 3 chapters + a Front
    /// Matter prefix (anchor + a paragraph before page 1).
    func test_happy_path_splits_at_each_TOC_boundary() throws {
        let blocks: [Block] = [
            // Front matter — block 0..1
            .paragraph(runs: [InlineRun("dedication blurb")]),
            .anchor(id: "p1", label: "1"),
            // Essay one — block 2..4
            .heading(level: 2, runs: [InlineRun("Essay One")]),
            .paragraph(runs: [InlineRun("essay one body")]),
            .anchor(id: "p10", label: "10"),
            // Essay two — block 5..7
            .heading(level: 2, runs: [InlineRun("Essay Two")]),
            .paragraph(runs: [InlineRun("essay two body")]),
            .anchor(id: "p20", label: "20"),
            // Essay three — block 8..9
            .heading(level: 2, runs: [InlineRun("Essay Three")]),
            .paragraph(runs: [InlineRun("essay three body")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p1"),
            .init(pdfPage: 9, anchorId: "p10"),
            .init(pdfPage: 19, anchorId: "p20"),
        ]
        let toc = ParsedTOC(entries: [
            .init(title: "Essay One", displayPage: "1"),
            .init(title: "Essay Two", displayPage: "10"),
            .init(title: "Essay Three", displayPage: "20"),
        ])

        let result = try XCTUnwrap(TOCDrivenSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], toc: toc, bookFallbackTitle: "Test Book"
        ))

        XCTAssertEqual(result.chapters.count, 4,
            "front matter + 3 TOC entries = 4 chapters")
        XCTAssertEqual(result.chapters[0].title, "Front Matter")
        XCTAssertEqual(result.chapters[1].title, "Essay One")
        XCTAssertEqual(result.chapters[2].title, "Essay Two")
        XCTAssertEqual(result.chapters[3].title, "Essay Three")
        XCTAssertEqual(result.diagnostics.resolvedEntries, 3)
        XCTAssertEqual(result.diagnostics.unresolvedEntries, 0)
    }

    /// Same book, but the first content block is already at page 1
    /// (no pre-page-1 material). Front Matter should be suppressed.
    func test_no_front_matter_when_first_block_is_first_boundary() throws {
        let blocks: [Block] = [
            .anchor(id: "p1", label: "1"),
            .heading(level: 2, runs: [InlineRun("Chapter One")]),
            .paragraph(runs: [InlineRun("body")]),
            .anchor(id: "p5", label: "5"),
            .heading(level: 2, runs: [InlineRun("Chapter Two")]),
            .paragraph(runs: [InlineRun("body")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p1"),
            .init(pdfPage: 4, anchorId: "p5"),
        ]
        let toc = ParsedTOC(entries: [
            .init(title: "Chapter One", displayPage: "1"),
            .init(title: "Chapter Two", displayPage: "5"),
        ])

        let result = try XCTUnwrap(TOCDrivenSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], toc: toc, bookFallbackTitle: "Book"
        ))
        XCTAssertEqual(result.chapters.count, 2)
        XCTAssertEqual(result.chapters[0].title, "Chapter One")
        XCTAssertEqual(result.chapters[1].title, "Chapter Two")
    }

    // MARK: - offset learning

    /// TOC display pages are 1-based but the book has 12 pages of
    /// roman-numeral front matter before "page 1" of the body —
    /// classic mid-20th-century convention. The offset learner
    /// should find +12. Front-matter anchors are deliberately
    /// sparse (every 6th page) so they don't ambiguously match
    /// the offset-1 hypothesis: with anchors at PDF 0 and 6 only,
    /// no candidate offset besides +12 explains all three body
    /// boundaries.
    func test_offset_learning_aligns_with_roman_front_matter_pages() throws {
        var blocks: [Block] = []
        blocks.append(.anchor(id: "fm0", label: "fm0"))
        blocks.append(.paragraph(runs: [InlineRun("cover")]))
        blocks.append(.anchor(id: "fm6", label: "fm6"))
        blocks.append(.paragraph(runs: [InlineRun("dedication")]))
        blocks.append(.anchor(id: "p1", label: "p1"))
        blocks.append(.heading(level: 2, runs: [InlineRun("A")]))
        blocks.append(.paragraph(runs: [InlineRun("a body")]))
        blocks.append(.anchor(id: "p17", label: "p17"))
        blocks.append(.heading(level: 2, runs: [InlineRun("B")]))
        blocks.append(.paragraph(runs: [InlineRun("b body")]))
        blocks.append(.anchor(id: "p32", label: "p32"))
        blocks.append(.heading(level: 2, runs: [InlineRun("C")]))
        blocks.append(.paragraph(runs: [InlineRun("c body")]))

        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "fm0"),
            .init(pdfPage: 6, anchorId: "fm6"),
            .init(pdfPage: 12, anchorId: "p1"),    // display 1
            .init(pdfPage: 28, anchorId: "p17"),   // display 17
            .init(pdfPage: 43, anchorId: "p32"),   // display 32
        ]
        let toc = ParsedTOC(entries: [
            .init(title: "A", displayPage: "1"),
            .init(title: "B", displayPage: "17"),
            .init(title: "C", displayPage: "32"),
        ])

        let result = try XCTUnwrap(TOCDrivenSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], toc: toc, bookFallbackTitle: "Book"
        ))
        XCTAssertEqual(result.diagnostics.inferredOffset, 12,
            "offset should be +12 — display 1 maps to PDF 12")
        XCTAssertEqual(result.chapters.last?.title, "C")
    }

    // MARK: - confidence gate

    /// TOC has 4 arabic entries but only 1 aligns to a page anchor
    /// under any candidate offset. Below the 50% confidence floor —
    /// must return nil so the caller falls through to the heuristic
    /// splitter.
    func test_low_confidence_returns_nil() {
        let blocks: [Block] = [
            .anchor(id: "p1", label: "1"),
            .paragraph(runs: [InlineRun("body")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p1"),
        ]
        // 4 TOC entries; only "Page 1" maps. 1/4 < 0.5 → bail.
        let toc = ParsedTOC(entries: [
            .init(title: "A", displayPage: "1"),
            .init(title: "B", displayPage: "47"),
            .init(title: "C", displayPage: "88"),
            .init(title: "D", displayPage: "133"),
        ])
        let result = TOCDrivenSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], toc: toc, bookFallbackTitle: "Book"
        )
        XCTAssertNil(result)
    }

    func test_empty_toc_returns_nil() {
        let blocks: [Block] = [.anchor(id: "p1", label: "1")]
        let pageAnchors: [PageAnchor] = [.init(pdfPage: 0, anchorId: "p1")]
        XCTAssertNil(TOCDrivenSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], toc: ParsedTOC(entries: []),
            bookFallbackTitle: "Book"
        ))
    }

    func test_no_page_anchors_returns_nil() {
        // Scanned-image PDF with no page-break detection — even a
        // perfect TOC can't be aligned. Caller falls back to the
        // heuristic splitter.
        let blocks: [Block] = [
            .heading(level: 2, runs: [InlineRun("Anything")]),
            .paragraph(runs: [InlineRun("body")]),
        ]
        let toc = ParsedTOC(entries: [
            .init(title: "Anything", displayPage: "1")
        ])
        XCTAssertNil(TOCDrivenSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            figureAssets: [], toc: toc, bookFallbackTitle: "Book"
        ))
    }

    // MARK: - dedupe + ordering

    /// Two TOC entries on the same page should collapse to one
    /// boundary — the first title wins. Mirrors real-world OCR
    /// where a chapter title and a sub-heading both land on the
    /// chapter's opening page.
    func test_two_toc_entries_on_same_page_collapse_to_one_boundary() throws {
        let blocks: [Block] = [
            .anchor(id: "p1", label: "1"),
            .heading(level: 2, runs: [InlineRun("Chapter 1")]),
            .paragraph(runs: [InlineRun("body")]),
            .anchor(id: "p10", label: "10"),
            .heading(level: 2, runs: [InlineRun("Chapter 2")]),
            .paragraph(runs: [InlineRun("body")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p1"),
            .init(pdfPage: 9, anchorId: "p10"),
        ]
        let toc = ParsedTOC(entries: [
            .init(title: "Chapter 1", displayPage: "1"),
            .init(title: "Section 1.1", displayPage: "1"),
            .init(title: "Chapter 2", displayPage: "10"),
        ])
        let result = try XCTUnwrap(TOCDrivenSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], toc: toc, bookFallbackTitle: "Book"
        ))
        XCTAssertEqual(result.chapters.count, 2)
        XCTAssertEqual(result.chapters[0].title, "Chapter 1",
            "first TOC entry on a duplicate-page wins")
        XCTAssertEqual(result.chapters[1].title, "Chapter 2")
    }

    // MARK: - fuzzy lookup

    /// TOC says page 50, but the page-anchor at PDF 50 didn't survive
    /// page-break detection (a layout glitch). The splitter should
    /// fall back to PDF 49 or 51 within the ±2 tolerance window.
    func test_fuzzy_lookup_finds_block_within_tolerance() throws {
        let blocks: [Block] = [
            .anchor(id: "p1", label: "1"),
            .heading(level: 2, runs: [InlineRun("Ch 1")]),
            .paragraph(runs: [InlineRun("body")]),
            // No anchor at PDF 9 (display page 10). Anchor at PDF 10
            // (display page 11) is what survived.
            .anchor(id: "p11", label: "11"),
            .heading(level: 2, runs: [InlineRun("Ch 2")]),
            .paragraph(runs: [InlineRun("body")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p1"),
            .init(pdfPage: 10, anchorId: "p11"),
        ]
        // TOC says Ch 2 is on display page 10 — but PDF 9 has no
        // anchor. Splitter should still find PDF 10 (within ±2).
        let toc = ParsedTOC(entries: [
            .init(title: "Ch 1", displayPage: "1"),
            .init(title: "Ch 2", displayPage: "10"),
        ])
        let result = try XCTUnwrap(TOCDrivenSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], toc: toc, bookFallbackTitle: "Book"
        ))
        XCTAssertEqual(result.chapters.count, 2)
        XCTAssertEqual(result.chapters[1].title, "Ch 2")
    }
}
