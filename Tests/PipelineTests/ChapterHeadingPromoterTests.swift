import XCTest
import Document
@testable import Pipeline

/// `ChapterHeadingPromoter` coverage. Two layers exercised:
///   1. The marker / title heuristics in isolation (matchesMarker,
///      looksLikeTitle).
///   2. End-to-end `promote(blocks:)` over representative input
///      shapes — the Weber-style "CHAPTER 1" + ALL-CAPS title fuse,
///      the false-positive "Chapter House" rejection, the running-
///      head suppression, the standalone-marker-only path.
final class ChapterHeadingPromoterTests: XCTestCase {

    // MARK: - matchesMarker

    func test_matchesMarker_accepts_uppercase_chapter_with_arabic() {
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("CHAPTER 1"))
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("CHAPTER 12"))
    }

    func test_matchesMarker_accepts_uppercase_chapter_with_roman() {
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("CHAPTER II"))
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("CHAPTER XVIII"))
    }

    func test_matchesMarker_accepts_titlecase_chapter() {
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("Chapter 1"))
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("Chapter II"))
    }

    func test_matchesMarker_accepts_spelled_chapter_numerals() {
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("Chapter One"))
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("Chapter Ten"))
    }

    func test_matchesMarker_accepts_part_and_book_markers() {
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("PART ONE"))
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("Part I"))
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("Book One"))
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("BOOK II"))
    }

    func test_matchesMarker_accepts_roman_numeral_prefix() {
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("I. INTRODUCTION"))
        XCTAssertTrue(ChapterHeadingPromoter.matchesMarker("II. The Method"))
    }

    func test_matchesMarker_rejects_bare_chapter_word() {
        // No numeral after "Chapter" — common running-head shape
        // that must not be promoted.
        XCTAssertFalse(ChapterHeadingPromoter.matchesMarker("Chapter"))
        XCTAssertFalse(ChapterHeadingPromoter.matchesMarker("CHAPTER"))
    }

    func test_matchesMarker_rejects_inline_chapter_reference() {
        // Body sentence that happens to start with "Chapter".
        XCTAssertFalse(ChapterHeadingPromoter.matchesMarker(
            "Chapter discusses this in detail."
        ))
    }

    func test_matchesMarker_rejects_chapter_house() {
        // False positive guard: a place named "Chapter House" must
        // not register as a chapter marker.
        XCTAssertFalse(ChapterHeadingPromoter.matchesMarker("Chapter House"))
    }

    // MARK: - looksLikeTitle

    func test_looksLikeTitle_accepts_all_caps_title() {
        XCTAssertTrue(ChapterHeadingPromoter.looksLikeTitle(
            "BASIC SOCIOLOGICAL TERMS"
        ))
    }

    func test_looksLikeTitle_accepts_title_case() {
        XCTAssertTrue(ChapterHeadingPromoter.looksLikeTitle(
            "The Types of Legitimate Domination"
        ))
    }

    func test_looksLikeTitle_rejects_lowercase_first_letter() {
        XCTAssertFalse(ChapterHeadingPromoter.looksLikeTitle(
            "the rest of the sentence here"
        ))
    }

    func test_looksLikeTitle_rejects_multi_sentence_body() {
        // Sentence-terminator past offset 6 = body text Surya
        // mis-classified.
        XCTAssertFalse(ChapterHeadingPromoter.looksLikeTitle(
            "He nodded. Then he left."
        ))
    }

    // MARK: - promote, end to end

    func test_promote_fuses_marker_with_following_title() {
        // The exact Weber case: "CHAPTER 1" + "BASIC SOCIOLOGICAL
        // TERMS." adjacent as paragraphs. After promotion: one H2.
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun("CHAPTER 1")]),
            .paragraph(runs: [InlineRun("BASIC SOCIOLOGICAL TERMS.")]),
            .paragraph(runs: [InlineRun("Prefatory Note")]),
        ]
        let result = ChapterHeadingPromoter.promote(blocks: blocks)
        XCTAssertEqual(result.blocks.count, 2)
        guard case .heading(let level, let runs) = result.blocks[0] else {
            return XCTFail("First block should be a heading after promotion")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(
            runs.map(\.text).joined(),
            "CHAPTER 1: BASIC SOCIOLOGICAL TERMS."
        )
        guard case .paragraph(let p2Runs) = result.blocks[1] else {
            return XCTFail("Second block should still be a paragraph")
        }
        XCTAssertEqual(p2Runs.map(\.text).joined(), "Prefatory Note")
        XCTAssertEqual(result.diagnostics.promotions.count, 1)
        XCTAssertEqual(
            result.diagnostics.promotions.first?.fusedTitle,
            "BASIC SOCIOLOGICAL TERMS."
        )
    }

    func test_promote_emits_marker_only_when_next_block_not_title_shaped() {
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun("CHAPTER 1")]),
            .paragraph(runs: [InlineRun(
                "the chapter opens with a long sentence here."
            )]),
        ]
        let result = ChapterHeadingPromoter.promote(blocks: blocks)
        XCTAssertEqual(result.blocks.count, 2)
        guard case .heading(_, let runs) = result.blocks[0] else {
            return XCTFail("First block should be promoted")
        }
        XCTAssertEqual(runs.map(\.text).joined(), "CHAPTER 1")
        // Body paragraph untouched.
        if case .paragraph(let bodyRuns) = result.blocks[1] {
            XCTAssertEqual(
                bodyRuns.map(\.text).joined(),
                "the chapter opens with a long sentence here."
            )
        } else {
            XCTFail("Second block should remain a paragraph")
        }
        XCTAssertNil(result.diagnostics.promotions.first?.fusedTitle)
    }

    func test_promote_preserves_anchors_between_marker_and_title() {
        // Real pipelines interleave page anchors at chapter
        // boundaries; the promoter must look past them to find the
        // fusion title and emit them after the heading in the same
        // order.
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun("CHAPTER 1")]),
            .anchor(id: "p-100", label: "100"),
            .paragraph(runs: [InlineRun("BASIC SOCIOLOGICAL TERMS")]),
            .paragraph(runs: [InlineRun("Body.")]),
        ]
        let result = ChapterHeadingPromoter.promote(blocks: blocks)
        XCTAssertEqual(result.blocks.count, 3)
        guard case .heading(_, let runs) = result.blocks[0] else {
            return XCTFail("Heading expected")
        }
        XCTAssertEqual(
            runs.map(\.text).joined(),
            "CHAPTER 1: BASIC SOCIOLOGICAL TERMS"
        )
        if case .anchor(let id, _) = result.blocks[1] {
            XCTAssertEqual(id, "p-100")
        } else {
            XCTFail("Anchor should follow the heading")
        }
    }

    func test_promote_skips_repeated_markers_treated_as_running_heads() {
        // Same marker text appearing > maxMarkerRepetition times
        // is a running head, not a real chapter break. The
        // promoter must leave them as paragraphs so they don't
        // pollute the heading set and trick ChapterSplitter.
        var blocks: [Block] = []
        for _ in 0..<(ChapterHeadingPromoter.maxMarkerRepetition + 1) {
            blocks.append(.paragraph(runs: [InlineRun("CHAPTER 1")]))
            blocks.append(.paragraph(runs: [InlineRun("Some body text here.")]))
        }
        let result = ChapterHeadingPromoter.promote(blocks: blocks)
        // No promotions at all when the marker is too repetitive.
        let headings = result.blocks.filter {
            if case .heading = $0 { return true }
            return false
        }
        XCTAssertTrue(headings.isEmpty,
            "Repeated marker should not promote — running-head pattern")
        XCTAssertEqual(result.diagnostics.promotions.count, 0)
    }

    func test_promote_does_not_fuse_two_adjacent_markers() {
        // Two consecutive markers (PART ONE / CHAPTER 1) should
        // each get their own heading; the second must not be
        // consumed by the first's fusion lookahead.
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun("PART ONE")]),
            .paragraph(runs: [InlineRun("CHAPTER 1")]),
            .paragraph(runs: [InlineRun("THE THEORY")]),
        ]
        let result = ChapterHeadingPromoter.promote(blocks: blocks)
        // PART ONE → heading (no fusion because next is also a marker)
        // CHAPTER 1 → heading (fused with THE THEORY)
        XCTAssertEqual(result.blocks.count, 2)
        if case .heading(_, let r0) = result.blocks[0] {
            XCTAssertEqual(r0.map(\.text).joined(), "PART ONE")
        } else { XCTFail("First block should be a heading") }
        if case .heading(_, let r1) = result.blocks[1] {
            XCTAssertEqual(
                r1.map(\.text).joined(),
                "CHAPTER 1: THE THEORY"
            )
        } else { XCTFail("Second block should be a heading") }
    }

    func test_promote_leaves_existing_headings_alone() {
        // Already-promoted blocks (e.g. from Surya .sectionHeader)
        // pass through untouched and don't count as paragraphs
        // scanned.
        let blocks: [Block] = [
            .heading(level: 2, runs: [InlineRun("Existing Heading")]),
            .paragraph(runs: [InlineRun("Body.")]),
        ]
        let result = ChapterHeadingPromoter.promote(blocks: blocks)
        XCTAssertEqual(result.blocks, blocks)
        XCTAssertEqual(result.diagnostics.paragraphsScanned, 1)
        XCTAssertEqual(result.diagnostics.promotions.count, 0)
    }

    // MARK: - integration with ChapterSplitter

    func test_promoter_plus_splitter_produces_multi_chapter_weber_shape() {
        // End-to-end: input mimics the Weber EPUB's body shape —
        // CHAPTER 1 / TITLE / body / page anchor / CHAPTER II /
        // TITLE / body. After promoter + splitter, we should see
        // two chapters with the fused titles.
        let blocks: [Block] = [
            .paragraph(runs: [InlineRun("Front matter prose.")]),
            .paragraph(runs: [InlineRun("CHAPTER 1")]),
            .paragraph(runs: [InlineRun("BASIC SOCIOLOGICAL TERMS")]),
            .paragraph(runs: [InlineRun("First chapter body.")]),
            .paragraph(runs: [InlineRun("CHAPTER II")]),
            .paragraph(runs: [InlineRun("SOCIOLOGICAL CATEGORIES")]),
            .paragraph(runs: [InlineRun("Second chapter body.")]),
        ]
        let promotion = ChapterHeadingPromoter.promote(blocks: blocks)
        let result = ChapterSplitter.splitWithDiagnostics(
            blocks: promotion.blocks,
            footnotes: [], pageAnchors: [], figureAssets: [],
            bookFallbackTitle: "Weber"
        )
        XCTAssertEqual(result.chapters.count, 3,
            "front matter + two body chapters")
        XCTAssertEqual(result.chapters[0].title, "Front Matter")
        XCTAssertEqual(
            result.chapters[1].title,
            "CHAPTER 1: BASIC SOCIOLOGICAL TERMS"
        )
        XCTAssertEqual(
            result.chapters[2].title,
            "CHAPTER II: SOCIOLOGICAL CATEGORIES"
        )
        XCTAssertFalse(result.diagnostics.degenerateFallbackUsed)
        XCTAssertEqual(result.diagnostics.eligibleBreakCount, 2)
    }
}
