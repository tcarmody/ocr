import XCTest
@testable import Humanist

/// Pins the Markdown shape of the marks export: chapter grouping,
/// blockquoted highlights, bold notes, bookmark markers, byline, and
/// the chapter-title fallback. Drives the formatter directly so the
/// view-layer save/clipboard plumbing stays thin.
final class AnnotationMarkdownExporterTests: XCTestCase {

    private func highlight(
        chapter: Int, anchor: String, text: String, note: String? = nil
    ) -> Annotation {
        Annotation(
            chapterIdx: chapter,
            paragraphAnchorId: anchor,
            selectedText: text,
            note: note,
            kind: note == nil ? .highlight : .passage
        )
    }

    func test_groups_by_chapter_with_byline() {
        let annots = [
            highlight(chapter: 0, anchor: "hu-p-0-1", text: "First grab."),
            highlight(chapter: 1, anchor: "hu-p-1-3", text: "Second grab."),
        ]
        let md = AnnotationMarkdownExporter.markdown(
            bookTitle: "The Blue Book",
            author: "Wittgenstein",
            annotations: annots,
            chapterTitles: [0: "Preface", 1: "Following a Rule"]
        )
        XCTAssertTrue(md.hasPrefix("# The Blue Book\n*by Wittgenstein*\n"), md)
        XCTAssertTrue(md.contains("\n## Preface\n"), md)
        XCTAssertTrue(md.contains("\n## Following a Rule\n"), md)
        XCTAssertTrue(md.contains("> First grab."), md)
        XCTAssertTrue(md.contains("> Second grab."), md)
    }

    func test_passage_renders_note() {
        let md = AnnotationMarkdownExporter.markdown(
            bookTitle: "Book",
            author: nil,
            annotations: [highlight(
                chapter: 0, anchor: "hu-p-0-1",
                text: "bedrock", note: "cf. On Certainty §253"
            )],
            chapterTitles: [0: "Ch"]
        )
        XCTAssertTrue(md.contains("> bedrock\n\n**Note:** cf. On Certainty §253"), md)
    }

    func test_no_author_omits_byline() {
        let md = AnnotationMarkdownExporter.markdown(
            bookTitle: "Book",
            author: nil,
            annotations: [highlight(chapter: 0, anchor: "hu-p-0-1", text: "x")],
            chapterTitles: [:]
        )
        XCTAssertTrue(md.hasPrefix("# Book\n"), md)
        XCTAssertFalse(md.contains("*by"), md)
    }

    func test_blank_author_omits_byline() {
        let md = AnnotationMarkdownExporter.markdown(
            bookTitle: "Book", author: "   ",
            annotations: [highlight(chapter: 0, anchor: "hu-p-0-1", text: "x")],
            chapterTitles: [:]
        )
        XCTAssertFalse(md.contains("*by"), md)
    }

    func test_bookmark_marker_and_chapter_fallback() {
        let bookmark = Annotation(
            chapterIdx: 4, paragraphAnchorId: "hu-p-4-2", kind: .bookmark
        )
        let md = AnnotationMarkdownExporter.markdown(
            bookTitle: "Book", author: nil,
            annotations: [bookmark],
            chapterTitles: [:]   // no title → fallback
        )
        XCTAssertTrue(md.contains("## Chapter 5"), md)   // chapterIdx 4 → "Chapter 5"
        XCTAssertTrue(md.contains("🔖 Bookmark"), md)
    }

    func test_multiline_highlight_quotes_each_line() {
        let md = AnnotationMarkdownExporter.markdown(
            bookTitle: "Book", author: nil,
            annotations: [highlight(
                chapter: 0, anchor: "hu-p-0-1", text: "line one\nline two"
            )],
            chapterTitles: [0: "Ch"]
        )
        XCTAssertTrue(md.contains("> line one\n> line two"), md)
    }

    func test_highlight_without_text_or_note_is_skipped() {
        let empty = Annotation(
            chapterIdx: 0, paragraphAnchorId: "hu-p-0-1",
            selectedText: nil, kind: .highlight
        )
        let md = AnnotationMarkdownExporter.markdown(
            bookTitle: "Book", author: nil,
            annotations: [empty],
            chapterTitles: [0: "Ch"]
        )
        // No content → chapter heading shouldn't even appear.
        XCTAssertFalse(md.contains("## Ch"), md)
        XCTAssertEqual(md, "# Book\n")
    }

    func test_default_filename_sanitizes_title() {
        XCTAssertEqual(
            AnnotationMarkdownExporter.defaultFilename(bookTitle: "A/B: C?"),
            "A B C — Marks.md"
        )
        XCTAssertEqual(
            AnnotationMarkdownExporter.defaultFilename(bookTitle: "   "),
            "Book — Marks.md"
        )
        XCTAssertEqual(
            AnnotationMarkdownExporter.defaultFilename(bookTitle: "Clean Title"),
            "Clean Title — Marks.md"
        )
    }
}
