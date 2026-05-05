import XCTest
import Document
import EPUB
@testable import Pipeline

/// `ClaudeTOCParser` (response parsing + array extraction) and
/// `TOCTitleApplier` (offset learning + title override) unit tests.
/// `TOCPageDetector` and the live API path are covered separately
/// (the latter would need a network mock — same `MockTransport`
/// pattern as `ClaudePostProcessorTests`; deferred until the live
/// path proves out empirically).
final class ClaudeTOCParserTests: XCTestCase {

    // MARK: - parseResponse

    func test_parse_plain_json_array() {
        let raw = """
        [{"title":"Chapter 1","displayPage":"1"},
         {"title":"Chapter 2","displayPage":"23"}]
        """
        guard let toc = ClaudeTOCParser.parseResponse(raw) else {
            return XCTFail("parseResponse returned nil")
        }
        XCTAssertEqual(toc.entries.count, 2)
        XCTAssertEqual(toc.entries[0].title, "Chapter 1")
        XCTAssertEqual(toc.entries[1].displayPage, "23")
    }

    func test_parse_strips_code_fences() {
        let raw = """
        ```json
        [{"title":"Preface","displayPage":"vii"}]
        ```
        """
        let toc = ClaudeTOCParser.parseResponse(raw)
        XCTAssertEqual(toc?.entries.count, 1)
        XCTAssertEqual(toc?.entries[0].title, "Preface")
        XCTAssertEqual(toc?.entries[0].displayPage, "vii")
    }

    func test_parse_handles_prefix_commentary() {
        // Haiku occasionally prefixes "Here is the parsed TOC:" or
        // similar despite the system prompt — the array extractor
        // should pick up the first balanced [ ... ] anyway.
        let raw = """
        Here is the parsed TOC:
        [{"title":"Body","displayPage":"1"}]
        """
        XCTAssertEqual(
            ClaudeTOCParser.parseResponse(raw)?.entries.count, 1
        )
    }

    func test_parse_accepts_int_displayPage() {
        // Haiku sometimes returns displayPage as a JSON number even
        // when the prompt asks for a string. The DTO tolerates both.
        let raw = #"[{"title":"Chapter 1","displayPage":1}]"#
        let toc = ClaudeTOCParser.parseResponse(raw)
        XCTAssertEqual(toc?.entries[0].displayPage, "1")
    }

    func test_parse_returns_nil_on_malformed_json() {
        XCTAssertNil(ClaudeTOCParser.parseResponse("not JSON at all"))
        XCTAssertNil(ClaudeTOCParser.parseResponse("[invalid:"))
    }

    func test_parse_drops_empty_titles() {
        let raw = """
        [{"title":"","displayPage":"1"},
         {"title":"Real Title","displayPage":"2"}]
        """
        let toc = ClaudeTOCParser.parseResponse(raw)
        XCTAssertEqual(toc?.entries.count, 1)
        XCTAssertEqual(toc?.entries[0].title, "Real Title")
    }

    func test_parse_returns_nil_when_no_valid_entries() {
        let raw = #"[{"title":"","displayPage":""}]"#
        XCTAssertNil(ClaudeTOCParser.parseResponse(raw))
    }

    // MARK: - extractFirstArray

    func test_extractFirstArray_returns_first_balanced_array() {
        let s = "preamble [{\"a\":1},{\"b\":2}] trailing"
        XCTAssertEqual(
            ClaudeTOCParser.extractFirstArray(s),
            "[{\"a\":1},{\"b\":2}]"
        )
    }

    func test_extractFirstArray_handles_nested_arrays() {
        let s = "[1, [2, 3], 4] tail"
        XCTAssertEqual(
            ClaudeTOCParser.extractFirstArray(s),
            "[1, [2, 3], 4]"
        )
    }

    func test_extractFirstArray_ignores_brackets_in_strings() {
        // Strings inside the JSON might contain `[` or `]` — the
        // extractor's depth counter must skip those.
        let s = "[\"text with [bracket]\"]"
        XCTAssertEqual(
            ClaudeTOCParser.extractFirstArray(s),
            "[\"text with [bracket]\"]"
        )
    }

    func test_extractFirstArray_returns_nil_for_unbalanced() {
        XCTAssertNil(ClaudeTOCParser.extractFirstArray("[unclosed"))
        XCTAssertNil(ClaudeTOCParser.extractFirstArray("no array here"))
    }

    // MARK: - TOCTitleApplier

    private func makeChapter(title: String, pdfPages: [Int]) -> Chapter {
        Chapter(
            title: title,
            blocks: [],
            footnotes: [],
            pageAnchors: pdfPages.map {
                PageAnchor(pdfPage: $0, anchorId: "hu-page-\($0)")
            },
            figureAssets: []
        )
    }

