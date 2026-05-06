import XCTest
import Document
@testable import Pipeline

final class ClaudePageXHTMLParserTests: XCTestCase {

    // MARK: - basic structure

    func test_single_paragraph() {
        let xhtml = "<p>Hello world.</p>"
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 5)
        XCTAssertEqual(result.blocks.count, 1)
        if case let .paragraph(runs) = result.blocks[0] {
            XCTAssertEqual(runs.map(\.text).joined(), "Hello world.")
            XCTAssertNil(runs[0].language)
            XCTAssertNil(runs[0].noterefId)
        } else {
            XCTFail("Expected paragraph block")
        }
        XCTAssertTrue(result.footnotes.isEmpty)
    }

    func test_heading_levels_map_to_block_levels() {
        let xhtml = """
        <h1>Title</h1>
        <h2>Chapter</h2>
        <h3>Section</h3>
        <p>Body.</p>
        """
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertEqual(result.blocks.count, 4)
        if case let .heading(level: l1, _) = result.blocks[0] { XCTAssertEqual(l1, 1) }
        if case let .heading(level: l2, _) = result.blocks[1] { XCTAssertEqual(l2, 2) }
        if case let .heading(level: l3, _) = result.blocks[2] { XCTAssertEqual(l3, 3) }
        if case .paragraph = result.blocks[3] {} else { XCTFail("Expected paragraph") }
    }

    func test_multiple_paragraphs_preserve_order() {
        let xhtml = """
        <p>First.</p>
        <p>Second.</p>
        <p>Third.</p>
        """
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        let texts = result.blocks.compactMap { block -> String? in
            if case let .paragraph(runs) = block { return runs.map(\.text).joined() }
            return nil
        }
        XCTAssertEqual(texts, ["First.", "Second.", "Third."])
    }

    // MARK: - inline elements

    func test_em_and_strong_are_inlined_as_plain_text() {
        // We don't model bold/italic on InlineRun yet; the parser
        // should keep the wrapped text in the run, not drop it.
        let xhtml = "<p>Plain <em>emphasis</em> and <strong>bold</strong>.</p>"
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertEqual(result.blocks.count, 1)
        if case let .paragraph(runs) = result.blocks[0] {
            let joined = runs.map(\.text).joined()
            XCTAssertEqual(joined, "Plain emphasis and bold.")
        }
    }

    func test_span_lang_attribute_sets_run_language() {
        let xhtml = #"<p>Latin: <span lang="la">veni vidi vici</span> end.</p>"#
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertEqual(result.blocks.count, 1)
        guard case let .paragraph(runs) = result.blocks[0] else {
            return XCTFail("Expected paragraph")
        }
        // Find the run with the Latin language tag.
        let latinRun = runs.first { $0.language?.rawValue == "la" }
        XCTAssertNotNil(latinRun)
        XCTAssertEqual(latinRun?.text, "veni vidi vici")
        // Surrounding text shouldn't carry the language.
        let plainRuns = runs.filter { $0.language == nil }
        XCTAssertEqual(plainRuns.map(\.text).joined(), "Latin:  end.")
    }

    func test_xml_lang_attribute_also_recognized() {
        let xhtml = #"<p><span xml:lang="grc">λόγος</span></p>"#
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        guard case let .paragraph(runs) = result.blocks[0] else {
            return XCTFail("Expected paragraph")
        }
        XCTAssertEqual(runs.first { $0.language?.rawValue == "grc" }?.text, "λόγος")
    }

    // MARK: - footnotes

    func test_noteref_in_paragraph_namespaces_id_with_page_index() {
        let xhtml = #"""
        <p>Body text<a class="noteref" href="#fn-1">1</a> continues.</p>
        <aside class="footnote" id="fn-1">1 footnote body text.</aside>
        """#
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 7)
        XCTAssertEqual(result.blocks.count, 1)
        XCTAssertEqual(result.footnotes.count, 1)
        // Namespaced id includes the page index.
        XCTAssertEqual(result.footnotes[0].id, "fn-p7-1")
        XCTAssertEqual(result.footnotes[0].marker, "1")
        XCTAssertEqual(result.footnotes[0].runs.map(\.text).joined(),
            "footnote body text.")
        // The noteref run in the paragraph also gets the namespaced id.
        guard case let .paragraph(runs) = result.blocks[0] else {
            return XCTFail("Expected paragraph")
        }
        let noterefRun = runs.first { $0.noterefId != nil }
        XCTAssertNotNil(noterefRun)
        XCTAssertEqual(noterefRun?.text, "1")
        XCTAssertEqual(noterefRun?.noterefId, "fn-p7-1")
    }

    func test_symbolic_marker_extracted_from_aside_body() {
        let xhtml = #"""
        <p>Text<a class="noteref" href="#fn-1">*</a>.</p>
        <aside class="footnote" id="fn-1">* This is the asterisked note.</aside>
        """#
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertEqual(result.footnotes.count, 1)
        XCTAssertEqual(result.footnotes[0].marker, "*")
        XCTAssertEqual(result.footnotes[0].runs.map(\.text).joined(),
            "This is the asterisked note.")
    }

    func test_multiple_footnotes_get_distinct_namespaced_ids() {
        let xhtml = #"""
        <p>One<a class="noteref" href="#fn-1">1</a> and two<a class="noteref" href="#fn-2">2</a>.</p>
        <aside class="footnote" id="fn-1">1 first note.</aside>
        <aside class="footnote" id="fn-2">2 second note.</aside>
        """#
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 12)
        XCTAssertEqual(result.footnotes.count, 2)
        XCTAssertEqual(result.footnotes[0].id, "fn-p12-1")
        XCTAssertEqual(result.footnotes[1].id, "fn-p12-2")
        // Both noterefs land in one paragraph with matching ids.
        guard case let .paragraph(runs) = result.blocks[0] else {
            return XCTFail("Expected paragraph")
        }
        let noterefIds = runs.compactMap(\.noterefId)
        XCTAssertEqual(noterefIds, ["fn-p12-1", "fn-p12-2"])
    }

    // MARK: - entity preprocessing

    func test_html_named_entities_are_decoded() {
        let xhtml = "<p>Foo&nbsp;bar&mdash;baz.</p>"
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        if case let .paragraph(runs) = result.blocks[0] {
            XCTAssertEqual(runs.map(\.text).joined(), "Foo\u{00A0}bar\u{2014}baz.")
        } else {
            XCTFail("Expected paragraph")
        }
    }

    // MARK: - robustness

    func test_empty_input_returns_empty_result() {
        let result = ClaudePageXHTMLParser().parse("", pageIndex: 0)
        XCTAssertTrue(result.blocks.isEmpty)
        XCTAssertTrue(result.footnotes.isEmpty)
    }

    func test_malformed_xhtml_falls_back_to_plain_paragraph() {
        // Unclosed tag — XMLParser will reject the whole document,
        // we should still return a paragraph with the body text.
        let xhtml = "<p>Some text without a closing tag"
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertEqual(result.blocks.count, 1)
        if case let .paragraph(runs) = result.blocks[0] {
            XCTAssertEqual(runs.map(\.text).joined(),
                "Some text without a closing tag")
        }
    }

    func test_whitespace_only_blocks_are_dropped() {
        let xhtml = "<p>   </p><p>Real content.</p><p></p>"
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertEqual(result.blocks.count, 1)
        if case let .paragraph(runs) = result.blocks[0] {
            XCTAssertEqual(runs.map(\.text).joined(), "Real content.")
        }
    }
}
