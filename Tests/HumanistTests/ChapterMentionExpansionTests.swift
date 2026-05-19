import XCTest
import Foundation
import Document
import EPUB
@testable import Humanist

/// `BookChatViewModel.expandQueryMentionedChapters` resolves
/// explicit chapter / notebook references in the user's query
/// into spine indices for force-include in the rendered context.
/// Covers the numeric-kind regex matrix, named-keyword matching,
/// and the cap on how many chapters can expand at once.
@MainActor
final class ChapterMentionExpansionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mention-expansion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Numeric kinds

    func test_chapter_numeric_match() throws {
        let vm = try makeVM(chapterTitles: [
            "Preface", "Chapter 1", "Chapter 2", "Chapter 13",
        ])
        XCTAssertEqual(
            vm.expandQueryMentionedChapters(query: "What's in chapter 13?"),
            [3]
        )
    }

    func test_notebook_numeric_match() throws {
        // Wittgenstein-style title scheme.
        let vm = try makeVM(chapterTitles: [
            "Preface", "Notebook 1", "Notebook 10", "Notebook 13", "Notebook 23",
        ])
        let matched = vm.expandQueryMentionedChapters(
            query: "Summarize Notebooks 10 and 13."
        )
        XCTAssertEqual(matched, [2, 3])
    }

    func test_chapter_abbreviation_matches() throws {
        let vm = try makeVM(chapterTitles: ["Chapter 5", "Chapter 6"])
        // "ch. 5" and "ch 6" should both resolve.
        let matched = vm.expandQueryMentionedChapters(query: "Compare ch. 5 with ch 6.")
        XCTAssertEqual(matched, [0, 1])
    }

    func test_title_equals_number_match() throws {
        // Books that title chapters with bare numerals ("1", "2", …).
        let vm = try makeVM(chapterTitles: ["Preface", "1", "2", "13"])
        let matched = vm.expandQueryMentionedChapters(
            query: "What does chapter 13 say?"
        )
        XCTAssertEqual(matched, [3])
    }

    // MARK: - Named entries

    func test_preface_matches() throws {
        let vm = try makeVM(chapterTitles: ["Preface", "Chapter 1"])
        XCTAssertEqual(
            vm.expandQueryMentionedChapters(query: "Explain the preface."),
            [0]
        )
    }

    func test_introduction_and_conclusion() throws {
        let vm = try makeVM(chapterTitles: [
            "Introduction", "Chapter 1", "Chapter 2", "Conclusion",
        ])
        let matched = vm.expandQueryMentionedChapters(
            query: "Compare the introduction with the conclusion."
        )
        XCTAssertEqual(matched, [0, 3])
    }

    // MARK: - Non-matches

    func test_no_mention_returns_empty() throws {
        let vm = try makeVM(chapterTitles: ["Chapter 1", "Chapter 2"])
        XCTAssertTrue(vm.expandQueryMentionedChapters(
            query: "What did the author argue about modernity?"
        ).isEmpty)
    }

    func test_roman_numerals_not_matched() throws {
        // V1 deliberately skips Roman numerals — false-positive
        // risk on common words ("I", "V") too high.
        let vm = try makeVM(chapterTitles: ["Chapter 1", "Chapter 2"])
        XCTAssertTrue(vm.expandQueryMentionedChapters(
            query: "What's in chapter IV?"
        ).isEmpty)
    }

    func test_substring_does_not_match_keyword() throws {
        // "preface" is a substring of "interfacial" but the
        // keyword-equality check shouldn't trigger because the
        // chapter title doesn't equal "preface".
        let vm = try makeVM(chapterTitles: ["Chapter 1", "Chapter 2"])
        XCTAssertTrue(vm.expandQueryMentionedChapters(
            query: "What does the preface say?"
        ).isEmpty)
    }

    // MARK: - Cap

    func test_cap_at_six_chapters() throws {
        let titles = (1...10).map { "Chapter \($0)" }
        let vm = try makeVM(chapterTitles: titles)
        let q = (1...10)
            .map { "chapter \($0)" }
            .joined(separator: ", ")
        let matched = vm.expandQueryMentionedChapters(query: q)
        XCTAssertEqual(matched.count, 6)
    }

    // MARK: - Helpers

    /// Build a real EPUB with the requested chapter titles, open
    /// it into an EPUBBook, and instantiate a BookChatViewModel.
    /// The VM kicks off background embedding builds in init —
    /// we don't wait on those; the regex-based mention extractor
    /// runs purely against in-memory chapter titles.
    private func makeVM(chapterTitles: [String]) throws -> BookChatViewModel {
        let chapters: [Chapter] = chapterTitles.map { title in
            Chapter(
                title: title,
                blocks: [
                    .heading(level: 1, runs: [InlineRun(title)]),
                    .paragraph(runs: [InlineRun("Body text for \(title).")]),
                ]
            )
        }
        let book = Book(
            title: "Test",
            author: "Author",
            language: .en,
            chapters: chapters
        )
        let url = tempDir.appendingPathComponent("mention-test.epub")
        try EPUBBuilder().write(book: book, to: url)
        let opened = try EPUBBook.open(epubURL: url)
        return BookChatViewModel(book: opened, epubURL: url)
    }
}
