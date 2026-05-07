import XCTest
import Foundation
import Document
import EPUB
@testable import Humanist

/// `BulkEditor.replace` against real EPUB fixtures built via
/// `EPUBBuilder` — exercises the full open → search → replace →
/// repack round-trip for one or more books.
final class BulkEditorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-editor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// Build a minimal real EPUB at `outputName.epub` containing
    /// the given inline body text in its single chapter.
    private func makeFixture(name: String, body: String) throws -> URL {
        let book = Book(
            title: name,
            author: "Test",
            language: .en,
            chapters: [
                Chapter(
                    title: "Chapter 1",
                    blocks: [
                        .heading(level: 1, runs: [InlineRun(name)]),
                        .paragraph(runs: [InlineRun(body)]),
                    ]
                ),
            ]
        )
        let url = tempDir.appendingPathComponent("\(name).epub")
        try EPUBBuilder().write(book: book, to: url)
        return url
    }

    /// Read the `chapter-001.xhtml` text out of an EPUB so we can
    /// assert on what the bulk edit actually wrote. Re-opens the
    /// EPUB into a fresh working dir; the BulkEditor's repack
    /// should have flushed its changes by the time we get here.
    private func readChapterOne(from epubURL: URL) throws -> String {
        let pkg = try EPUBPackage.open(epubURL: epubURL)
        let xhtmlURL = pkg.workingDirectory
            .appendingPathComponent("OEBPS/text/chapter-001.xhtml")
        return try String(contentsOf: xhtmlURL)
    }

    // MARK: - tests

    func test_replace_applies_query_across_books_in_place() throws {
        let a = try makeFixture(name: "A", body: "the quick brown fox")
        let b = try makeFixture(name: "B", body: "another fox passage")

        let results = BulkEditor().replace(
            in: [a, b],
            query: "fox",
            replacement: "FOX",
            caseSensitive: false,
            regex: false
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].epubURL, a)
        XCTAssertEqual(results[0].totalReplacements, 1)
        XCTAssertNil(results[0].error)
        XCTAssertEqual(results[1].totalReplacements, 1)

        let aBody = try readChapterOne(from: a)
        XCTAssertTrue(aBody.contains("FOX"))
        XCTAssertFalse(aBody.contains(" fox "))
        let bBody = try readChapterOne(from: b)
        XCTAssertTrue(bBody.contains("FOX"))
    }

    func test_replace_skips_repack_when_no_matches() throws {
        let url = try makeFixture(name: "Untouched", body: "no relevant text")
        let mtimeBefore = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        // Sleep briefly so a same-mtime "did the file get rewritten"
        // assertion is meaningful even on filesystems with 1-second
        // mtime granularity.
        Thread.sleep(forTimeInterval: 1.1)

        let results = BulkEditor().replace(
            in: [url],
            query: "absolutely-not-in-this-document",
            replacement: "X"
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].totalReplacements, 0)
        XCTAssertNil(results[0].error)

        let mtimeAfter = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(mtimeBefore, mtimeAfter,
            "EPUB with no matches must not be rewritten — saves wear, preserves backups")
    }

    func test_replace_returns_per_book_result_for_failed_open() throws {
        let real = try makeFixture(name: "Real", body: "hello")
        let bogus = tempDir.appendingPathComponent("does-not-exist.epub")

        let results = BulkEditor().replace(
            in: [real, bogus],
            query: "hello",
            replacement: "world"
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertNil(results[0].error,
            "real EPUB should still be processed when a sibling fails")
        XCTAssertEqual(results[0].totalReplacements, 1)
        XCTAssertNotNil(results[1].error,
            "missing EPUB should produce a per-book error, not abort the batch")
    }

    func test_replace_with_empty_query_returns_zero_results() throws {
        let url = try makeFixture(name: "X", body: "anything")
        let results = BulkEditor().replace(
            in: [url],
            query: "",
            replacement: "y"
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].totalReplacements, 0)
        XCTAssertNil(results[0].error)
    }

    func test_replace_honors_case_sensitive_flag() throws {
        let url = try makeFixture(name: "Case", body: "Fox fox FOX")
        let results = BulkEditor().replace(
            in: [url],
            query: "fox",
            replacement: "X",
            caseSensitive: true,
            regex: false
        )
        // Only the lowercase `fox` should match.
        XCTAssertEqual(results[0].totalReplacements, 1)
        let body = try readChapterOne(from: url)
        XCTAssertTrue(body.contains("Fox X FOX"))
    }

    func test_replace_progress_callback_fires_per_book() throws {
        let urls = try (0..<3).map { try makeFixture(name: "P\($0)", body: "x") }
        var seen: [Int] = []
        _ = BulkEditor().replace(
            in: urls,
            query: "x", replacement: "y",
            progress: { idx, _ in seen.append(idx) }
        )
        XCTAssertEqual(seen, [0, 1, 2])
    }
}
