import XCTest
import Document
@testable import EPUB

/// End-to-end tests for the File Tools → EPUB Join / Split commands.
/// Builds tiny EPUB fixtures via `EPUBBuilder` (the same writer
/// shipping books use), runs the operations, re-opens the output via
/// `EPUBBookLoader`, and asserts the manifest / spine / chapter
/// layout matches the user-visible expectation.
final class EPUBJoinerSplitterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBJoinerSplitterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Joiner

    func test_join_concatenates_chapters_in_input_order() throws {
        let a = try buildEPUB(name: "a.epub", chapterCount: 3, title: "Book A")
        let b = try buildEPUB(name: "b.epub", chapterCount: 2, title: "Book B")
        let outURL = tempDir.appendingPathComponent("joined.epub")

        let result = try EPUBJoiner().join(
            sourceURLs: [a, b], outputURL: outURL, title: "Combined"
        )
        XCTAssertEqual(result.chapterCount, 5)
        XCTAssertEqual(result.sourceCount, 2)

        // Re-open the merged EPUB and walk it.
        let merged = try EPUBBook.open(epubURL: outURL)
        XCTAssertEqual(merged.spine.count, 5)
        // Each source's chapters live under its own book-NN/ prefix.
        let chapterHrefs = merged.spine.compactMap {
            merged.resourcesByID[$0]?.hrefRelativeToOPF
        }
        XCTAssertTrue(chapterHrefs.allSatisfy { $0.contains("book-") })
        // Source #1 chapters come first (book-01); source #2 follow.
        let firstThree = Array(chapterHrefs.prefix(3))
        XCTAssertTrue(firstThree.allSatisfy { $0.hasPrefix("book-01/") })
        let lastTwo = Array(chapterHrefs.suffix(2))
        XCTAssertTrue(lastTwo.allSatisfy { $0.hasPrefix("book-02/") })
    }

    func test_join_uses_explicit_title_when_supplied() throws {
        let a = try buildEPUB(name: "a.epub", chapterCount: 1, title: "Original")
        let outURL = tempDir.appendingPathComponent("joined.epub")
        try EPUBJoiner().join(
            sourceURLs: [a], outputURL: outURL, title: "Renamed"
        )
        let merged = try EPUBBook.open(epubURL: outURL)
        XCTAssertEqual(merged.metadata.title, "Renamed")
    }

    func test_join_falls_back_to_first_source_title() throws {
        let a = try buildEPUB(name: "a.epub", chapterCount: 1, title: "Source One")
        let b = try buildEPUB(name: "b.epub", chapterCount: 1, title: "Source Two")
        let outURL = tempDir.appendingPathComponent("joined.epub")
        try EPUBJoiner().join(sourceURLs: [a, b], outputURL: outURL)
        let merged = try EPUBBook.open(epubURL: outURL)
        XCTAssertEqual(merged.metadata.title, "Source One")
    }

    func test_join_throws_on_empty_input() {
        XCTAssertThrowsError(
            try EPUBJoiner().join(
                sourceURLs: [],
                outputURL: tempDir.appendingPathComponent("x.epub")
            )
        ) { error in
            guard case EPUBJoiner.JoinError.noInput = error else {
                XCTFail("expected noInput, got \(error)")
                return
            }
        }
    }

    // MARK: - Splitter

    func test_split_into_two_parts_by_chapter_range() throws {
        let source = try buildEPUB(name: "src.epub", chapterCount: 6, title: "Source")
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true
        )

        let parts: [EPUBSplitter.Part] = [
            .init(chapterIndexes: Array(0...2)),
            .init(chapterIndexes: Array(3...5))
        ]
        let result = try EPUBSplitter().split(
            sourceURL: source, outputDirectory: outDir, parts: parts
        )
        XCTAssertEqual(result.outputURLs.count, 2)
        XCTAssertEqual(result.totalChapters, 6)

        for (i, url) in result.outputURLs.enumerated() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let part = try EPUBBook.open(epubURL: url)
            XCTAssertEqual(part.spine.count, 3, "part \(i + 1) should have 3 chapters")
            // Title carries part suffix.
            XCTAssertTrue(part.metadata.title?.contains("Part \(i + 1)") == true)
        }
    }

    func test_split_throws_on_out_of_bounds_chapter() throws {
        let source = try buildEPUB(name: "src.epub", chapterCount: 2, title: "Source")
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true
        )
        let parts: [EPUBSplitter.Part] = [.init(chapterIndexes: [0, 5])]
        XCTAssertThrowsError(
            try EPUBSplitter().split(
                sourceURL: source, outputDirectory: outDir, parts: parts
            )
        ) { error in
            guard case EPUBSplitter.SplitError.invalidChapterIndex = error else {
                XCTFail("expected invalidChapterIndex, got \(error)")
                return
            }
        }
    }

    func test_split_throws_on_empty_parts() throws {
        let source = try buildEPUB(name: "src.epub", chapterCount: 2, title: "Source")
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true
        )
        XCTAssertThrowsError(
            try EPUBSplitter().split(
                sourceURL: source, outputDirectory: outDir, parts: []
            )
        ) { error in
            guard case EPUBSplitter.SplitError.emptyParts = error else {
                XCTFail("expected emptyParts, got \(error)")
                return
            }
        }
    }

    func test_split_then_join_recovers_chapter_count() throws {
        let source = try buildEPUB(name: "src.epub", chapterCount: 4, title: "Source")
        let outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true
        )
        let parts: [EPUBSplitter.Part] = [
            .init(chapterIndexes: [0, 1]),
            .init(chapterIndexes: [2, 3])
        ]
        let split = try EPUBSplitter().split(
            sourceURL: source, outputDirectory: outDir, parts: parts
        )
        let joinedURL = tempDir.appendingPathComponent("joined.epub")
        let join = try EPUBJoiner().join(
            sourceURLs: split.outputURLs, outputURL: joinedURL
        )
        XCTAssertEqual(join.chapterCount, 4)
    }

    // MARK: - Fixture builder

    /// Build a minimal EPUB on disk via `EPUBBuilder` (the production
    /// writer). Each chapter contains a heading + a paragraph so
    /// `firstHeadingTitle` has something to extract.
    private func buildEPUB(
        name: String, chapterCount: Int, title: String
    ) throws -> URL {
        let chapters: [Chapter] = (0..<chapterCount).map { i in
            Chapter(
                title: "Chapter \(i + 1)",
                blocks: [
                    .heading(level: 1, runs: [InlineRun("Chapter \(i + 1)")]),
                    .paragraph(runs: [InlineRun("Body of chapter \(i + 1).")])
                ]
            )
        }
        let book = Book(
            title: title,
            language: .en,
            chapters: chapters
        )
        let outURL = tempDir.appendingPathComponent(name)
        try EPUBBuilder().write(book: book, to: outURL)
        return outURL
    }
}
