import XCTest
@testable import EPUB

final class PageContentReplacerTests: XCTestCase {

    func test_replace_page_body_between_anchors() {
        let chapter = """
        <html><body>
        <span id="hu-page-0"></span>
        <p>old page 0 content</p>
        <span id="hu-page-1"></span>
        <p>page 1 content</p>
        </body></html>
        """
        let result = PageContentReplacer.replaceBody(
            of: "hu-page-0",
            in: chapter,
            with: "<p>NEW page 0</p>"
        )
        let unwrapped = try! XCTUnwrap(result)
        XCTAssertTrue(unwrapped.contains("<p>NEW page 0</p>"))
        XCTAssertFalse(unwrapped.contains("old page 0 content"))
        // Page 1 still intact.
        XCTAssertTrue(unwrapped.contains("<p>page 1 content</p>"))
        // Anchor span itself is preserved.
        XCTAssertTrue(unwrapped.contains("<span id=\"hu-page-0\""))
    }

    func test_replace_last_page_body_extends_to_body_close() {
        let chapter = """
        <html><body>
        <span id="hu-page-0"></span>
        <p>page 0</p>
        <span id="hu-page-1"></span>
        <p>old final page</p>
        </body></html>
        """
        let result = PageContentReplacer.replaceBody(
            of: "hu-page-1",
            in: chapter,
            with: "<p>NEW final</p>"
        )
        let unwrapped = try! XCTUnwrap(result)
        XCTAssertTrue(unwrapped.contains("<p>NEW final</p>"))
        XCTAssertFalse(unwrapped.contains("old final page"))
        // Closing tags preserved.
        XCTAssertTrue(unwrapped.hasSuffix("</body></html>"))
    }

    func test_unknown_anchor_returns_nil() {
        let chapter = "<html><body><span id=\"hu-page-0\"></span><p>x</p></body></html>"
        let result = PageContentReplacer.replaceBody(
            of: "hu-page-99",
            in: chapter,
            with: "<p>x</p>"
        )
        XCTAssertNil(result)
    }

    func test_handles_single_quoted_anchor_attribute() {
        let chapter = "<html><body><span id='hu-page-0'></span><p>old</p></body></html>"
        let result = PageContentReplacer.replaceBody(
            of: "hu-page-0",
            in: chapter,
            with: "<p>new</p>"
        )
        let unwrapped = try! XCTUnwrap(result)
        XCTAssertTrue(unwrapped.contains("<p>new</p>"))
    }

    func test_anchor_with_extra_attributes() {
        let chapter = """
        <html><body>
        <span class="page" id="hu-page-0" data-pdf="0"></span>
        <p>old</p>
        <span id="hu-page-1"></span>
        <p>two</p>
        </body></html>
        """
        let result = PageContentReplacer.replaceBody(
            of: "hu-page-0",
            in: chapter,
            with: "<p>new</p>"
        )
        let unwrapped = try! XCTUnwrap(result)
        XCTAssertTrue(unwrapped.contains("<p>new</p>"))
        XCTAssertTrue(unwrapped.contains("<p>two</p>"))
    }

    func test_replacement_pads_with_newlines() {
        // The splice pads the replacement with leading + trailing
        // newlines so the new content sits on its own lines rather
        // than smashed against the anchor span. (Note: matches the
        // JS implementation in CodeMirror's index.html, which replaces
        // from the first `>` after `id=` — i.e. the anchor span's
        // opening `>`. The anchor's empty `</span>` close gets
        // swallowed by the replacement; this is a known shared quirk
        // and parsers tolerate it in practice.)
        let chapter = "<body><span id=\"hu-page-0\"></span><p>old</p><span id=\"hu-page-1\"></span></body>"
        let result = PageContentReplacer.replaceBody(
            of: "hu-page-0",
            in: chapter,
            with: "<p>new</p>"
        )
        let unwrapped = try! XCTUnwrap(result)
        XCTAssertTrue(unwrapped.contains("0\">\n<p>new</p>\n<span"))
    }

    func test_replacement_strips_surrounding_whitespace_in_payload() {
        let chapter = "<body><span id=\"hu-page-0\"></span><p>old</p></body>"
        let result = PageContentReplacer.replaceBody(
            of: "hu-page-0",
            in: chapter,
            with: "\n\n  <p>new</p>  \n\n"
        )
        let unwrapped = try! XCTUnwrap(result)
        // Trimmed payload sits on its own line.
        XCTAssertTrue(unwrapped.contains("\n<p>new</p>\n"))
    }
}
