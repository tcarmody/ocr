import XCTest
import Document
@testable import Pipeline

/// Tests `ChapterSplitter.split` — Phase 1 of structured-document
/// detection. Splits a flat block stream at H1 boundaries, builds
/// Front Matter from pre-first-H1 content, and distributes footnotes
/// + page anchors to the right chapter.
final class ChapterSplitterTests: XCTestCase {

    // MARK: - degenerate cases

    /// No H1s in the block stream → single chapter (matches the
    /// pre-Phase-1 behavior so simple pieces still produce valid
    /// EPUBs).
    func test_no_h1_returns_single_chapter_with_fallback_title() {
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun("Just some prose.")]),
            .paragraph(runs: [InlineRun("More prose.")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "My Book"
        )
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "My Book")
        XCTAssertEqual(chapters[0].blocks.count, 2)
    }

    /// Empty block stream → single empty chapter (defensive — the
    /// converter should never reach here with zero blocks, but we
    /// shouldn't crash).
    func test_empty_blocks_returns_single_empty_chapter() {
        let chapters = ChapterSplitter.split(
            blocks: [], footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Empty Book"
        )
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "Empty Book")
        XCTAssertEqual(chapters[0].blocks.count, 0)
    }

    // MARK: - H1 splitting

    /// Two H1s, no front matter → two chapters.
    func test_two_h1s_produces_two_chapters_with_titles_from_headings() {
        let blocks: [Block] = [
            .heading(level: 1, runs: [InlineRun("Chapter One")]),
            .paragraph(runs: [InlineRun("First chapter body.")]),
            .heading(level: 1, runs: [InlineRun("Chapter Two")]),
            .paragraph(runs: [InlineRun("Second chapter body.")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "Chapter One")
        XCTAssertEqual(chapters[1].title, "Chapter Two")
        // Each chapter's blocks include the H1 itself.
        XCTAssertEqual(chapters[0].blocks.count, 2)
        XCTAssertEqual(chapters[1].blocks.count, 2)
    }

    /// Substantive content before the first H1 becomes a Front Matter
    /// chapter.
    func test_substantive_pre_h1_content_becomes_front_matter() {
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun("Dedication: For my parents.")]),
            .heading(level: 1, runs: [InlineRun("Chapter One")]),
            .paragraph(runs: [InlineRun("Body.")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, ChapterSplitter.frontMatterTitle)
        XCTAssertEqual(chapters[1].title, "Chapter One")
    }

    /// Pre-H1 segment with nothing but page anchors gets dropped —
    /// otherwise we'd produce an empty Front Matter chapter for
    /// every book whose first page renders as a single anchor.
    func test_pre_h1_anchors_only_does_not_create_front_matter() {
        let blocks: [Block] = [
            .anchor(id: "hu-page-0", label: "Page 1"),
            .heading(level: 1, runs: [InlineRun("Chapter One")]),
            .paragraph(runs: [InlineRun("Body.")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters.count, 1, "anchor-only front matter should be dropped")
        XCTAssertEqual(chapters[0].title, "Chapter One")
    }

    /// H1 with empty/whitespace text is filtered as non-eligible by
    /// the chapter-break filter (min length gate) — no chapter break
    /// happens, so the document falls through to the single-chapter
    /// fallback with the book-level title. Earlier the empty heading
    /// would still open a chapter named "Chapter 1"; the new behavior
    /// is more conservative.
    func test_empty_h1_does_not_open_chapter() {
        let blocks: [Block] = [
            .heading(level: 1, runs: [InlineRun("   ")]),
            .paragraph(runs: [InlineRun("Body.")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "Book")
    }

    /// H1 with multi-run text (e.g. mixed-language runs) joins all
    /// run text for the chapter title.
    func test_h1_with_multiple_runs_joins_them_for_title() {
        let blocks: [Block] = [
            .heading(level: 1, runs: [
                InlineRun("Caput "),
                InlineRun("I", language: BCP47("la")),
            ]),
            .paragraph(runs: [InlineRun("Body.")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters[0].title, "Caput I")
    }

    // MARK: - footnote distribution

    /// Footnotes are filtered to only those referenced from the
    /// chapter's inline runs.
    func test_footnotes_distributed_to_referencing_chapter_only() {
        let fn1 = Footnote(id: "fn-p1-1", marker: "1", runs: [InlineRun("First note.")])
        let fn2 = Footnote(id: "fn-p5-2", marker: "2", runs: [InlineRun("Second note.")])
        let blocks: [Block] = [
            .heading(level: 1, runs: [InlineRun("Chapter One")]),
            .paragraph(runs: [
                InlineRun("Body with note"),
                InlineRun("1", noterefId: "fn-p1-1"),
            ]),
            .heading(level: 1, runs: [InlineRun("Chapter Two")]),
            .paragraph(runs: [
                InlineRun("Other body with note"),
                InlineRun("2", noterefId: "fn-p5-2"),
            ]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [fn1, fn2], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters[0].footnotes.map(\.id), ["fn-p1-1"])
        XCTAssertEqual(chapters[1].footnotes.map(\.id), ["fn-p5-2"])
    }

    /// Footnotes referenced by no chapter (orphans) are dropped from
    /// the per-chapter lists.
    func test_orphan_footnotes_dropped_from_all_chapters() {
        let referenced = Footnote(id: "fn-p1-1", marker: "1", runs: [InlineRun("Used.")])
        let orphan = Footnote(id: "fn-p9-9", marker: "9", runs: [InlineRun("Never referenced.")])
        let blocks: [Block] = [
            .heading(level: 1, runs: [InlineRun("Chapter One")]),
            .paragraph(runs: [
                InlineRun("With note"),
                InlineRun("1", noterefId: "fn-p1-1"),
            ]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks,
            footnotes: [referenced, orphan],
            pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters[0].footnotes.map(\.id), ["fn-p1-1"])
    }

    // MARK: - page anchor distribution

    /// Page anchors are distributed to the chapter whose blocks
    /// contain the matching `Block.anchor` element.
    func test_page_anchors_distributed_by_anchor_block_position() {
        let pa1 = PageAnchor(pdfPage: 0, anchorId: "hu-page-0")
        let pa2 = PageAnchor(pdfPage: 1, anchorId: "hu-page-1")
        let pa3 = PageAnchor(pdfPage: 2, anchorId: "hu-page-2")
        let blocks: [Block] = [
            .heading(level: 1, runs: [InlineRun("Chapter One")]),
            .anchor(id: "hu-page-0", label: "Page 1"),
            .paragraph(runs: [InlineRun("Body.")]),
            .anchor(id: "hu-page-1", label: "Page 2"),
            .heading(level: 1, runs: [InlineRun("Chapter Two")]),
            .anchor(id: "hu-page-2", label: "Page 3"),
            .paragraph(runs: [InlineRun("More.")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks,
            footnotes: [],
            pageAnchors: [pa1, pa2, pa3],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters[0].pageAnchors.map(\.anchorId).sorted(),
                       ["hu-page-0", "hu-page-1"])
        XCTAssertEqual(chapters[1].pageAnchors.map(\.anchorId), ["hu-page-2"])
    }

    // MARK: - integration

    /// Realistic example: front matter + two chapters, mixed
    /// footnotes and anchors. Verifies the whole distribution chain.
    func test_full_book_with_front_matter_chapters_footnotes_anchors() {
        let pa0 = PageAnchor(pdfPage: 0, anchorId: "hu-page-0")
        let pa1 = PageAnchor(pdfPage: 1, anchorId: "hu-page-1")
        let pa2 = PageAnchor(pdfPage: 2, anchorId: "hu-page-2")
        let fnA = Footnote(id: "fn-p1-1", marker: "1", runs: [InlineRun("First.")])
        let fnB = Footnote(id: "fn-p3-1", marker: "1", runs: [InlineRun("Second.")])
        let blocks: [Block] = [
            .anchor(id: "hu-page-0", label: "Page 1"),
            .paragraph(runs: [InlineRun("Dedication.")]),
            .heading(level: 1, runs: [InlineRun("Introduction")]),
            .anchor(id: "hu-page-1", label: "Page 2"),
            .paragraph(runs: [
                InlineRun("Intro text "),
                InlineRun("1", noterefId: "fn-p1-1"),
            ]),
            .heading(level: 1, runs: [InlineRun("Chapter One")]),
            .anchor(id: "hu-page-2", label: "Page 3"),
            .paragraph(runs: [
                InlineRun("Chapter content "),
                InlineRun("1", noterefId: "fn-p3-1"),
            ]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks,
            footnotes: [fnA, fnB],
            pageAnchors: [pa0, pa1, pa2],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, ChapterSplitter.frontMatterTitle)
        XCTAssertEqual(chapters[1].title, "Introduction")
        XCTAssertEqual(chapters[2].title, "Chapter One")
        XCTAssertEqual(chapters[0].pageAnchors.map { $0.anchorId }, ["hu-page-0"])
        XCTAssertEqual(chapters[1].pageAnchors.map { $0.anchorId }, ["hu-page-1"])
        XCTAssertEqual(chapters[2].pageAnchors.map { $0.anchorId }, ["hu-page-2"])
        XCTAssertTrue(chapters[0].footnotes.isEmpty)
        XCTAssertEqual(chapters[1].footnotes.map { $0.id }, ["fn-p1-1"])
        XCTAssertEqual(chapters[2].footnotes.map { $0.id }, ["fn-p3-1"])
    }

    // MARK: - dominant heading level detection

    /// One H1 (book title) + many H2s (chapter starts) → split at H2.
    /// This is the typical Surya output: `.title` → H1 only on the
    /// title page, `.sectionHeader` → H2 for chapter headings.
    func test_one_h1_plus_many_h2s_splits_at_h2() {
        let blocks: [Block] = [
            .heading(level: 1, runs: [InlineRun("The Book")]),
            .paragraph(runs: [InlineRun("by author")]),
            .heading(level: 2, runs: [InlineRun("Chapter 1")]),
            .paragraph(runs: [InlineRun("body of chapter 1")]),
            .heading(level: 2, runs: [InlineRun("Chapter 2")]),
            .paragraph(runs: [InlineRun("body of chapter 2")]),
            .heading(level: 2, runs: [InlineRun("Chapter 3")]),
            .paragraph(runs: [InlineRun("body of chapter 3")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        // Front matter (title page) + 3 chapters.
        XCTAssertEqual(chapters.count, 4)
        XCTAssertEqual(chapters[0].title, ChapterSplitter.frontMatterTitle)
        XCTAssertEqual(chapters[1].title, "Chapter 1")
        XCTAssertEqual(chapters[2].title, "Chapter 2")
        XCTAssertEqual(chapters[3].title, "Chapter 3")
    }

    /// Many H1s (each chapter starts with its own H1) → split at H1
    /// even when H2 also has occurrences. H1 wins on "smallest level
    /// with ≥ 2 occurrences."
    func test_many_h1s_splits_at_h1_even_with_h2_present() {
        let blocks: [Block] = [
            .heading(level: 1, runs: [InlineRun("Chapter 1")]),
            .heading(level: 2, runs: [InlineRun("Section 1.1")]),
            .paragraph(runs: [InlineRun("body")]),
            .heading(level: 1, runs: [InlineRun("Chapter 2")]),
            .heading(level: 2, runs: [InlineRun("Section 2.1")]),
            .paragraph(runs: [InlineRun("body")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "Chapter 1")
        XCTAssertEqual(chapters[1].title, "Chapter 2")
    }

    /// Single H2 doesn't qualify (need ≥ 2 occurrences). Falls back
    /// to single chapter with the book's fallback title.
    func test_lone_h2_falls_back_to_single_chapter() {
        let blocks: [Block] = [
            .heading(level: 2, runs: [InlineRun("The Only Section")]),
            .paragraph(runs: [InlineRun("body")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Pamphlet"
        )
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "Pamphlet")
    }

    /// Detection helper isolated. Heading texts must pass
    /// `canBreakChapter` (length ≥ 3, starts non-lowercase, etc.) to
    /// count toward the dominant level.
    func test_detectChapterLevel_picks_smallest_level_with_two_occurrences() {
        // 1 H1 + 5 H2 → level 2.
        let h1WithH2s: [Block] = [
            .heading(level: 1, runs: [InlineRun("Title Page")]),
        ] + (1...5).map {
            Block.heading(level: 2, runs: [InlineRun("Section \($0)")])
        }
        XCTAssertEqual(ChapterSplitter.detectChapterLevel(in: h1WithH2s), 2)

        // 3 H1 + 5 H2 → level 1.
        let h1Heavy: [Block] = (1...3).map {
            Block.heading(level: 1, runs: [InlineRun("Chapter \($0)")])
        } + (1...5).map {
            Block.heading(level: 2, runs: [InlineRun("Section \($0)")])
        }
        XCTAssertEqual(ChapterSplitter.detectChapterLevel(in: h1Heavy), 1)

        // No headings at all → fallback to 1.
        XCTAssertEqual(ChapterSplitter.detectChapterLevel(in: []), 1)
    }

    // MARK: - chapter-break eligibility gates

    /// Drop caps come back from layout as 1-character `.sectionHeader`
    /// regions; those should never open a new chapter.
    func test_drop_cap_heading_does_not_open_chapter() {
        let blocks: [Block] = [
            .heading(level: 2, runs: [InlineRun("Real Chapter One")]),
            .paragraph(runs: [InlineRun("Body of chapter one.")]),
            // Drop cap: real chapter starts with a large "T" labelled
            // as a heading by Surya, then the body continues.
            .heading(level: 2, runs: [InlineRun("T")]),
            .paragraph(runs: [InlineRun("he chapter body continues here.")]),
            .heading(level: 2, runs: [InlineRun("Real Chapter Two")]),
            .paragraph(runs: [InlineRun("Body of chapter two.")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters.count, 2,
            "Drop-cap heading must not produce a third chapter")
        XCTAssertEqual(chapters[0].title, "Real Chapter One")
        XCTAssertEqual(chapters[1].title, "Real Chapter Two")
    }

    /// Body fragments mis-promoted to headings (lowercase-first,
    /// mid-sentence text) should not open a new chapter. Mirrors the
    /// "ing, with all the humanly possible…" failure on Husserl.
    func test_lowercase_start_heading_does_not_open_chapter() {
        let blocks: [Block] = [
            .heading(level: 2, runs: [InlineRun("Real Chapter One")]),
            .paragraph(runs: [InlineRun("Body.")]),
            .heading(level: 2, runs: [InlineRun(
                "ing, with all the humanly possible expenditure of energy."
            )]),
            .paragraph(runs: [InlineRun("More body.")]),
            .heading(level: 2, runs: [InlineRun("Real Chapter Two")]),
            .paragraph(runs: [InlineRun("Body two.")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters.count, 2,
            "Lowercase-start heading must not open a chapter")
    }

    /// Multi-sentence "headings" (real body text) should not open a
    /// chapter — the mid-text sentence terminator gate.
    func test_multi_sentence_heading_does_not_open_chapter() {
        let blocks: [Block] = [
            .heading(level: 2, runs: [InlineRun("First Real Chapter")]),
            .paragraph(runs: [InlineRun("Body.")]),
            .heading(level: 2, runs: [InlineRun(
                "He nodded. Then he left."
            )]),
            .paragraph(runs: [InlineRun("More body.")]),
            .heading(level: 2, runs: [InlineRun("Second Real Chapter")]),
            .paragraph(runs: [InlineRun("Body two.")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters.count, 2,
            "Multi-sentence heading must not open a chapter")
    }

    /// A heading text repeated ≥ `maxChapterHeadingRepetition` times
    /// across the document is a running head, not a chapter break.
    func test_repeated_running_head_does_not_open_chapter() {
        // Five "INTRODUCTION" running heads + two real chapters.
        var blocks: [Block] = [
            .heading(level: 2, runs: [InlineRun("Real Chapter One")]),
            .paragraph(runs: [InlineRun("Chapter one body.")]),
        ]
        for _ in 0..<5 {
            blocks.append(.heading(level: 2, runs: [InlineRun("INTRODUCTION")]))
            blocks.append(.paragraph(runs: [InlineRun("Filler line.")]))
        }
        blocks.append(.heading(level: 2, runs: [InlineRun("Real Chapter Two")]))
        blocks.append(.paragraph(runs: [InlineRun("Chapter two body.")]))

        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters.count, 2,
            "Repeated running head must not open chapters")
        XCTAssertEqual(chapters[0].title, "Real Chapter One")
        XCTAssertEqual(chapters[1].title, "Real Chapter Two")
    }

    /// Two repetitions are still acceptable — a multi-part book might
    /// legitimately have two "Notes" chapters (one per part).
    func test_two_repetitions_still_allowed() {
        let blocks: [Block] = [
            .heading(level: 2, runs: [InlineRun("Notes")]),
            .paragraph(runs: [InlineRun("First notes section.")]),
            .heading(level: 2, runs: [InlineRun("Other Real Chapter")]),
            .paragraph(runs: [InlineRun("Body.")]),
            .heading(level: 2, runs: [InlineRun("Notes")]),
            .paragraph(runs: [InlineRun("Second notes section.")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters.count, 3,
            "Two repetitions of a heading are still chapter-eligible")
    }

    /// Numerals + section symbols + opening quotes count as valid
    /// chapter starts (not lowercase letters). Sanity check that the
    /// first-char gate is loose enough.
    func test_non_lowercase_first_chars_open_chapter() {
        let blocks: [Block] = [
            .heading(level: 2, runs: [InlineRun("§ 1 Logic")]),
            .paragraph(runs: [InlineRun("Body of §1.")]),
            .heading(level: 2, runs: [InlineRun("1. Antitheses")]),
            .paragraph(runs: [InlineRun("Body of 1.")]),
            .heading(level: 2, runs: [InlineRun("\"Quoted Title\"")]),
            .paragraph(runs: [InlineRun("Body of quoted.")]),
        ]
        let chapters = ChapterSplitter.split(
            blocks: blocks, footnotes: [], pageAnchors: [],
            bookFallbackTitle: "Book"
        )
        XCTAssertEqual(chapters.count, 3,
            "§, digits, and opening quotes are all valid chapter starts")
    }
}
