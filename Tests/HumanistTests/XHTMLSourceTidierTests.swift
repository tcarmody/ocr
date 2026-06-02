import XCTest
@testable import Humanist

/// Pins the inline-vs-block contract of the source tidy pass. The
/// regression that motivated it: Foundation's `.nodePrettyPrint`
/// broke `<em>`, `<strong>`, `<sup>`, … onto their own lines and
/// shoved whitespace between a closing inline tag and the punctuation
/// that should hug it.
final class XHTMLSourceTidierTests: XCTestCase {

    private func tidy(_ s: String) -> String {
        let outcome = XHTMLSourceTidier.tidy(s)
        XCTAssertNil(outcome.error, "unexpected parse error")
        return outcome.text ?? ""
    }

    func test_inline_tags_stay_glued_to_punctuation() {
        let src = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>\
        <p>He said <em>hello</em>, then <strong>left</strong>. \
        A word<sup>1</sup> and <i>more</i>; done.</p></body></html>
        """
        let out = tidy(src)
        // The whole paragraph lands on one line — no inline breaks.
        XCTAssertTrue(
            out.contains("<p>He said <em>hello</em>, then <strong>left</strong>. A word<sup>1</sup> and <i>more</i>; done.</p>"),
            out
        )
        // And none of the punctuation grew a leading space.
        XCTAssertFalse(out.contains("</em>\n"))
        XCTAssertFalse(out.contains("</strong>\n"))
        XCTAssertFalse(out.contains("</sup>\n"))
        XCTAssertFalse(out.contains("</em> ,"))
        XCTAssertFalse(out.contains("</strong> ."))
    }

    func test_block_structure_is_indented() {
        let src = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>\
        <div><p>One</p><blockquote><p>Two</p></blockquote></div></body></html>
        """
        let out = tidy(src)
        XCTAssertTrue(out.contains("\n    <body>"), out)
        XCTAssertTrue(out.contains("\n        <div>"), out)
        XCTAssertTrue(out.contains("\n            <p>One</p>"), out)
        XCTAssertTrue(out.contains("\n            <blockquote>"), out)
        XCTAssertTrue(out.contains("\n                <p>Two</p>"), out)
    }

    func test_glued_superscript_without_space_is_preserved() {
        let src = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><p>word<sup>1</sup>next</p></body></html>
        """
        XCTAssertTrue(tidy(src).contains("<p>word<sup>1</sup>next</p>"))
    }

    func test_pre_block_content_survives_verbatim() {
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>"
            + "<pre>a\n  b\n    c</pre></body></html>"
        XCTAssertTrue(tidy(body).contains("<pre>a\n  b\n    c</pre>"), tidy(body))
    }

    func test_attributes_with_special_chars_round_trip() {
        let src = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>\
        <div class="a&amp;b" data-x="1&gt;2"><p>Hi <a href="x?y=1&amp;z=2">link</a>.</p></div></body></html>
        """
        let out = tidy(src)
        XCTAssertTrue(out.contains("<div class=\"a&amp;b\" data-x=\"1&gt;2\">"), out)
        XCTAssertTrue(out.contains("<p>Hi <a href=\"x?y=1&amp;z=2\">link</a>.</p>"), out)
    }

    func test_malformed_source_reports_error_and_no_text() {
        let outcome = XHTMLSourceTidier.tidy("<p>unclosed")
        XCTAssertNotNil(outcome.error)
        XCTAssertNil(outcome.text)
    }

    func test_empty_source_is_noop() {
        let outcome = XHTMLSourceTidier.tidy("")
        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.error)
    }
}