    func test_offset_zero_applies_titles_when_pages_match() {
        // TOC says "Body … 1"; Chapter starts at PDF page 0
        // (display page 1 maps to PDF index 0 with offset 0).
        let toc = ParsedTOC(entries: [
            ParsedTOC.Entry(title: "Body", displayPage: "1"),
            ParsedTOC.Entry(title: "Conclusion", displayPage: "23"),
        ])
        let chapters = [
            makeChapter(title: "Chapter 1", pdfPages: [0, 1, 2]),
            makeChapter(title: "Chapter 2", pdfPages: [22, 23, 24]),
        ]
        let outcome = TOCTitleApplier.apply(toc: toc, chapters: chapters)
        XCTAssertEqual(outcome.inferredOffset, 0)
        XCTAssertEqual(outcome.chapters[0].title, "Body")
        XCTAssertEqual(outcome.chapters[1].title, "Conclusion")
    }

    func test_offset_inferred_from_front_matter() {
        // Front matter is 18 pages (i…xviii). TOC says "Body … 1"
        // and Chapter 1 starts at PDF page 18 (display 1 + offset
        // 18 - 1 = 18).
        let toc = ParsedTOC(entries: [
            ParsedTOC.Entry(title: "The Reign of Hadrian", displayPage: "1"),
            ParsedTOC.Entry(title: "The Reign of Antoninus", displayPage: "53"),
        ])
        let chapters = [
            makeChapter(title: "Chapter 1", pdfPages: [18, 19, 20]),
            makeChapter(title: "Chapter 2", pdfPages: [70, 71]),
        ]
        let outcome = TOCTitleApplier.apply(toc: toc, chapters: chapters)
        XCTAssertEqual(outcome.inferredOffset, 18)
        XCTAssertEqual(outcome.chapters[0].title, "The Reign of Hadrian")
        XCTAssertEqual(outcome.chapters[1].title, "The Reign of Antoninus")
    }

    func test_no_match_leaves_titles_intact() {
        // TOC pages don't line up with chapter starts under any
        // candidate offset. Don't override — safer to keep the
        // heuristic titles than apply a misaligned TOC.
        let toc = ParsedTOC(entries: [
            ParsedTOC.Entry(title: "Body", displayPage: "100"),
            ParsedTOC.Entry(title: "End", displayPage: "200"),
        ])
        let chapters = [
            makeChapter(title: "Chapter 1", pdfPages: [0, 1, 2]),
            makeChapter(title: "Chapter 2", pdfPages: [3, 4]),
        ]
        let outcome = TOCTitleApplier.apply(toc: toc, chapters: chapters)
        XCTAssertNil(outcome.inferredOffset)
        XCTAssertEqual(outcome.chapters[0].title, "Chapter 1")
        XCTAssertEqual(outcome.chapters[1].title, "Chapter 2")
    }

    func test_roman_numeral_entries_are_skipped_for_offset_learning() {
        // Front-matter entries with roman-numeral display pages
        // can't participate in offset arithmetic — they're dropped
        // from learning. Arithmetic happens on the arabic-numeral
        // entries; we want enough of those to disambiguate the
        // offset (a single arabic entry can match at multiple
        // candidate offsets, so add two whose distance lines up
        // unambiguously with the chapter starts).
        let toc = ParsedTOC(entries: [
            ParsedTOC.Entry(title: "Preface", displayPage: "vii"),
            ParsedTOC.Entry(title: "Body", displayPage: "1"),
            ParsedTOC.Entry(title: "Conclusion", displayPage: "41"),
        ])
        let chapters = [
            makeChapter(title: "Front Matter", pdfPages: [0, 1, 2]),
            makeChapter(title: "Chapter 1", pdfPages: [10, 11, 12]),
            makeChapter(title: "Chapter 2", pdfPages: [50, 51]),
        ]
        let outcome = TOCTitleApplier.apply(toc: toc, chapters: chapters)
        XCTAssertEqual(outcome.inferredOffset, 10)
        XCTAssertEqual(outcome.chapters[1].title, "Body")
        XCTAssertEqual(outcome.chapters[2].title, "Conclusion")
    }

    // MARK: - TOCPageDetector.scorePage

    func test_scorePage_recognizes_explicit_header() {
        let text = """
        Table of Contents

        Chapter 1: Introduction ............ 1
        Chapter 2: Methods .................. 23
        Chapter 3: Results .................. 45
        Chapter 4: Discussion ............... 67
        Chapter 5: Conclusion ............... 89
        """
        XCTAssertGreaterThanOrEqual(
            TOCPageDetector.scorePage(text),
            TOCPageDetector.minTOCPageScore
        )
    }

    func test_scorePage_rejects_plain_body_text() {
        let text = """
        This is just an ordinary page of body text. It contains
        sentences with periods, but no page-number leaders, and
        no headers. The detector should not flag it.
        """
        XCTAssertLessThan(
            TOCPageDetector.scorePage(text),
            TOCPageDetector.minTOCPageScore
        )
    }

    func test_scorePage_recognizes_dot_leader_density_alone() {
        // No "Contents" header, but lots of dot-leader lines —
        // still a TOC.
        let text = """
        Introduction ........................ 1
        The Origins ......................... 23
        The Decline ......................... 45
        The Aftermath ....................... 67
        Index ............................... 89
        """
        XCTAssertGreaterThanOrEqual(
            TOCPageDetector.scorePage(text),
            TOCPageDetector.minTOCPageScore
        )
    }
}
