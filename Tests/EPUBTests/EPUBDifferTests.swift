import XCTest
import Document
@testable import EPUB

/// End-to-end tests for the Tools → Compare EPUBs… (O-Diff) flow.
/// Builds two small EPUB fixtures via `EPUBBuilder`, runs the
/// differ, and asserts the chapter / paragraph layout of the
/// resulting `EPUBDiff`. Includes a smoke test for the unified-diff
/// text formatter.
final class EPUBDifferTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBDifferTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Paragraph extraction

    func test_paragraphs_extracts_p_elements() {
        let xhtml = """
        <html><body>
        <p>First paragraph.</p>
        <p>Second paragraph.</p>
        </body></html>
        """
        let paras = EPUBDiffer.paragraphs(in: xhtml)
        XCTAssertEqual(paras, ["First paragraph.", "Second paragraph."])
    }

    func test_paragraphs_strips_inline_tags() {
        let xhtml = "<body><p>Hello <em>emphasized</em> world.</p></body>"
        let paras = EPUBDiffer.paragraphs(in: xhtml)
        XCTAssertEqual(paras, ["Hello emphasized world."])
    }

    func test_normalize_collapses_whitespace_and_decodes_entities() {
        XCTAssertEqual(
            EPUBDiffer.normalize("  Hello&nbsp;&amp;\n  goodbye  "),
            "Hello & goodbye"
        )
    }

    // MARK: - Diff: identical books

    func test_identical_books_produce_no_changes() throws {
        let a = try buildEPUB(name: "a.epub", chapters: [
            ("Chapter 1", "First paragraph.", "Second paragraph."),
            ("Chapter 2", "Another chapter.", "Another paragraph.")
        ])
        let b = try buildEPUB(name: "b.epub", chapters: [
            ("Chapter 1", "First paragraph.", "Second paragraph."),
            ("Chapter 2", "Another chapter.", "Another paragraph.")
        ])
        let diff = try EPUBDiffer().diff(leftURL: a, rightURL: b)
        XCTAssertEqual(diff.totalChanges, 0)
        XCTAssertEqual(diff.chaptersWithChanges, 0)
    }

    // MARK: - Diff: paragraph changes

    func test_modified_paragraph_reports_remove_plus_add() throws {
        let a = try buildEPUB(name: "a.epub", chapters: [
            ("Chapter 1", "First paragraph.", "Second paragraph.")
        ])
        let b = try buildEPUB(name: "b.epub", chapters: [
            ("Chapter 1", "First paragraph.", "Second paragraph (revised).")
        ])
        let diff = try EPUBDiffer().diff(leftURL: a, rightURL: b)
        XCTAssertEqual(diff.chaptersWithChanges, 1)
        let chapter = diff.chapterDiffs[0]
        XCTAssertEqual(chapter.changedCount, 2)
        // Order: removed comes before added (left walked first).
        XCTAssertTrue(chapter.changes.contains(where: {
            if case .removed(let s) = $0 { return s == "Second paragraph." }
            return false
        }))
        XCTAssertTrue(chapter.changes.contains(where: {
            if case .added(let s) = $0 { return s == "Second paragraph (revised)." }
            return false
        }))
    }

    func test_added_paragraph_only_appears_as_added() throws {
        let a = try buildEPUB(name: "a.epub", chapters: [
            ("Chapter 1", "First.", "Second.")
        ])
        let b = try buildEPUB(name: "b.epub", chapters: [
            ("Chapter 1", "First.", "Second.", "Third.")
        ])
        let diff = try EPUBDiffer().diff(leftURL: a, rightURL: b)
        let chapter = diff.chapterDiffs[0]
        XCTAssertEqual(chapter.changedCount, 1)
        XCTAssertTrue(chapter.changes.contains(.added("Third.")))
    }

    func test_removed_paragraph_only_appears_as_removed() throws {
        let a = try buildEPUB(name: "a.epub", chapters: [
            ("Chapter 1", "First.", "Second.", "Third.")
        ])
        let b = try buildEPUB(name: "b.epub", chapters: [
            ("Chapter 1", "First.", "Second.")
        ])
        let diff = try EPUBDiffer().diff(leftURL: a, rightURL: b)
        let chapter = diff.chapterDiffs[0]
        XCTAssertEqual(chapter.changedCount, 1)
        XCTAssertTrue(chapter.changes.contains(.removed("Third.")))
    }

    // MARK: - Diff: chapter mismatch

    func test_extra_chapter_in_right_appears_as_added_chapter() throws {
        let a = try buildEPUB(name: "a.epub", chapters: [
            ("Chapter 1", "First.")
        ])
        let b = try buildEPUB(name: "b.epub", chapters: [
            ("Chapter 1", "First."),
            ("Chapter 2", "Brand new chapter.")
        ])
        let diff = try EPUBDiffer().diff(leftURL: a, rightURL: b)
        XCTAssertEqual(diff.chapterDiffs.count, 2)
        XCTAssertTrue(diff.chapterDiffs[1].isLeftMissing)
        XCTAssertFalse(diff.chapterDiffs[1].isRightMissing)
    }

    // MARK: - Reporter

    func test_report_includes_summary_and_per_chapter_blocks() throws {
        let a = try buildEPUB(name: "a.epub", chapters: [
            ("Chapter 1", "Old paragraph.")
        ])
        let b = try buildEPUB(name: "b.epub", chapters: [
            ("Chapter 1", "New paragraph.")
        ])
        let diff = try EPUBDiffer().diff(leftURL: a, rightURL: b)
        let report = EPUBDiffReporter.report(diff)
        XCTAssertTrue(report.contains("a.epub"))
        XCTAssertTrue(report.contains("b.epub"))
        XCTAssertTrue(report.contains("@@ Chapter 1"))
        XCTAssertTrue(report.contains("- Old paragraph."))
        XCTAssertTrue(report.contains("+ New paragraph."))
    }

    func test_report_for_identical_books_says_no_changes() throws {
        let a = try buildEPUB(name: "a.epub", chapters: [
            ("Chapter 1", "Same.")
        ])
        let b = try buildEPUB(name: "b.epub", chapters: [
            ("Chapter 1", "Same.")
        ])
        let diff = try EPUBDiffer().diff(leftURL: a, rightURL: b)
        let report = EPUBDiffReporter.report(diff)
        XCTAssertTrue(report.contains("No paragraph-level changes"))
    }

    // MARK: - Fixture builder

    /// Build a tiny EPUB with the given (chapterTitle, paragraphs…)
    /// tuples. Each chapter gets a heading + paragraph blocks.
    private func buildEPUB(
        name: String, chapters: [(String, String, String?, String?)]
    ) throws -> URL {
        let chapterDocs: [Chapter] = chapters.map { tuple in
            var blocks: [Block] = [
                .heading(level: 1, runs: [InlineRun(tuple.0)])
            ]
            blocks.append(.paragraph(runs: [InlineRun(tuple.1)]))
            if let p = tuple.2 {
                blocks.append(.paragraph(runs: [InlineRun(p)]))
            }
            if let p = tuple.3 {
                blocks.append(.paragraph(runs: [InlineRun(p)]))
            }
            return Chapter(title: tuple.0, blocks: blocks)
        }
        let book = Book(
            title: name.replacingOccurrences(of: ".epub", with: ""),
            language: .en,
            chapters: chapterDocs
        )
        let outURL = tempDir.appendingPathComponent(name)
        try EPUBBuilder().write(book: book, to: outURL)
        return outURL
    }

    private func buildEPUB(
        name: String, chapters: [(String, String)]
    ) throws -> URL {
        try buildEPUB(name: name, chapters: chapters.map { ($0.0, $0.1, nil, nil) })
    }

    private func buildEPUB(
        name: String, chapters: [(String, String, String)]
    ) throws -> URL {
        try buildEPUB(name: name, chapters: chapters.map { ($0.0, $0.1, $0.2, nil) })
    }
}
