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

    // MARK: - <section data-stream> (complex layout)

    func test_section_data_stream_captured_in_diagnostic() {
        let xhtml = """
        <section data-stream="main"><p>Main column.</p></section>\
        <section data-stream="sidebar"><p>Glossary entry.</p></section>
        """
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertEqual(result.detectedStreams, ["main", "sidebar"])
    }

    func test_section_only_primary_stream_emits_blocks() {
        // Only blocks inside `data-stream="main"` (or outside any
        // section) land in the block stream. Non-primary streams
        // are recorded in `detectedStreams` but their content is
        // suppressed — Gemini 3.5 Flash emits a hallucinated
        // `main-2` that doubled body text in the EPUB until this
        // suppression landed (May 2026 Becker test).
        let xhtml = """
        <section data-stream="main"><p>First.</p><p>Second.</p></section>\
        <section data-stream="sidebar"><p>Third.</p></section>
        """
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        let texts: [String] = result.blocks.compactMap { block in
            if case let .paragraph(runs) = block {
                return runs.map(\.text).joined()
            }
            return nil
        }
        XCTAssertEqual(texts, ["First.", "Second."])
        XCTAssertEqual(result.detectedStreams, ["main", "sidebar"])
    }

    // MARK: - P-Math (MathML pass-through)

    func test_math_inline_in_paragraph_is_captured_verbatim() {
        // The parser should NOT flatten `<math>` into sub/sup runs.
        // It should capture the whole subtree as a rawXHTML run so
        // the XHTML writer can emit it unmodified.
        let xhtml = """
        <p>Define <math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi><msub><mi>m</mi><mn>1</mn></msub></math> as the first.</p>
        """
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertEqual(result.blocks.count, 1)
        guard case let .paragraph(runs) = result.blocks[0] else {
            XCTFail("expected paragraph block")
            return
        }
        // Should have at least one run with rawXHTML set.
        let mathRuns = runs.filter { $0.rawXHTML != nil }
        XCTAssertEqual(mathRuns.count, 1)
        let raw = mathRuns[0].rawXHTML ?? ""
        XCTAssertTrue(raw.hasPrefix("<math"))
        XCTAssertTrue(raw.contains("<mi>x</mi>"))
        XCTAssertTrue(raw.contains("<msub>"))
        XCTAssertTrue(raw.hasSuffix("</math>"))
    }

    func test_math_display_block_emits_paragraph_with_raw_run() {
        // A standalone `<math display="block">` should start a
        // paragraph implicitly and emit a single rawXHTML run.
        let xhtml = #"""
        <math xmlns="http://www.w3.org/1998/Math/MathML" display="block"><mi>Z</mi><mo>=</mo><mi>f</mi></math>
        """#
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertEqual(result.blocks.count, 1)
        guard case let .paragraph(runs) = result.blocks[0] else {
            XCTFail("expected paragraph block")
            return
        }
        XCTAssertEqual(runs.count, 1)
        let raw = runs[0].rawXHTML ?? ""
        XCTAssertTrue(raw.contains("display=\"block\""))
        XCTAssertTrue(raw.contains("<mi>Z</mi>"))
    }

    func test_math_plain_text_fallback_is_populated() {
        // The InlineRun's `text` field should hold the math's
        // visible text content so Markdown / .txt outputs have
        // something to fall back on.
        let xhtml = """
        <p>Therefore <math><mi>a</mi><mo>+</mo><mi>b</mi></math> follows.</p>
        """
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        guard case let .paragraph(runs) = result.blocks[0] else {
            XCTFail("expected paragraph"); return
        }
        let mathRun = runs.first { $0.rawXHTML != nil }
        XCTAssertEqual(mathRun?.text, "a+b")
    }

    func test_section_main_2_stream_is_suppressed() {
        // Regression: Gemini 3.5 Flash emits two streams per
        // page (`main` + `main-2`) for typeset single-column
        // prose, with `main-2` being hallucinated next-page
        // content. The contents are slight variants of the same
        // text, producing visibly doubled paragraphs in the EPUB.
        // Verify the parser keeps only the primary stream's blocks.
        let xhtml = """
        <section data-stream="main"><p>Real page content.</p></section>\
        <section data-stream="main-2"><p>Hallucinated continuation.</p></section>
        """
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        let texts: [String] = result.blocks.compactMap { block in
            if case let .paragraph(runs) = block {
                return runs.map(\.text).joined()
            }
            return nil
        }
        XCTAssertEqual(texts, ["Real page content."])
        XCTAssertEqual(result.detectedStreams, ["main", "main-2"])
    }

    func test_single_column_page_has_no_detected_streams() {
        let xhtml = "<p>Just a normal paragraph.</p><p>And another.</p>"
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertTrue(result.detectedStreams.isEmpty)
    }

    func test_section_without_data_stream_attr_is_ignored() {
        // Defensive: a bare <section> without the attribute
        // shouldn't pollute the diagnostic. Blocks inside still
        // parse normally.
        let xhtml = "<section><p>Body.</p></section>"
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertTrue(result.detectedStreams.isEmpty)
        XCTAssertEqual(result.blocks.count, 1)
    }

    // MARK: - P-Verse-Layout

    func test_verse_div_collects_lines_into_block_verse() {
        let xhtml = """
        <div class="verse">
        <p class="line">Click of the hooves, through garbage,</p>
        <p class="line">Clutching the greasy stone</p>
        <p class="line indent-3">But Varchi of Florence,</p>
        </div>
        """
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertEqual(result.blocks.count, 1)
        guard case let .verse(lines) = result.blocks[0] else {
            XCTFail("Expected Block.verse")
            return
        }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].indent, 0)
        XCTAssertEqual(lines[1].indent, 0)
        XCTAssertEqual(lines[2].indent, 3)
        XCTAssertEqual(
            lines[0].runs.map(\.text).joined(),
            "Click of the hooves, through garbage,"
        )
        XCTAssertEqual(
            lines[2].runs.map(\.text).joined(),
            "But Varchi of Florence,"
        )
    }

    func test_verse_div_carries_inline_language_and_emphasis() {
        // Sonnet-shaped output with an italic Greek fragment in a
        // verse line. Parser must preserve both the language tag
        // and the italic flag on the inner run.
        let xhtml = """
        <div class="verse">
        <p class="line">Then "<i lang="grc">Σίγα μαλ' αὖθις δευτέραν</i>!</p>
        </div>
        """
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertEqual(result.blocks.count, 1)
        guard case let .verse(lines) = result.blocks[0] else {
            XCTFail("Expected Block.verse")
            return
        }
        XCTAssertEqual(lines.count, 1)
        let runs = lines[0].runs
        // At least one italic, lang-grc-tagged run is present.
        let italicGreek = runs.first {
            $0.isItalic && $0.language == BCP47("grc")
        }
        XCTAssertNotNil(italicGreek, "Greek italic run missing language tag")
    }

    func test_verse_div_emits_nothing_when_empty() {
        let xhtml = "<div class=\"verse\"></div>"
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertTrue(result.blocks.isEmpty)
    }

    func test_prose_paragraph_outside_verse_div_unaffected() {
        // Regression guard: verse-collection mode must not bleed
        // into surrounding prose paragraphs.
        let xhtml = """
        <p>Before the poem.</p>
        <div class="verse">
        <p class="line">A line.</p>
        </div>
        <p>After the poem.</p>
        """
        let result = ClaudePageXHTMLParser().parse(xhtml, pageIndex: 0)
        XCTAssertEqual(result.blocks.count, 3)
        guard case .paragraph = result.blocks[0] else {
            XCTFail("Expected leading paragraph")
            return
        }
        guard case .verse(let lines) = result.blocks[1] else {
            XCTFail("Expected middle verse")
            return
        }
        XCTAssertEqual(lines.count, 1)
        guard case .paragraph = result.blocks[2] else {
            XCTFail("Expected trailing paragraph")
            return
        }
    }

    func test_indent_bucket_parser_extracts_n_from_class() {
        // Internal helper, but worth pinning the regex behavior:
        // accepts indent-N tokens in any position; ignores other
        // classes; defaults to 0 when absent.
        XCTAssertEqual(
            ClaudePageXHTMLParser.parseIndentBucket(from: "line indent-5"),
            5
        )
        XCTAssertEqual(
            ClaudePageXHTMLParser.parseIndentBucket(from: "indent-2 line"),
            2
        )
        XCTAssertEqual(
            ClaudePageXHTMLParser.parseIndentBucket(from: "line"),
            0
        )
        XCTAssertEqual(
            ClaudePageXHTMLParser.parseIndentBucket(from: ""),
            0
        )
    }
}
