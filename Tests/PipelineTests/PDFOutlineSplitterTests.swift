import XCTest
import Document
import PDFIngest  // OutlineEntry
@testable import Pipeline

/// Coverage for `PDFOutlineSplitter` — the highest-confidence
/// chapter splitter (runs when the source PDF carries publisher-
/// set bookmarks). Tests mirror the shape of `TOCDrivenSplitterTests`:
/// synthetic block streams + page anchors + a fabricated `[OutlineEntry]`,
/// no real PDFs involved (extractor coverage is separate).
final class PDFOutlineSplitterTests: XCTestCase {

    // MARK: - Happy path

    /// 3 outline entries at PDF pages 0 / 10 / 20; matching page
    /// anchors in the block stream. Expect Front Matter + 3
    /// chapters.
    func test_outline_splits_at_each_entry() throws {
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun("dedication line")]),
            .anchor(id: "p0", label: "0"),
            .heading(level: 2, runs: [InlineRun("Introduction")]),
            .paragraph(runs: [InlineRun("intro body")]),
            .anchor(id: "p10", label: "10"),
            .heading(level: 2, runs: [InlineRun("Chapter Heading That OCR Mis-detected")]),
            .paragraph(runs: [InlineRun("body")]),
            .anchor(id: "p20", label: "20"),
            .heading(level: 2, runs: [InlineRun("Last")]),
            .paragraph(runs: [InlineRun("body")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p0"),
            .init(pdfPage: 10, anchorId: "p10"),
            .init(pdfPage: 20, anchorId: "p20"),
        ]
        let outline: [OutlineEntry] = [
            .init(title: "Introduction", pdfPage: 0),
            .init(title: "Chapter 2: The Real Title", pdfPage: 10),
            .init(title: "Chapter 3", pdfPage: 20),
        ]

        let result = try XCTUnwrap(PDFOutlineSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], outline: outline
        ))
        XCTAssertEqual(result.diagnostics.resolvedEntries, 3)
        XCTAssertEqual(result.chapters.count, 4,
            "front matter + 3 outline entries = 4 chapters")
        XCTAssertEqual(result.chapters[0].title, "Front Matter")
        // Outline-provided titles win over whatever the OCR'd
        // heading text says — the second entry's content has a
        // mis-detected heading but the bookmark label is the
        // authoritative title.
        XCTAssertEqual(result.chapters[1].title, "Introduction")
        XCTAssertEqual(result.chapters[2].title, "Chapter 2: The Real Title")
        XCTAssertEqual(result.chapters[3].title, "Chapter 3")
    }

    /// No front matter to surface when the first block IS the
    /// first boundary's matched anchor.
    func test_no_front_matter_when_first_block_is_first_entry() throws {
        let blocks: [Block] = [
            .anchor(id: "p0", label: "0"),
            .heading(level: 2, runs: [InlineRun("One")]),
            .paragraph(runs: [InlineRun("body")]),
            .anchor(id: "p5", label: "5"),
            .heading(level: 2, runs: [InlineRun("Two")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p0"),
            .init(pdfPage: 5, anchorId: "p5"),
        ]
        let outline: [OutlineEntry] = [
            .init(title: "Chapter One", pdfPage: 0),
            .init(title: "Chapter Two", pdfPage: 5),
        ]
        let result = try XCTUnwrap(PDFOutlineSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], outline: outline
        ))
        XCTAssertEqual(result.chapters.count, 2)
        XCTAssertEqual(result.chapters[0].title, "Chapter One")
        XCTAssertEqual(result.chapters[1].title, "Chapter Two")
    }

    // MARK: - Fuzzy lookup

    /// Outline says page 9 but the page anchor for PDF 9 didn't
    /// survive page-break detection. The splitter should fall
    /// back to the closest anchor within ±2 pages.
    func test_fuzzy_lookup_within_tolerance() throws {
        let blocks: [Block] = [
            .anchor(id: "p0", label: "0"),
            .heading(level: 2, runs: [InlineRun("A")]),
            // No anchor at pdf=9; anchor at pdf=10 should still match.
            .anchor(id: "p10", label: "10"),
            .heading(level: 2, runs: [InlineRun("B")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p0"),
            .init(pdfPage: 10, anchorId: "p10"),
        ]
        let outline: [OutlineEntry] = [
            .init(title: "Ch A", pdfPage: 0),
            .init(title: "Ch B", pdfPage: 9),  // off-by-one from anchor
        ]
        let result = try XCTUnwrap(PDFOutlineSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], outline: outline
        ))
        XCTAssertEqual(result.chapters.count, 2)
        XCTAssertEqual(result.chapters[1].title, "Ch B")
    }

    // MARK: - Dedupe

    /// Two outline entries pointing at the same PDF page collapse
    /// to one boundary; first title wins. Mirrors `TOCDrivenSplitter`.
    func test_two_entries_on_same_page_collapse_to_one_boundary() throws {
        let blocks: [Block] = [
            .anchor(id: "p0", label: "0"),
            .heading(level: 2, runs: [InlineRun("Top")]),
            .anchor(id: "p10", label: "10"),
            .heading(level: 2, runs: [InlineRun("Mid")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p0"),
            .init(pdfPage: 10, anchorId: "p10"),
        ]
        let outline: [OutlineEntry] = [
            .init(title: "Chapter 1", pdfPage: 0),
            .init(title: "Section 1.1", pdfPage: 0),
            .init(title: "Chapter 2", pdfPage: 10),
        ]
        let result = try XCTUnwrap(PDFOutlineSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], outline: outline
        ))
        XCTAssertEqual(result.chapters.count, 2)
        XCTAssertEqual(result.chapters[0].title, "Chapter 1",
            "duplicate-page collapse: first-listed wins")
    }

    // MARK: - Sparse / missing inputs

    func test_too_few_entries_returns_nil() {
        let blocks: [Block] = [.anchor(id: "p0", label: "0")]
        let pageAnchors: [PageAnchor] = [.init(pdfPage: 0, anchorId: "p0")]
        // 1 entry < minEntries (2) — splitter declines.
        XCTAssertNil(PDFOutlineSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], outline: [
                .init(title: "Only Entry", pdfPage: 0)
            ]
        ))
    }

    func test_empty_outline_returns_nil() {
        let blocks: [Block] = [.anchor(id: "p0", label: "0")]
        let pageAnchors: [PageAnchor] = [.init(pdfPage: 0, anchorId: "p0")]
        XCTAssertNil(PDFOutlineSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], outline: []
        ))
    }

    func test_no_page_anchors_returns_nil() {
        // Pure-text block stream with no `.anchor` blocks — even a
        // confident outline can't map to block indices. Caller
        // falls through to the heuristic splitter.
        let blocks: [Block] = [
            .heading(level: 2, runs: [InlineRun("title")]),
            .paragraph(runs: [InlineRun("body")]),
        ]
        let outline: [OutlineEntry] = [
            .init(title: "Ch 1", pdfPage: 0),
            .init(title: "Ch 2", pdfPage: 1),
        ]
        XCTAssertNil(PDFOutlineSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            figureAssets: [], outline: outline
        ))
    }

    func test_unresolved_entries_dont_abort_split() throws {
        // Outline points at pdf=99 which is past every page anchor.
        // The valid entries still drive boundaries; the orphan is
        // counted in diagnostics.
        let blocks: [Block] = [
            .anchor(id: "p0", label: "0"),
            .heading(level: 2, runs: [InlineRun("One")]),
            .anchor(id: "p5", label: "5"),
            .heading(level: 2, runs: [InlineRun("Two")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p0"),
            .init(pdfPage: 5, anchorId: "p5"),
        ]
        let outline: [OutlineEntry] = [
            .init(title: "Ch 1", pdfPage: 0),
            .init(title: "Ch 2", pdfPage: 5),
            .init(title: "Orphan", pdfPage: 99),
        ]
        let result = try XCTUnwrap(PDFOutlineSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], outline: outline
        ))
        XCTAssertEqual(result.diagnostics.resolvedEntries, 2)
        XCTAssertEqual(result.diagnostics.unresolvedEntries, 1)
        XCTAssertEqual(result.chapters.count, 2)
    }

    // MARK: - Ordering

    /// Outline entries arrive out of document order (rare — a
    /// publisher's bookmark tree shouldn't, but defensive sort
    /// is cheap insurance). Boundaries should sort by block index.
    func test_out_of_order_entries_get_sorted() throws {
        let blocks: [Block] = [
            .anchor(id: "p0", label: "0"),
            .heading(level: 2, runs: [InlineRun("A")]),
            .anchor(id: "p10", label: "10"),
            .heading(level: 2, runs: [InlineRun("B")]),
            .anchor(id: "p20", label: "20"),
            .heading(level: 2, runs: [InlineRun("C")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p0"),
            .init(pdfPage: 10, anchorId: "p10"),
            .init(pdfPage: 20, anchorId: "p20"),
        ]
        let outline: [OutlineEntry] = [
            .init(title: "Last", pdfPage: 20),
            .init(title: "First", pdfPage: 0),
            .init(title: "Middle", pdfPage: 10),
        ]
        let result = try XCTUnwrap(PDFOutlineSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], outline: outline
        ))
        XCTAssertEqual(result.chapters.map(\.title),
                       ["First", "Middle", "Last"])
    }
}
