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

    // MARK: - Title-matching primary path (Lacan-shape scenarios)

    /// Lacan-shape: dense page anchors mean multiple offsets tie on
    /// match count, so the page-offset path picks wrong. Title
    /// matching keys on heading text and lands at the right blocks
    /// regardless of which offset would tie. matchStrategy must
    /// report `.titleMatch`.
    func test_title_matching_wins_when_offsets_are_ambiguous() throws {
        // Three essays. Page anchors exist for every PDF page, so
        // offsets 0, 1, 5, etc. all tie (every TOC entry hits an
        // anchor under any offset). Title text uniquely places each
        // boundary.
        var blocks: [Block] = []
        // Front matter (10 paragraphs + anchors).
        for i in 0..<10 {
            blocks.append(.anchor(id: "fm\(i)", label: "fm\(i)"))
            blocks.append(.paragraph(runs: [InlineRun("front matter line \(i)")]))
        }
        // Essay one — appears at PDF 10.
        blocks.append(.anchor(id: "p10", label: "p10"))
        blocks.append(.heading(level: 2, runs: [InlineRun("Overture to this Collection")]))
        blocks.append(.paragraph(runs: [InlineRun("overture body…")]))
        blocks.append(.anchor(id: "p11", label: "p11"))
        blocks.append(.paragraph(runs: [InlineRun("more overture")]))
        // Essay two — appears at PDF 12.
        blocks.append(.anchor(id: "p12", label: "p12"))
        blocks.append(.heading(level: 2, runs: [InlineRun("Seminar on The Purloined Letter")]))
        blocks.append(.paragraph(runs: [InlineRun("seminar body…")]))
        blocks.append(.anchor(id: "p13", label: "p13"))
        // Essay three — PDF 14.
        blocks.append(.anchor(id: "p14", label: "p14"))
        blocks.append(.heading(level: 2, runs: [InlineRun("Kant with Sade")]))
        blocks.append(.paragraph(runs: [InlineRun("kant body…")]))

        var pageAnchors: [PageAnchor] = []
        for i in 0..<10 {
            pageAnchors.append(.init(pdfPage: i, anchorId: "fm\(i)"))
        }
        for i in 10...14 {
            pageAnchors.append(.init(pdfPage: i, anchorId: "p\(i)"))
        }
        // TOC display pages would have ambiguous offset under page-
        // anchor learning — but title matching doesn't care.
        let toc = ParsedTOC(entries: [
            .init(title: "Overture to this Collection", displayPage: "3"),
            .init(title: "Seminar on \u{201C}The Purloined Letter\u{201D}", displayPage: "6"),
            .init(title: "Kant with Sade", displayPage: "44"),
        ])

        let result = try XCTUnwrap(TOCDrivenSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], toc: toc, bookFallbackTitle: "Book"
        ))
        XCTAssertEqual(result.diagnostics.matchStrategy, .titleMatch)
        XCTAssertEqual(result.diagnostics.resolvedEntries, 3)
        // Front matter + 3 essays.
        XCTAssertEqual(result.chapters.count, 4)
        XCTAssertEqual(result.chapters[0].title, "Front Matter")
        XCTAssertEqual(result.chapters[1].title, "Overture to this Collection")
        XCTAssertTrue((result.chapters[2].title ?? "").contains("Purloined"))
        XCTAssertEqual(result.chapters[3].title, "Kant with Sade")
    }

    /// Heading text has OCR garbage embedded — a misread page
    /// number ("I25"), a stray running-head fragment. After
    /// digit + whitespace normalization, the word bag still
    /// matches the TOC entry's words.
    func test_title_matching_tolerates_ocr_artifacts() throws {
        let blocks: [Block] = [
            .anchor(id: "p1", label: "1"),
            .paragraph(runs: [InlineRun("front matter")]),
            .anchor(id: "p2", label: "2"),
            .heading(level: 2, runs: [InlineRun(
                "A Theoretical Introduction to the Functions I25 of Psychoanalysis in Criminology"
            )]),
            .paragraph(runs: [InlineRun("body")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p1"),
            .init(pdfPage: 1, anchorId: "p2"),
        ]
        let toc = ParsedTOC(entries: [
            .init(
                title: "A Theoretical Introduction to the Functions of Psychoanalysis in Criminology",
                displayPage: "100"
            )
        ])
        // Need at least 2 entries to hit minRequired = 2; pad with
        // a second entry that also matches (otherwise nil).
        let toc2 = ParsedTOC(entries: toc.entries + [
            .init(title: "Coda Marker That Is Long Enough", displayPage: "200")
        ])
        // Add the second heading too so the second entry matches.
        var paddedBlocks = blocks
        paddedBlocks.append(.heading(level: 2, runs: [InlineRun("Coda Marker That Is Long Enough")]))
        paddedBlocks.append(.paragraph(runs: [InlineRun("coda body")]))

        let result = try XCTUnwrap(TOCDrivenSplitter.split(
            blocks: paddedBlocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], toc: toc2, bookFallbackTitle: "Book"
        ))
        XCTAssertEqual(result.diagnostics.matchStrategy, .titleMatch)
        // Verify the first chapter title is the TOC version, not
        // the OCR'd heading text with "I25" in it.
        XCTAssertTrue(result.chapters.contains {
            ($0.title ?? "").contains("Functions of Psychoanalysis")
        })
    }

    /// Diacritic variance: TOC uses "ÉCRITS", heading uses "ECRITS"
    /// (a common OCR shortcoming). After stripDiacritics normalization,
    /// they match.
    func test_title_matching_diacritic_insensitive() throws {
        let blocks: [Block] = [
            .anchor(id: "p1", label: "1"),
            .heading(level: 2, runs: [InlineRun("ECRITS Selection Premiere")]),
            .paragraph(runs: [InlineRun("body")]),
            .anchor(id: "p2", label: "2"),
            .heading(level: 2, runs: [InlineRun("ECRITS Selection Deuxieme")]),
            .paragraph(runs: [InlineRun("body")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p1"),
            .init(pdfPage: 1, anchorId: "p2"),
        ]
        let toc = ParsedTOC(entries: [
            .init(title: "Écrits Sélection Première", displayPage: "1"),
            .init(title: "Écrits Sélection Deuxième", displayPage: "2"),
        ])
        let result = try XCTUnwrap(TOCDrivenSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], toc: toc, bookFallbackTitle: "Book"
        ))
        XCTAssertEqual(result.diagnostics.matchStrategy, .titleMatch)
        XCTAssertEqual(result.chapters.count, 2)
    }

    /// Running-head heading text shouldn't be a chapter boundary
    /// even when it overlaps with a TOC entry's words. The
    /// canBreakChapter filter catches the running-head dedup.
    func test_title_matching_skips_running_heads() throws {
        // "Chapter Notes" appears 5 times — once per page. It would
        // otherwise match a TOC entry "Notes" via word containment.
        var blocks: [Block] = []
        for i in 0..<5 {
            blocks.append(.anchor(id: "p\(i)", label: "p\(i)"))
            blocks.append(.heading(level: 2, runs: [InlineRun("Chapter Notes")]))
            blocks.append(.paragraph(runs: [InlineRun("page \(i) body")]))
        }
        // Real "Conclusion" heading appears once at the end.
        blocks.append(.anchor(id: "p5", label: "p5"))
        blocks.append(.heading(level: 2, runs: [InlineRun("Conclusion of the Whole")]))
        blocks.append(.paragraph(runs: [InlineRun("conclusion body")]))

        var pageAnchors: [PageAnchor] = []
        for i in 0...5 {
            pageAnchors.append(.init(pdfPage: i, anchorId: "p\(i)"))
        }
        // TOC entries — "Some Important Notes" should NOT match the
        // running-head "Chapter Notes" (filtered by canBreakChapter).
        let toc = ParsedTOC(entries: [
            .init(title: "Some Important Notes on the Method", displayPage: "1"),
            .init(title: "Conclusion of the Whole", displayPage: "6"),
        ])
        // The first TOC entry shouldn't match anything (running
        // head is filtered, and there's no other "Notes" heading).
        // The second should match "Conclusion of the Whole."
        // With only 1/2 = 50% match rate, this hits exactly the
        // minRequired floor of max(2, ceil(2 * 0.5)) = 2.
        // So this test exercises the boundary: title-matching gets
        // 1 match but needs 2 — falls through to page-offset, which
        // should resolve via anchors.
        let result = TOCDrivenSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], toc: toc, bookFallbackTitle: "Book"
        )
        // Either path is acceptable here; just verify the running
        // head doesn't end up as a chapter title.
        if let result {
            XCTAssertFalse(
                result.chapters.contains { $0.title == "Chapter Notes" },
                "running-head heading must not become a chapter"
            )
        }
    }

    /// Ultra-short TOC entries ("I", "II") shouldn't match anywhere
    /// — they'd be too easy to mis-place. The splitter skips them
    /// during title-matching; they get folded into the preceding
    /// chapter.
    func test_title_matching_skips_ultra_short_entries() throws {
        let blocks: [Block] = [
            .anchor(id: "p1", label: "1"),
            .heading(level: 2, runs: [InlineRun("A Longer Chapter Title")]),
            .paragraph(runs: [InlineRun("body")]),
            .anchor(id: "p2", label: "2"),
            .heading(level: 2, runs: [InlineRun("Another Chapter With More Words")]),
            .paragraph(runs: [InlineRun("body")]),
        ]
        let pageAnchors: [PageAnchor] = [
            .init(pdfPage: 0, anchorId: "p1"),
            .init(pdfPage: 1, anchorId: "p2"),
        ]
        let toc = ParsedTOC(entries: [
            .init(title: "I", displayPage: "1"),    // too short, skipped
            .init(title: "A Longer Chapter Title", displayPage: "1"),
            .init(title: "Another Chapter With More Words", displayPage: "2"),
        ])
        let result = try XCTUnwrap(TOCDrivenSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: pageAnchors,
            figureAssets: [], toc: toc, bookFallbackTitle: "Book"
        ))
        XCTAssertEqual(result.diagnostics.matchStrategy, .titleMatch)
        XCTAssertEqual(result.diagnostics.resolvedEntries, 2,
            "the bare 'I' entry should be skipped, not folded into a boundary")
        XCTAssertEqual(result.chapters.count, 2)
    }

    // MARK: - Page-offset fallback (existing strategy)

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
