import XCTest
import CoreGraphics
import Document
@testable import EPUB

/// `XHTMLWriter` figure-metadata aside emission for
/// P-Diagram-Description Tier 2 (description) and Tier 3
/// (labels). The aside is hidden — `hidden` attribute on the
/// element plus `aside.hu-figure-metadata { display: none; }`
/// in `book.css`. The chat / search indexer sees it.
final class XHTMLFigureMetadataTests: XCTestCase {

    private func makeFigureChapter(metadata: FigureMetadata?) -> Chapter {
        let asset = FigureAsset(
            id: "fig-00001",
            data: Data([0x89, 0x50, 0x4E, 0x47]),  // PNG magic, unused
            mediaType: "image/png",
            intrinsicSize: CGSize(width: 400, height: 300),
            isCover: false
        )
        var metaDict: [String: FigureMetadata] = [:]
        if let metadata { metaDict["fig-00001"] = metadata }
        return Chapter(
            title: "Test",
            blocks: [
                .figure(assetId: "fig-00001", alt: "marriage market chart", caption: [])
            ],
            figureAssets: [asset],
            figureMetadata: metaDict
        )
    }

    private func render(_ chapter: Chapter) -> String {
        XHTMLWriter(cssPath: "../css/book.css")
            .render(chapter, defaultLanguage: .en, fallbackTitle: "T")
    }

    // MARK: - Tier 2 (description)

    func test_emits_hidden_aside_when_description_present() {
        let chapter = makeFigureChapter(
            metadata: FigureMetadata(
                altText: "marriage market chart",
                description: "A vertical bar chart with five categories on the x-axis."
            )
        )
        let xhtml = render(chapter)
        XCTAssertTrue(
            xhtml.contains("<aside class=\"hu-figure-metadata\" hidden>"),
            "expected hidden aside; got:\n\(xhtml)"
        )
        XCTAssertTrue(
            xhtml.contains("A vertical bar chart with five categories on the x-axis."),
            "expected description text inside aside; got:\n\(xhtml)"
        )
    }

    func test_no_aside_when_metadata_has_only_alt_text() {
        // The alt text already lives on `<img alt>`; an aside
        // with nothing else to add would just be empty markup.
        let chapter = makeFigureChapter(
            metadata: FigureMetadata(
                altText: "marriage market chart",
                description: nil,
                labels: []
            )
        )
        let xhtml = render(chapter)
        XCTAssertFalse(
            xhtml.contains("hu-figure-metadata"),
            "no aside should emit when only alt text is present; got:\n\(xhtml)"
        )
    }

    func test_no_aside_when_no_metadata_at_all() {
        // The pre-Diagram-Description default: figure with no
        // metadata. Output should be the bare `<figure><img/></figure>`.
        let chapter = makeFigureChapter(metadata: nil)
        let xhtml = render(chapter)
        XCTAssertFalse(xhtml.contains("hu-figure-metadata"))
    }

    func test_description_is_xml_escaped() {
        // Defensive: a description containing `<` / `>` / `&`
        // mustn't break chapter XHTML well-formedness.
        let chapter = makeFigureChapter(
            metadata: FigureMetadata(
                altText: "alt",
                description: "5 < x & y > 3"
            )
        )
        let xhtml = render(chapter)
        XCTAssertTrue(xhtml.contains("5 &lt; x &amp; y &gt; 3"))
        XCTAssertFalse(xhtml.contains("5 < x"))  // raw not present
    }

    // MARK: - Tier 3 (labels)

    func test_emits_labels_in_aside_when_present() {
        let chapter = makeFigureChapter(
            metadata: FigureMetadata(
                altText: "heart diagram",
                description: nil,
                labels: ["left atrium", "right atrium", "aorta"]
            )
        )
        let xhtml = render(chapter)
        XCTAssertTrue(
            xhtml.contains("hu-figure-metadata"),
            "expected aside to emit when labels present (even without description)"
        )
        XCTAssertTrue(xhtml.contains("Labels: left atrium, right atrium, aorta"))
    }

    func test_emits_both_description_and_labels_when_both_present() {
        let chapter = makeFigureChapter(
            metadata: FigureMetadata(
                altText: "bar chart",
                description: "Five categories from 1950 to 1990.",
                labels: ["1950", "1960", "1970", "1980", "1990"]
            )
        )
        let xhtml = render(chapter)
        XCTAssertTrue(xhtml.contains("Five categories from 1950 to 1990."))
        XCTAssertTrue(xhtml.contains("Labels: 1950, 1960, 1970, 1980, 1990"))
    }

    func test_labels_are_xml_escaped() {
        // Defensive: a label containing `<` / `>` / `&` (math
        // symbols, comparison operators) mustn't break XHTML.
        let chapter = makeFigureChapter(
            metadata: FigureMetadata(
                altText: "alt",
                labels: ["x < 5", "y & z"]
            )
        )
        let xhtml = render(chapter)
        XCTAssertTrue(xhtml.contains("x &lt; 5"))
        XCTAssertTrue(xhtml.contains("y &amp; z"))
    }
}
