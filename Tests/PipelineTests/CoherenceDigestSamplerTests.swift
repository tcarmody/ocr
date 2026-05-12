import XCTest
import Document
@testable import Pipeline

/// `CoherenceDigestSampler` — the XHTML → digest-suitable `[Chapter]`
/// helper the EPUB import path uses to feed `BookCoherenceAnalyzer`
/// without round-tripping through a full XHTML parser.
final class CoherenceDigestSamplerTests: XCTestCase {

    // MARK: - title extraction

    func test_extractFirstTitle_prefers_h1_over_title_element() {
        let xhtml = """
        <html><head><title>Head Title</title></head>
        <body><h1>Real Chapter Title</h1></body></html>
        """
        XCTAssertEqual(
            CoherenceDigestSampler.extractFirstTitle(from: xhtml),
            "Real Chapter Title"
        )
    }

    func test_extractFirstTitle_falls_back_to_title_element() {
        let xhtml = """
        <html><head><title>Head Title</title></head>
        <body><p>No heading here.</p></body></html>
        """
        XCTAssertEqual(
            CoherenceDigestSampler.extractFirstTitle(from: xhtml),
            "Head Title"
        )
    }

    func test_extractFirstTitle_strips_inline_tags() {
        let xhtml = "<h1>The <em>Annotated</em> Walden</h1>"
        XCTAssertEqual(
            CoherenceDigestSampler.extractFirstTitle(from: xhtml),
            "The Annotated Walden"
        )
    }

    func test_extractFirstTitle_returns_nil_when_neither_present() {
        let xhtml = "<html><body><p>Just paragraphs.</p></body></html>"
        XCTAssertNil(
            CoherenceDigestSampler.extractFirstTitle(from: xhtml)
        )
    }

    // MARK: - block extraction

    func test_extractBlocks_captures_headings_with_level() {
        let xhtml = """
        <h2>Section One</h2>
        <p>Body of section one.</p>
        <h3>Subsection</h3>
        <p>Sub body.</p>
        """
        let blocks = CoherenceDigestSampler.extractBlocks(
            from: xhtml, maxChars: 1000
        )
        XCTAssertEqual(blocks.count, 4)
        switch blocks[0] {
        case .heading(let level, let runs):
            XCTAssertEqual(level, 2)
            XCTAssertEqual(runs.first?.text, "Section One")
        default: XCTFail("expected heading at [0]")
        }
        switch blocks[2] {
        case .heading(let level, _):
            XCTAssertEqual(level, 3)
        default: XCTFail("expected heading at [2]")
        }
    }

    func test_extractBlocks_captures_paragraphs_blockquote_li() {
        let xhtml = """
        <p>A paragraph.</p>
        <blockquote>A quotation.</blockquote>
        <ul><li>Item one.</li></ul>
        """
        let blocks = CoherenceDigestSampler.extractBlocks(
            from: xhtml, maxChars: 1000
        )
        XCTAssertEqual(blocks.count, 3)
        for block in blocks {
            if case .heading = block { XCTFail("expected paragraph-shape"); return }
        }
    }

    func test_extractBlocks_stops_at_maxChars() {
        let chunk = String(repeating: "x", count: 100)
        let xhtml = (1...20).map { _ in "<p>\(chunk)</p>" }.joined()
        let blocks = CoherenceDigestSampler.extractBlocks(
            from: xhtml, maxChars: 250
        )
        // 100 + 100 = 200 (< 250), 100 + 100 + 100 = 300 (>= 250) → 3 blocks
        XCTAssertEqual(blocks.count, 3)
    }

    func test_extractBlocks_skips_empty_text() {
        let xhtml = "<p>   </p><p>Real content.</p><p></p>"
        let blocks = CoherenceDigestSampler.extractBlocks(
            from: xhtml, maxChars: 1000
        )
        XCTAssertEqual(blocks.count, 1)
        switch blocks[0] {
        case .paragraph(let runs):
            XCTAssertEqual(runs.first?.text, "Real content.")
        default: XCTFail("expected paragraph")
        }
    }

    // MARK: - stripXHTML

    func test_stripXHTML_drops_tags_and_decodes_entities() {
        let input = "<p>Caf&amp;eacute; <em>au lait</em> &amp; tea</p>"
        let plain = CoherenceDigestSampler.stripXHTML(input)
        // &amp;eacute; decodes only the &amp; portion (we don't
        // do full HTML5 entity decoding); &amp; → &.
        XCTAssertTrue(plain.contains("au lait"))
        XCTAssertTrue(plain.contains("&"))
        XCTAssertFalse(plain.contains("<em>"))
    }

    func test_stripXHTML_collapses_whitespace() {
        let input = "<p>One\n\n   two\t\tthree</p>"
        let plain = CoherenceDigestSampler.stripXHTML(input)
        XCTAssertFalse(plain.contains("\n"))
        XCTAssertFalse(plain.contains("\t"))
        XCTAssertFalse(plain.contains("  "))
    }

    // MARK: - sampleChapter

    func test_sampleChapter_yields_title_and_blocks() {
        let xhtml = """
        <html><body>
        <h1>Origins</h1>
        <p>The story begins in Vienna.</p>
        <p>Schafer arrived in winter.</p>
        </body></html>
        """
        let chapter = CoherenceDigestSampler.sampleChapter(from: xhtml)
        XCTAssertEqual(chapter.title, "Origins")
        XCTAssertEqual(chapter.blocks.count, 3)  // h1 + 2 p
    }

    func test_sampleChapter_empty_for_chrome_only_xhtml() {
        let xhtml = "<html><head><meta charset=\"utf-8\"/></head><body></body></html>"
        let chapter = CoherenceDigestSampler.sampleChapter(from: xhtml)
        XCTAssertNil(chapter.title)
        XCTAssertTrue(chapter.blocks.isEmpty)
    }
}
