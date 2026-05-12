import XCTest
@testable import Pipeline

/// `XHTMLTextReplacer` — text-node-only string replacement used by
/// the EPUB import coherence path. Verifies that tags, attributes,
/// `<script>` / `<style>` bodies, comments, CDATA, and PIs pass
/// through byte-identical while character-data regions get rewritten.
final class XHTMLTextReplacerTests: XCTestCase {

    private func sug(_ wrong: String, _ right: String)
        -> ClaudeCoherenceAnalyzer.Suggestion {
        ClaudeCoherenceAnalyzer.Suggestion(wrong: wrong, right: right)
    }

    // MARK: - text-node replacement

    func test_apply_rewrites_text_in_paragraphs() {
        let xhtml = "<p>Schafer arrived.</p>"
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("Schafer", "Schäfer")], xhtml: xhtml
        )
        XCTAssertEqual(result, "<p>Schäfer arrived.</p>")
    }

    func test_apply_rewrites_across_multiple_blocks() {
        let xhtml = "<h1>Schafer</h1><p>Schafer left.</p><p>Schafer waited.</p>"
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("Schafer", "Schäfer")], xhtml: xhtml
        )
        XCTAssertEqual(
            result,
            "<h1>Schäfer</h1><p>Schäfer left.</p><p>Schäfer waited.</p>"
        )
    }

    // MARK: - tags and attributes preserved

    func test_apply_does_not_rewrite_attribute_values() {
        // Attribute value contains the substring "Schafer" — must
        // not be replaced. Only the text content should change.
        let xhtml = "<p class=\"Schafer-class\">Schafer arrived.</p>"
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("Schafer", "Schäfer")], xhtml: xhtml
        )
        XCTAssertEqual(
            result,
            "<p class=\"Schafer-class\">Schäfer arrived.</p>"
        )
    }

    func test_apply_does_not_rewrite_inside_tag_names() {
        // Pathological tag name containing the wrong-string.
        let xhtml = "<schafer-element>Schafer arrived.</schafer-element>"
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("Schafer", "Schäfer")], xhtml: xhtml
        )
        XCTAssertEqual(
            result,
            "<schafer-element>Schäfer arrived.</schafer-element>"
        )
    }

    // MARK: - raw-text elements skipped

    func test_apply_skips_script_body() {
        let xhtml = """
        <script>var s = "Schafer";</script><p>Schafer arrived.</p>
        """
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("Schafer", "Schäfer")], xhtml: xhtml
        )
        // Script body untouched; paragraph body rewritten.
        XCTAssertEqual(
            result,
            "<script>var s = \"Schafer\";</script><p>Schäfer arrived.</p>"
        )
    }

    func test_apply_skips_style_body() {
        let xhtml = """
        <style>.Schafer { color: red; }</style><p>Schafer arrived.</p>
        """
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("Schafer", "Schäfer")], xhtml: xhtml
        )
        XCTAssertEqual(
            result,
            "<style>.Schafer { color: red; }</style><p>Schäfer arrived.</p>"
        )
    }

    // MARK: - comments, CDATA, PIs preserved

    func test_apply_skips_comment_body() {
        let xhtml = "<!-- TODO: Schafer rename --><p>Schafer arrived.</p>"
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("Schafer", "Schäfer")], xhtml: xhtml
        )
        XCTAssertEqual(
            result,
            "<!-- TODO: Schafer rename --><p>Schäfer arrived.</p>"
        )
    }

    func test_apply_skips_cdata_body() {
        let xhtml = "<![CDATA[Schafer raw]]><p>Schafer arrived.</p>"
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("Schafer", "Schäfer")], xhtml: xhtml
        )
        XCTAssertEqual(
            result,
            "<![CDATA[Schafer raw]]><p>Schäfer arrived.</p>"
        )
    }

    func test_apply_skips_processing_instruction_body() {
        let xhtml = "<?xml-stylesheet href=\"Schafer.xsl\"?><p>Schafer arrived.</p>"
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("Schafer", "Schäfer")], xhtml: xhtml
        )
        XCTAssertEqual(
            result,
            "<?xml-stylesheet href=\"Schafer.xsl\"?><p>Schäfer arrived.</p>"
        )
    }

    // MARK: - edge cases

    func test_apply_no_suggestions_returns_input_unchanged() {
        let xhtml = "<p>Schafer arrived.</p>"
        let result = XHTMLTextReplacer.apply(suggestions: [], xhtml: xhtml)
        XCTAssertEqual(result, xhtml)
    }

    func test_apply_no_matches_returns_byte_identical_output() {
        let xhtml = "<p>Some unrelated text.</p>"
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("Schafer", "Schäfer")], xhtml: xhtml
        )
        XCTAssertEqual(result, xhtml)
    }

    func test_apply_preserves_title_element_text() {
        // <title> content is text, not raw-text — it should be
        // rewritten just like <h1> content. (Confirms we don't
        // accidentally treat <title> as raw-text.)
        let xhtml = "<title>Schafer's Journey</title><p>Schafer arrived.</p>"
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("Schafer", "Schäfer")], xhtml: xhtml
        )
        XCTAssertEqual(
            result,
            "<title>Schäfer's Journey</title><p>Schäfer arrived.</p>"
        )
    }

    func test_apply_sequential_replacement_matches_chapter_path_semantics() {
        // Same semantics as `ClaudeCoherenceAnalyzer.applyToString`:
        // suggestions apply in order; chained rewrites can compose.
        // (Guardrails prevent dangerous chains in practice — this
        // test just locks down the documented behavior.)
        let xhtml = "<p>foo bar baz</p>"
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("foo", "qux"), sug("qux", "WIN")],
            xhtml: xhtml
        )
        XCTAssertEqual(result, "<p>WIN bar baz</p>")
    }

    func test_apply_handles_doctype_declaration() {
        let xhtml = """
        <!DOCTYPE html>
        <html><body><p>Schafer arrived.</p></body></html>
        """
        let result = XHTMLTextReplacer.apply(
            suggestions: [sug("Schafer", "Schäfer")], xhtml: xhtml
        )
        XCTAssertTrue(result.contains("<!DOCTYPE html>"))
        XCTAssertTrue(result.contains("Schäfer arrived."))
    }
}
