import XCTest
import Foundation
@testable import EPUB

final class PackageSearchTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackageSearchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - basic search

    func test_search_finds_substring_across_files() throws {
        let urlA = tempDir.appendingPathComponent("a.xhtml")
        let urlB = tempDir.appendingPathComponent("b.xhtml")
        try "line one\nfoo bar\nline three".write(
            to: urlA, atomically: true, encoding: .utf8
        )
        try "no match here\nanother foo\nend".write(
            to: urlB, atomically: true, encoding: .utf8
        )
        let provider: (URL) -> String? = {
            try? String(contentsOf: $0, encoding: .utf8)
        }
        let hits = try PackageSearch().search(
            in: [urlA, urlB],
            query: "foo",
            contentProvider: provider
        )
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].fileURL, urlA)
        XCTAssertEqual(hits[0].line, 2)
        XCTAssertEqual(hits[0].lineText, "foo bar")
        XCTAssertEqual(hits[1].fileURL, urlB)
        XCTAssertEqual(hits[1].line, 2)
        XCTAssertEqual(hits[1].lineText, "another foo")
    }

    func test_search_is_case_insensitive_by_default() throws {
        let url = tempDir.appendingPathComponent("a.xhtml")
        try "Foo\nBAR\nbaz".write(to: url, atomically: true, encoding: .utf8)
        let hits = try PackageSearch().search(
            in: [url], query: "foo",
            contentProvider: { try? String(contentsOf: $0, encoding: .utf8) }
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].lineText, "Foo")
    }

    func test_search_case_sensitive_distinguishes() throws {
        let url = tempDir.appendingPathComponent("a.xhtml")
        try "Foo\nfoo\nFOO".write(to: url, atomically: true, encoding: .utf8)
        let hits = try PackageSearch().search(
            in: [url], query: "foo", caseSensitive: true,
            contentProvider: { try? String(contentsOf: $0, encoding: .utf8) }
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].lineText, "foo")
    }

    func test_search_regex_mode_uses_pattern() throws {
        let url = tempDir.appendingPathComponent("a.xhtml")
        try "id-1\nid-2\nname-3".write(to: url, atomically: true, encoding: .utf8)
        let hits = try PackageSearch().search(
            in: [url], query: "id-\\d", regex: true,
            contentProvider: { try? String(contentsOf: $0, encoding: .utf8) }
        )
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.map(\.lineText), ["id-1", "id-2"])
    }

    func test_search_returns_match_position_within_line() throws {
        let url = tempDir.appendingPathComponent("a.xhtml")
        try "abc target def".write(to: url, atomically: true, encoding: .utf8)
        let hits = try PackageSearch().search(
            in: [url], query: "target",
            contentProvider: { try? String(contentsOf: $0, encoding: .utf8) }
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].matchStart, 4)
        XCTAssertEqual(hits[0].matchLength, 6)
    }

    func test_search_empty_query_returns_no_hits() throws {
        let url = tempDir.appendingPathComponent("a.xhtml")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        let hits = try PackageSearch().search(
            in: [url], query: "",
            contentProvider: { try? String(contentsOf: $0, encoding: .utf8) }
        )
        XCTAssertTrue(hits.isEmpty)
    }

    func test_search_invalid_regex_throws() {
        let url = tempDir.appendingPathComponent("a.xhtml")
        try? "x".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try PackageSearch().search(
                in: [url], query: "[unterminated", regex: true,
                contentProvider: { try? String(contentsOf: $0, encoding: .utf8) }
            )
        ) { error in
            guard let searchError = error as? PackageSearch.SearchError else {
                XCTFail("expected SearchError, got \(error)")
                return
            }
            if case .invalidRegex = searchError {} else {
                XCTFail("expected invalidRegex, got \(searchError)")
            }
        }
    }

    // MARK: - replace

    func test_replaceAll_substitutes_in_every_file() throws {
        let urlA = tempDir.appendingPathComponent("a.xhtml")
        let urlB = tempDir.appendingPathComponent("b.xhtml")
        try "the cat sat".write(to: urlA, atomically: true, encoding: .utf8)
        try "another cat".write(to: urlB, atomically: true, encoding: .utf8)
        let results = try PackageSearch().replaceAll(
            in: [urlA, urlB],
            query: "cat",
            replacement: "dog",
            contentProvider: { try? String(contentsOf: $0, encoding: .utf8) }
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].newContent, "the dog sat")
        XCTAssertEqual(results[0].replacementCount, 1)
        XCTAssertEqual(results[1].newContent, "another dog")
        XCTAssertEqual(results[1].replacementCount, 1)
    }

    func test_replaceAll_skips_files_with_no_matches() throws {
        let urlA = tempDir.appendingPathComponent("a.xhtml")
        let urlB = tempDir.appendingPathComponent("b.xhtml")
        try "match here".write(to: urlA, atomically: true, encoding: .utf8)
        try "nothing here".write(to: urlB, atomically: true, encoding: .utf8)
        let results = try PackageSearch().replaceAll(
            in: [urlA, urlB], query: "match", replacement: "found",
            contentProvider: { try? String(contentsOf: $0, encoding: .utf8) }
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].fileURL, urlA)
    }

    func test_replaceAll_literal_replacement_does_not_interpret_dollar() throws {
        let url = tempDir.appendingPathComponent("a.xhtml")
        try "price was X".write(to: url, atomically: true, encoding: .utf8)
        let results = try PackageSearch().replaceAll(
            in: [url], query: "X", replacement: "$5",
            contentProvider: { try? String(contentsOf: $0, encoding: .utf8) }
        )
        // Without the escaping helper, "$5" would be interpreted as
        // "5th capture group" by NSRegularExpression and produce
        // garbage. Confirm we get the literal "$5".
        XCTAssertEqual(results.first?.newContent, "price was $5")
    }

    // MARK: - file enumeration

    func test_textFileURLs_includes_xhtml_css_opf() throws {
        let oebps = tempDir.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: oebps, withIntermediateDirectories: true
        )
        let chapter = oebps.appendingPathComponent("ch01.xhtml")
        let style = oebps.appendingPathComponent("style.css")
        let opf = oebps.appendingPathComponent("content.opf")
        let image = oebps.appendingPathComponent("cover.png")
        for url in [chapter, style, opf, image] {
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        // Compare by lastPathComponent — the enumerator's URLs may
        // resolve /var/folders → /private/var/folders, so direct URL
        // comparison fails on macOS even when the underlying file
        // matches.
        let names = Set(PackageSearch.textFileURLs(in: tempDir).map(\.lastPathComponent))
        XCTAssertTrue(names.contains("ch01.xhtml"))
        XCTAssertTrue(names.contains("style.css"))
        XCTAssertTrue(names.contains("content.opf"))
        XCTAssertFalse(names.contains("cover.png"),
            "PNG should be excluded from text-file enumeration")
    }
}
