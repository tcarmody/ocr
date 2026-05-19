import XCTest
import Foundation
import Document
import EPUB
@testable import Humanist

/// R-Reader. `ReaderTOC.build` against real EPUBs produced by
/// `EPUBBuilder`. Covers the nav.xhtml path (Humanist-emitted
/// EPUBs all carry nav.xhtml) plus the helper-method behaviors
/// the parser leans on (href resolution, normalization).
final class ReaderTOCTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-toc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - End-to-end via EPUBBuilder

    func test_builds_toc_from_humanist_emitted_nav_xhtml() throws {
        let book = Book(
            title: "Test",
            author: "Author",
            language: .en,
            chapters: [
                Chapter(title: "Introduction",
                        blocks: [.heading(level: 1, runs: [InlineRun("Introduction")])]),
                Chapter(title: "Chapter One",
                        blocks: [.heading(level: 1, runs: [InlineRun("Chapter One")])]),
                Chapter(title: "Chapter Two",
                        blocks: [.heading(level: 1, runs: [InlineRun("Chapter Two")])]),
            ]
        )
        let url = tempDir.appendingPathComponent("toc.epub")
        try EPUBBuilder().write(book: book, to: url)
        let opened = try EPUBBook.open(epubURL: url)
        let toc = ReaderTOC.build(from: opened)
        // Exactly one entry per spine item.
        XCTAssertEqual(toc.entries.count, opened.spine.count)
        XCTAssertEqual(toc.entries.map(\.title),
                       ["Introduction", "Chapter One", "Chapter Two"])
        // Entries map to ascending spine indices (flat TOC).
        XCTAssertEqual(toc.entries.map(\.spineIndex), [0, 1, 2])
    }

    func test_toc_titles_survive_special_chars_in_chapter_title() throws {
        let book = Book(
            title: "Mixed",
            author: "Author",
            language: .en,
            chapters: [
                Chapter(title: "Foo & Bar",
                        blocks: [.heading(level: 1, runs: [InlineRun("Foo & Bar")])]),
                Chapter(title: "α — Σίγα",
                        blocks: [.heading(level: 1, runs: [InlineRun("α — Σίγα")])]),
            ]
        )
        let url = tempDir.appendingPathComponent("mixed.epub")
        try EPUBBuilder().write(book: book, to: url)
        let opened = try EPUBBook.open(epubURL: url)
        let toc = ReaderTOC.build(from: opened)
        XCTAssertEqual(toc.entries.count, 2)
        XCTAssertEqual(toc.entries[0].title, "Foo & Bar")
        XCTAssertEqual(toc.entries[1].title, "α — Σίγα")
    }

    // MARK: - Helper methods

    func test_normalize_collapses_dot_segments() {
        XCTAssertEqual(
            ReaderTOC.normalize(href: "text/../text/chapter-1.xhtml"),
            "text/chapter-1.xhtml"
        )
        XCTAssertEqual(
            ReaderTOC.normalize(href: "./text/chapter-1.xhtml"),
            "text/chapter-1.xhtml"
        )
    }

    func test_normalize_percent_decodes_path() {
        XCTAssertEqual(
            ReaderTOC.normalize(href: "text/Table%20of%20Contents.xhtml"),
            "text/Table of Contents.xhtml"
        )
    }

    func test_resolveHref_strips_fragment_and_joins_nav_dir() {
        let resolved = ReaderTOC.resolveHref(
            "chapter-3.xhtml#section-2",
            againstNavDirectory: "text"
        )
        XCTAssertEqual(resolved, "text/chapter-3.xhtml")
    }

    func test_resolveHref_handles_parent_segments() {
        let resolved = ReaderTOC.resolveHref(
            "../images/cover.jpg",
            againstNavDirectory: "OEBPS/text"
        )
        XCTAssertEqual(resolved, "OEBPS/images/cover.jpg")
    }

    func test_resolveHref_empty_path_returns_nil() {
        XCTAssertNil(ReaderTOC.resolveHref(
            "#fragment-only", againstNavDirectory: "text"
        ))
    }
}
