import XCTest
@testable import EPUB

final class SmartQuoterTests: XCTestCase {

    // MARK: - Plain text transforms

    func test_simple_double_quoted_phrase() {
        XCTAssertEqual(
            SmartQuoter.smartQuote("\"Hello, world.\""),
            "\u{201C}Hello, world.\u{201D}"
        )
    }

    func test_simple_single_quoted_phrase() {
        XCTAssertEqual(
            SmartQuoter.smartQuote("'Hello, world.'"),
            "\u{2018}Hello, world.\u{2019}"
        )
    }

    func test_apostrophe_inside_word_is_closing() {
        XCTAssertEqual(
            SmartQuoter.smartQuote("don't"),
            "don\u{2019}t"
        )
        XCTAssertEqual(
            SmartQuoter.smartQuote("it's the cat's"),
            "it\u{2019}s the cat\u{2019}s"
        )
    }

    func test_quote_after_open_bracket_is_opener() {
        XCTAssertEqual(
            SmartQuoter.smartQuote("(\"hello\")"),
            "(\u{201C}hello\u{201D})"
        )
    }

    func test_quote_after_period_is_closer() {
        XCTAssertEqual(
            SmartQuoter.smartQuote("Some sentence.\""),
            "Some sentence.\u{201D}"
        )
    }

    // MARK: - XHTML structure preservation

    func test_attribute_quotes_are_left_alone() {
        let xhtml = "<a href=\"https://example.com\">link</a>"
        XCTAssertEqual(SmartQuoter.smartQuote(xhtml), xhtml)
    }

    func test_attributes_with_apostrophes_left_alone() {
        let xhtml = "<a href='https://example.com'>link</a>"
        XCTAssertEqual(SmartQuoter.smartQuote(xhtml), xhtml)
    }

    func test_text_inside_paragraph_is_curlied_attributes_are_not() {
        let xhtml = "<p class=\"body\">She said, \"hi.\"</p>"
        let expected = "<p class=\"body\">She said, \u{201C}hi.\u{201D}</p>"
        XCTAssertEqual(SmartQuoter.smartQuote(xhtml), expected)
    }

    func test_mixed_content_with_inline_tags() {
        let xhtml = "<p>He said, \"it's fine\" before <em>leaving</em>.</p>"
        let expected = "<p>He said, \u{201C}it\u{2019}s fine\u{201D} before <em>leaving</em>.</p>"
        XCTAssertEqual(SmartQuoter.smartQuote(xhtml), expected)
    }

    func test_empty_input_returns_empty() {
        XCTAssertEqual(SmartQuoter.smartQuote(""), "")
    }

    func test_no_quotes_returns_unchanged() {
        let s = "Plain prose with no straight quotes anywhere."
        XCTAssertEqual(SmartQuoter.smartQuote(s), s)
    }

    func test_already_curly_quotes_are_left_alone() {
        let s = "\u{201C}Already curly\u{201D} and \u{2018}so on\u{2019}."
        XCTAssertEqual(SmartQuoter.smartQuote(s), s)
    }

    // MARK: - Edge cases

    func test_quote_at_start_of_string_is_opener() {
        XCTAssertEqual(
            SmartQuoter.smartQuote("\"opener at start\""),
            "\u{201C}opener at start\u{201D}"
        )
    }

    func test_quote_after_em_dash_is_opener() {
        XCTAssertEqual(
            SmartQuoter.smartQuote("\u{2014}\"and so it began.\""),
            "\u{2014}\u{201C}and so it began.\u{201D}"
        )
    }

    func test_doctype_and_processing_instructions_pass_through() {
        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html><body><p>"hello"</p></body></html>
        """
        let result = SmartQuoter.smartQuote(xhtml)
        // The xml + doctype quotes stay byte-stable.
        XCTAssertTrue(result.contains("<?xml version=\"1.0\""))
        XCTAssertTrue(result.contains("<!DOCTYPE html>"))
        // The text-content quotes get curlied.
        XCTAssertTrue(result.contains("\u{201C}hello\u{201D}"))
    }

    func test_html_comment_content_is_left_alone() {
        // Comments live in the inTag path so their content isn't
        // transformed — acceptable trade-off, and rare in practice.
        let xhtml = "<!-- said \"hi\" --><p>said \"hi\"</p>"
        let result = SmartQuoter.smartQuote(xhtml)
        XCTAssertTrue(result.contains("<!-- said \"hi\" -->"))
        XCTAssertTrue(result.contains("<p>said \u{201C}hi\u{201D}</p>"))
    }
}
