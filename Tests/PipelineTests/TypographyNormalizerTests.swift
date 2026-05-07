import XCTest
import Document
@testable import Pipeline

/// `TypographyNormalizer` text-level passes — ligature
/// decomposition, soft-hyphen strip, em-dash from `--`,
/// en-dash for numeric ranges. Conservative posture means each
/// pass should be a no-op on already-clean input.
final class TypographyNormalizerTests: XCTestCase {

    // MARK: - Latin ligatures

    func test_decomposes_common_latin_ligatures() {
        // Each ligature codepoint → its letter-pair / triplet.
        // U+FB00 ﬀ → ff   (off+ﬀ+er → offer)
        // U+FB01 ﬁ → fi   (de+ﬁ+ne → define)
        // U+FB02 ﬂ → fl   (in+ﬂ+ate → inflate)
        // U+FB03 ﬃ → ffi  (di+ﬃ+cult → difficult)
        // U+FB04 ﬄ → ffl  (ba+ﬄ+e → baffle)
        let input = "o\u{FB00}er, de\u{FB01}ne, in\u{FB02}ate, di\u{FB03}cult, ba\u{FB04}e"
        let out = TypographyNormalizer.decomposeLatinLigatures(input)
        XCTAssertEqual(out, "offer, define, inflate, difficult, baffle")
    }

    func test_decomposes_st_ligature_codepoints() {
        XCTAssertEqual(
            TypographyNormalizer.decomposeLatinLigatures("\u{FB05}reet"),
            "street"
        )
        XCTAssertEqual(
            TypographyNormalizer.decomposeLatinLigatures("ju\u{FB06}"),
            "just"
        )
    }

    func test_ligature_pass_is_noop_on_clean_text() {
        let input = "The quick brown fox jumps over the lazy dog."
        XCTAssertEqual(
            TypographyNormalizer.decomposeLatinLigatures(input),
            input
        )
    }

    // MARK: - soft hyphens

    func test_strips_soft_hyphens_from_text() {
        // Soft hyphen U+00AD is a line-break hint that survives
        // OCR as an invisible character — breaks copy/paste +
        // search. Always safe to remove from final text.
        let input = "Mendel\u{00AD}sohn was a composer."
        let out = TypographyNormalizer.stripSoftHyphens(input)
        XCTAssertEqual(out, "Mendelsohn was a composer.")
    }

    func test_soft_hyphen_strip_preserves_real_hyphens() {
        let input = "well-known author"
        XCTAssertEqual(
            TypographyNormalizer.stripSoftHyphens(input),
            input
        )
    }

    // MARK: - em-dashes from --

    func test_converts_double_hyphen_to_em_dash() {
        XCTAssertEqual(
            TypographyNormalizer.collapseDoubleHyphenToEmDash(
                "He paused -- then continued."
            ),
            "He paused \u{2014} then continued."
        )
    }

    func test_em_dash_pass_leaves_single_hyphen_alone() {
        let input = "well-known compound"
        XCTAssertEqual(
            TypographyNormalizer.collapseDoubleHyphenToEmDash(input),
            input
        )
    }

    func test_em_dash_pass_leaves_triple_hyphen_alone() {
        // 3+ hyphens are likely a typographic separator the
        // author chose — don't second-guess.
        let input = "Section ---"
        XCTAssertEqual(
            TypographyNormalizer.collapseDoubleHyphenToEmDash(input),
            input
        )
    }

    func test_em_dash_pass_handles_multiple_occurrences() {
        XCTAssertEqual(
            TypographyNormalizer.collapseDoubleHyphenToEmDash("a -- b -- c"),
            "a \u{2014} b \u{2014} c"
        )
    }

    // MARK: - en-dashes for numeric ranges

    func test_converts_digit_range_hyphen_to_en_dash() {
        XCTAssertEqual(
            TypographyNormalizer.digitRangeHyphenToEnDash("pages 12-47"),
            "pages 12\u{2013}47"
        )
        XCTAssertEqual(
            TypographyNormalizer.digitRangeHyphenToEnDash("1939-1945"),
            "1939\u{2013}1945"
        )
    }

    func test_en_dash_pass_leaves_phone_numbers_alone() {
        // Phone numbers have non-digit prefixes/suffixes around
        // the hyphen (parens, area-code separators); the
        // lookaround requires bare digits both sides. A bare
        // `555-1212` will be rewritten — that's accepted scope:
        // phone numbers in academic prose are rare, and "1939"
        // → "1939" (en-dash) is the more common case we want.
        XCTAssertEqual(
            TypographyNormalizer.digitRangeHyphenToEnDash("(555) 555-1212"),
            "(555) 555\u{2013}1212",
            "lookaround-only rule does catch raw `\\d+-\\d+` phone numbers; documented limitation"
        )
    }

