import XCTest
import Document
@testable import Humanist

/// `EPUBImporter`'s minimal-Chapter sampler: title extraction +
/// opening-text concatenation. These are the cheap-shortcut
/// pieces that make AFM chapter classification on imported EPUBs
/// possible without building a full XHTML → Chapter IR parser.
///
/// `@MainActor` because `EPUBImporter` is, and Swift 6 won't let
/// us call its static methods from a synchronous nonisolated
/// context.
@MainActor
final class EPUBImporterSamplerTests: XCTestCase {

    // MARK: - extractFirstTitle

    func test_extractFirstTitle_uses_h1_when_present() {
        let xhtml = """
            <html><body>
            <h1>Chapter Two: Power</h1>
            <p>Foucault argued…</p>
            </body></html>
            """
        XCTAssertEqual(
            EPUBImporter.extractFirstTitle(from: xhtml),
            "Chapter Two: Power"
        )
    }

    func test_extractFirstTitle_strips_inline_tags_from_h1() {
        // `<em>` / `<span>` inside the heading shouldn't survive
        // into the classifier input — it expects plain text.
        let xhtml = """
            <h1><em>Discipline</em> and <span>Punish</span></h1>
            """
        XCTAssertEqual(
            EPUBImporter.extractFirstTitle(from: xhtml),
            "Discipline and Punish"
        )
    }

    func test_extractFirstTitle_falls_back_to_title_element() {
        let xhtml = """
            <html><head><title>Bibliography</title></head>
            <body><p>References below.</p></body></html>
            """
        XCTAssertEqual(
            EPUBImporter.extractFirstTitle(from: xhtml),
            "Bibliography"
        )
    }

    func test_extractFirstTitle_prefers_h1_over_title() {
        // h1 sits in body and is what the classifier actually
        // reads as the section's heading; <title> is metadata.
        let xhtml = """
            <html><head><title>Foucault Reader</title></head>
            <body><h1>Preface</h1></body></html>
            """
        XCTAssertEqual(
            EPUBImporter.extractFirstTitle(from: xhtml),
            "Preface"
        )
    }

    func test_extractFirstTitle_returns_nil_when_both_missing() {
        let xhtml = "<html><body><p>No headings here.</p></body></html>"
        XCTAssertNil(EPUBImporter.extractFirstTitle(from: xhtml))
    }

    func test_extractFirstTitle_returns_nil_for_empty_h1() {
        let xhtml = "<h1>   </h1><p>body</p>"
        XCTAssertNil(EPUBImporter.extractFirstTitle(from: xhtml))
    }

    // MARK: - extractOpeningText

    func test_extractOpeningText_concatenates_paragraphs() {
        let xhtml = """
            <p>First sentence.</p>
            <p>Second sentence.</p>
            """
        let out = EPUBImporter.extractOpeningText(from: xhtml, maxChars: 1000)
        XCTAssertEqual(out, "First sentence. Second sentence.")
    }

    func test_extractOpeningText_stops_at_maxChars() {
        // Long opening — exercise the truncation path. The cap
        // is a hard limit, not a soft word boundary.
        let xhtml = "<p>" + String(repeating: "a", count: 500) + "</p>"
        let out = EPUBImporter.extractOpeningText(from: xhtml, maxChars: 100)
        XCTAssertEqual(out.count, 100)
    }

    func test_extractOpeningText_skips_figures_tables_anchors() {
        // Only paragraph-bearing elements should contribute — figures
        // and tables carry no classifier signal.
        let xhtml = """
            <p>Body text.</p>
            <figure><img src="x.png"/><figcaption>caption</figcaption></figure>
            <table><tr><td>cell</td></tr></table>
            <p>More body.</p>
            """
        let out = EPUBImporter.extractOpeningText(from: xhtml, maxChars: 1000)
        XCTAssertTrue(out.contains("Body text"))
        XCTAssertTrue(out.contains("More body"))
        XCTAssertFalse(out.contains("caption"))
        XCTAssertFalse(out.contains("cell"))
    }

    func test_extractOpeningText_includes_h2_to_h6() {
        // The classifier reads subheadings as part of the opening
        // signal ("Preface" + "Acknowledgments" both telegraph
        // front-matter shape).
        let xhtml = """
            <h2>Acknowledgments</h2>
            <p>Many thanks…</p>
            """
        let out = EPUBImporter.extractOpeningText(from: xhtml, maxChars: 1000)
        XCTAssertTrue(out.contains("Acknowledgments"))
        XCTAssertTrue(out.contains("Many thanks"))
    }

    func test_extractOpeningText_excludes_h1() {
        // h1 is the chapter title, already captured by
        // extractFirstTitle. Including it again in opening text
        // would double-count.
        let xhtml = """
            <h1>Title goes here</h1>
            <p>Body text.</p>
            """
        let out = EPUBImporter.extractOpeningText(from: xhtml, maxChars: 1000)
        XCTAssertFalse(out.contains("Title goes here"))
        XCTAssertTrue(out.contains("Body text"))
    }

    func test_extractOpeningText_handles_empty_doc() {
        XCTAssertEqual(
            EPUBImporter.extractOpeningText(from: "", maxChars: 100), ""
        )
    }

    // MARK: - buildMinimalChapter

    func test_buildMinimalChapter_returns_nil_for_empty_doc() {
        // No title AND no opening text = nothing to classify.
        XCTAssertNil(EPUBImporter.buildMinimalChapter(from: "<body></body>"))
    }

    func test_buildMinimalChapter_succeeds_with_only_title() {
        // Title alone is enough — the classifier reads title + body
        // independently. Some chapters genuinely have just an h1.
        let xhtml = "<h1>Dedication</h1>"
        let chapter = EPUBImporter.buildMinimalChapter(from: xhtml)
        XCTAssertNotNil(chapter)
        XCTAssertEqual(chapter?.title, "Dedication")
        XCTAssertEqual(chapter?.blocks.count, 0)
    }

    func test_buildMinimalChapter_succeeds_with_only_body() {
        // Opening text alone also works — chapters without an h1
        // (whole-book single-spine EPUBs) still classify against
        // their opening prose.
        let xhtml = "<p>Once upon a time…</p>"
        let chapter = EPUBImporter.buildMinimalChapter(from: xhtml)
        XCTAssertNotNil(chapter)
        XCTAssertNil(chapter?.title)
        XCTAssertEqual(chapter?.blocks.count, 1)
        if case .paragraph(let runs) = chapter?.blocks.first {
            XCTAssertEqual(runs.first?.text, "Once upon a time…")
        } else {
            XCTFail("expected paragraph block")
        }
    }

    func test_buildMinimalChapter_combines_title_and_opening() {
        let xhtml = """
            <h1>Preface</h1>
            <p>This book began in…</p>
            """
        let chapter = EPUBImporter.buildMinimalChapter(from: xhtml)
        XCTAssertEqual(chapter?.title, "Preface")
        XCTAssertEqual(chapter?.blocks.count, 1)
    }
}
