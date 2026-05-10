import XCTest
@testable import Pipeline

final class ParagraphAnchorInjectorTests: XCTestCase {

    func test_inject_adds_id_when_p_has_no_attributes() {
        let input = "<p>First paragraph.</p>"
        let result = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 3)
        XCTAssertEqual(result.xhtml, "<p id=\"hu-p-3-0\">First paragraph.</p>")
        XCTAssertEqual(result.paragraphsScanned, 1)
        XCTAssertEqual(result.anchorsAdded, 1)
    }

    func test_inject_preserves_existing_attributes() {
        let input = #"<p class="lead" lang="en">Hello.</p>"#
        let result = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 0)
        XCTAssertEqual(
            result.xhtml,
            #"<p id="hu-p-0-0" class="lead" lang="en">Hello.</p>"#
        )
        XCTAssertEqual(result.anchorsAdded, 1)
    }

    func test_inject_increments_paragraph_index_per_chapter() {
        let input = "<p>One.</p>\n<p>Two.</p>\n<p>Three.</p>"
        let result = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 0)
        XCTAssertTrue(result.xhtml.contains("hu-p-0-0"))
        XCTAssertTrue(result.xhtml.contains("hu-p-0-1"))
        XCTAssertTrue(result.xhtml.contains("hu-p-0-2"))
        XCTAssertEqual(result.paragraphsScanned, 3)
        XCTAssertEqual(result.anchorsAdded, 3)
    }

    func test_inject_skips_p_with_existing_id() {
        // Already-anchored `<p>` (Humanist or otherwise) must not be
        // rewritten — idempotent re-import is the whole point.
        let input = #"<p id="foo">Skip me.</p>"#
        let result = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 0)
        XCTAssertEqual(result.xhtml, input)
        XCTAssertEqual(result.paragraphsScanned, 1)
        XCTAssertEqual(result.anchorsAdded, 0)
    }

    func test_inject_increments_counter_even_for_skipped_p() {
        // The counter is "document order of <p>"; skipping a tagged
        // paragraph still consumes a number so a subsequent injection
        // sits at its true ordinal position.
        let input = #"<p id="keep">Tagged.</p><p>Bare.</p>"#
        let result = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 2)
        XCTAssertEqual(
            result.xhtml,
            #"<p id="keep">Tagged.</p><p id="hu-p-2-1">Bare.</p>"#
        )
        XCTAssertEqual(result.paragraphsScanned, 2)
        XCTAssertEqual(result.anchorsAdded, 1)
    }

    func test_inject_is_idempotent_on_second_run() {
        let input = "<p>One.</p><p>Two.</p>"
        let pass1 = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 5)
        let pass2 = ParagraphAnchorInjector.inject(xhtml: pass1.xhtml, chapterIndex: 5)
        XCTAssertEqual(pass2.xhtml, pass1.xhtml,
            "second pass over an injected doc must be a no-op")
        XCTAssertEqual(pass2.anchorsAdded, 0)
    }

    func test_inject_ignores_non_p_tags_starting_with_p() {
        // `<para>`, `<picture>`, `<pre>` etc. share the leading
        // `<p` substring but aren't paragraphs. The word-boundary
        // anchor in the regex must reject them.
        let input = "<pre>code</pre><picture></picture><p>real</p>"
        let result = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 0)
        XCTAssertEqual(
            result.xhtml,
            "<pre>code</pre><picture></picture><p id=\"hu-p-0-0\">real</p>"
        )
        XCTAssertEqual(result.paragraphsScanned, 1)
        XCTAssertEqual(result.anchorsAdded, 1)
    }

    func test_inject_handles_single_quoted_id() {
        // Some publishers emit single-quoted attributes. The id
        // detector should recognize them and skip the injection.
        let input = "<p id='already'>Already.</p>"
        let result = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 0)
        XCTAssertEqual(result.xhtml, input)
        XCTAssertEqual(result.anchorsAdded, 0)
    }

    func test_inject_rejects_xml_id_lookalike() {
        // `xml:id` and `data-id` are common; they shouldn't fool the
        // existing-id detector. We want to recognize *just* the
        // bare `id=` attribute.
        let input = #"<p xml:id="ns" data-id="x">Body.</p>"#
        let result = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 0)
        XCTAssertTrue(result.xhtml.contains(#"id="hu-p-0-0""#),
            "xml:id / data-id are not the `id` attribute and must not block injection")
    }

    func test_inject_handles_case_insensitive_P() {
        // EPUB spec is XHTML (lowercase), but some inputs come from
        // HTML pipelines that mix case. Match anyway.
        let input = "<P>uppercase opener.</P>"
        let result = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 0)
        XCTAssertTrue(result.xhtml.contains(#"id="hu-p-0-0""#))
        XCTAssertEqual(result.anchorsAdded, 1)
    }

    func test_inject_uppercase_existing_ID_attribute_is_recognized() {
        let input = #"<p ID="existing">Tagged.</p>"#
        let result = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 0)
        XCTAssertEqual(result.xhtml, input)
        XCTAssertEqual(result.anchorsAdded, 0)
    }

    func test_inject_leaves_other_paragraph_elements_alone() {
        // The conversion path's XHTMLWriter only anchors `<p>`; the
        // injector must mirror that — anchoring headings or list
        // items would invent ids that the rest of the editor doesn't
        // expect to navigate via `hu-p-…`.
        let input = "<h1>Title</h1><blockquote>Quote</blockquote><li>Item</li><p>Body</p>"
        let result = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 0)
        XCTAssertFalse(result.xhtml.contains("<h1 id="))
        XCTAssertFalse(result.xhtml.contains("<blockquote id="))
        XCTAssertFalse(result.xhtml.contains("<li id="))
        XCTAssertTrue(result.xhtml.contains(#"<p id="hu-p-0-0">"#))
    }

    func test_inject_handles_attributes_with_whitespace_around_equals() {
        let input = #"<p id = "spaced">Body.</p>"#
        let result = ParagraphAnchorInjector.inject(xhtml: input, chapterIndex: 0)
        XCTAssertEqual(result.xhtml, input, "whitespace around `=` is still a valid id attribute")
        XCTAssertEqual(result.anchorsAdded, 0)
    }
}