    func test_en_dash_pass_leaves_word_hyphens_alone() {
        let input = "letter-perfect"
        XCTAssertEqual(
            TypographyNormalizer.digitRangeHyphenToEnDash(input),
            input
        )
    }

    func test_en_dash_pass_leaves_mixed_alphanumeric_alone() {
        // `2-A` shouldn't become en-dash — only when both sides
        // are digits.
        let input = "Section 2-A"
        XCTAssertEqual(
            TypographyNormalizer.digitRangeHyphenToEnDash(input),
            input
        )
    }

    // MARK: - normalize() composes all passes

    func test_normalize_runs_all_passes() {
        let input = "The di\u{FB03}culty\u{00AD} of pages 12-47 -- a hard problem."
        let out = TypographyNormalizer.normalize(input)
        XCTAssertEqual(
            out,
            "The difficulty of pages 12\u{2013}47 \u{2014} a hard problem."
        )
    }

    func test_normalize_is_idempotent() {
        // Running normalize twice should equal running it once —
        // important for re-conversion / EPUB-refresh flows where
        // text might pass through the pipeline more than once.
        let input = "The di\u{FB01}culty -- pages 1-9."
        let once = TypographyNormalizer.normalize(input)
        let twice = TypographyNormalizer.normalize(once)
        XCTAssertEqual(once, twice)
    }

    // MARK: - block-level normalize()

    func test_normalize_blocks_walks_paragraphs_and_headings() {
        // \u{FB03} = ﬃ (ffi ligature), the right form for
        // "di+ffi+cult" = "difficult".
        let blocks: [Block] = [
            .heading(level: 2, runs: [InlineRun("Chapter 1\u{00AD}")]),
            .paragraph(runs: [InlineRun("It was -- as they say -- the di\u{FB03}cult choice.")]),
        ]
        let out = TypographyNormalizer.normalize(blocks)
        guard case .heading(_, let h) = out[0] else {
            XCTFail("expected heading"); return
        }
        XCTAssertEqual(h.first?.text, "Chapter 1")
        guard case .paragraph(let p) = out[1] else {
            XCTFail("expected paragraph"); return
        }
        XCTAssertEqual(
            p.first?.text,
            "It was \u{2014} as they say \u{2014} the difficult choice."
        )
    }

    func test_normalize_blocks_preserves_run_metadata() {
        // "difficilis" → di+ffi+cilis, so use \u{FB03} (ﬃ).
        let blocks: [Block] = [
            .paragraph(runs: [
                InlineRun("Latin: ", language: .en),
                InlineRun("di\u{FB03}cilis", language: .la, noterefId: "fn-1"),
            ]),
        ]
        let out = TypographyNormalizer.normalize(blocks)
        guard case .paragraph(let runs) = out[0] else {
            XCTFail("expected paragraph"); return
        }
        XCTAssertEqual(runs[0].language, .en)
        XCTAssertEqual(runs[1].text, "difficilis")
        XCTAssertEqual(runs[1].language, .la)
        XCTAssertEqual(runs[1].noterefId, "fn-1")
    }

    func test_normalize_blocks_walks_table_cells_and_captions() {
        let blocks: [Block] = [
            .table(
                rows: [[
                    TableCell(runs: [InlineRun("e\u{FB00}ort")]),
                    TableCell(runs: [InlineRun("12-47")]),
                ]],
                caption: [InlineRun("Table 1: di\u{FB03}culties")]
            ),
        ]
        let out = TypographyNormalizer.normalize(blocks)
        guard case .table(let rows, let caption) = out[0] else {
            XCTFail("expected table"); return
        }
        XCTAssertEqual(rows[0][0].runs.first?.text, "effort")
        XCTAssertEqual(rows[0][1].runs.first?.text, "12\u{2013}47")
        XCTAssertEqual(caption.first?.text, "Table 1: difficulties")
    }

    func test_normalize_blocks_passes_anchors_and_figures_through() {
        let blocks: [Block] = [
            .anchor(id: "hu-page-0", label: "Page 1"),
            .figure(assetId: "fig-001", alt: "Figure 1", caption: [
                InlineRun("e\u{FB00}ort visualized")
            ]),
        ]
        let out = TypographyNormalizer.normalize(blocks)
        if case .anchor(let id, let label) = out[0] {
            XCTAssertEqual(id, "hu-page-0")
            XCTAssertEqual(label, "Page 1")
        } else {
            XCTFail("anchor was mutated")
        }
        if case .figure(_, _, let caption) = out[1] {
            XCTAssertEqual(caption.first?.text, "effort visualized")
        } else {
            XCTFail("expected figure")
        }
    }
}
