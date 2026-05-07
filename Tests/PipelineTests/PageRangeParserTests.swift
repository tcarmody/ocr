import XCTest
@testable import Pipeline

/// `PageRangeParser` parses user-typed 1-based page-range strings
/// to 0-indexed `ClosedRange<Int>` arrays. Resilience over
/// strictness — typos in one token shouldn't lose the rest.
final class PageRangeParserTests: XCTestCase {

    // MARK: - parse

    func test_parse_empty_string_returns_empty_array() {
        XCTAssertEqual(PageRangeParser.parse(""), [])
        XCTAssertEqual(PageRangeParser.parse("   "), [])
    }

    func test_parse_single_page_token() {
        XCTAssertEqual(PageRangeParser.parse("5"), [4...4])
    }

    func test_parse_single_range_converts_one_based_to_zero_based() {
        XCTAssertEqual(PageRangeParser.parse("1-20"), [0...19])
    }

    func test_parse_multiple_tokens_joined_by_commas() {
        let result = PageRangeParser.parse("1-3, 10, 50-100")
        XCTAssertEqual(result, [0...2, 9...9, 49...99])
    }

    func test_parse_tolerates_whitespace_around_dashes_and_commas() {
        let result = PageRangeParser.parse(" 1 - 3 ,  10 ,  50 - 100  ")
        XCTAssertEqual(result, [0...2, 9...9, 49...99])
    }

    func test_parse_skips_malformed_tokens_silently() {
        // "abc" is non-numeric, "10-5" is reversed, "0" is below
        // 1-based floor — all skipped; valid tokens survive.
        let result = PageRangeParser.parse("1-3, abc, 10-5, 0, 7")
        XCTAssertEqual(result, [0...2, 6...6])
    }

    func test_parse_skips_negative_or_zero_values() {
        XCTAssertEqual(PageRangeParser.parse("-5"), [],
            "negative single skipped")
        XCTAssertEqual(PageRangeParser.parse("0"), [],
            "0 skipped (1-based floor)")
        XCTAssertEqual(PageRangeParser.parse("0-5"), [],
            "range starting at 0 skipped")
    }

    func test_parse_handles_single_page_in_range_form() {
        // "5-5" is a degenerate range → single page.
        XCTAssertEqual(PageRangeParser.parse("5-5"), [4...4])
    }

    func test_parse_does_not_merge_overlapping_ranges() {
        // Adjacent / overlapping ranges compose additively in
        // .contains; we don't bother merging at parse time.
        let result = PageRangeParser.parse("1-5, 3-10")
        XCTAssertEqual(result, [0...4, 2...9])
    }

    // MARK: - format (round-trip)

    func test_format_single_page_range() {
        XCTAssertEqual(PageRangeParser.format([4...4]), "5")
    }

    func test_format_multi_page_range() {
        XCTAssertEqual(PageRangeParser.format([0...19]), "1-20")
    }

    func test_format_multiple_ranges_joined_by_commas() {
        let formatted = PageRangeParser.format([0...2, 9...9, 49...99])
        XCTAssertEqual(formatted, "1-3, 10, 50-100")
    }

    func test_round_trip_through_parse_then_format() {
        let inputs = [
            "1-20",
            "5",
            "1-3, 10, 50-100",
            "1, 5, 10, 100",
        ]
        for input in inputs {
            let parsed = PageRangeParser.parse(input)
            let formatted = PageRangeParser.format(parsed)
            // Re-parse the formatted form and compare structures
            // (whitespace between formatter output and original
            // input may differ).
            let reparsed = PageRangeParser.parse(formatted)
            XCTAssertEqual(parsed, reparsed,
                "round-trip should be stable for input: \(input)")
        }
    }
}
