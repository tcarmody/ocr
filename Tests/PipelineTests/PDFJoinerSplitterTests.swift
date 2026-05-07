import XCTest
import PDFKit
import AppKit
@testable import PDFIngest

/// End-to-end tests for the File Tools → PDF Join / Split commands.
/// Builds tiny PDF fixtures on disk via PDFKit, runs the operations,
/// re-opens the output, and asserts page counts + that the bytes
/// round-trip through PDFKit cleanly.
final class PDFJoinerSplitterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFJoinerSplitterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Joiner

    func test_join_two_PDFs_concatenates_pages() throws {
        let a = try writePDF(name: "a.pdf", pages: 3)
        let b = try writePDF(name: "b.pdf", pages: 2)

        let joined = try PDFJoiner.join(urls: [a, b])
        let doc = try XCTUnwrap(PDFDocument(data: joined))
        XCTAssertEqual(doc.pageCount, 5)
    }

    func test_join_preserves_input_order() throws {
        // Tag each PDF's pages with a different size so we can tell
        // them apart in the output. PDFPage(image:) sets mediaBox
        // from the image — different image sizes → different
        // mediaBox sizes.
        let a = try writePDF(name: "a.pdf", pages: 2, pageSize: NSSize(width: 100, height: 100))
        let b = try writePDF(name: "b.pdf", pages: 2, pageSize: NSSize(width: 200, height: 100))

        let joined = try PDFJoiner.join(urls: [a, b])
        let doc = try XCTUnwrap(PDFDocument(data: joined))
        XCTAssertEqual(doc.pageCount, 4)
        // First two pages should be from `a` (100x100); last two from `b`.
        let firstBox = doc.page(at: 0)?.bounds(for: .mediaBox).size
        let lastBox = doc.page(at: 3)?.bounds(for: .mediaBox).size
        XCTAssertEqual(firstBox?.width, 100)
        XCTAssertEqual(lastBox?.width, 200)
    }

    func test_join_throws_on_empty_input() {
        XCTAssertThrowsError(try PDFJoiner.join(urls: [])) { error in
            guard case PDFJoiner.JoinError.noInput = error else {
                XCTFail("expected noInput, got \(error)")
                return
            }
        }
    }

    func test_join_throws_on_invalid_pdf_url() throws {
        let bogus = tempDir.appendingPathComponent("not-a-pdf.pdf")
        try Data("hello".utf8).write(to: bogus)
        XCTAssertThrowsError(try PDFJoiner.join(urls: [bogus])) { error in
            guard case PDFJoiner.JoinError.invalidPDF = error else {
                XCTFail("expected invalidPDF, got \(error)")
                return
            }
        }
    }

    // MARK: - Splitter

    func test_split_into_two_chunks_by_range() throws {
        let source = try writePDF(name: "long.pdf", pages: 10)
        // 0-based, inclusive; matches PageRangeParser output.
        let chunks = try PDFSplitter.split(
            url: source, ranges: [0...4, 5...9]
        )
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(PDFDocument(data: chunks[0].data)?.pageCount, 5)
        XCTAssertEqual(PDFDocument(data: chunks[1].data)?.pageCount, 5)
    }

    func test_split_throws_on_out_of_bounds_range() throws {
        let source = try writePDF(name: "src.pdf", pages: 3)
        XCTAssertThrowsError(try PDFSplitter.split(url: source, ranges: [0...10])) { error in
            guard case PDFSplitter.SplitError.rangeOutOfBounds = error else {
                XCTFail("expected rangeOutOfBounds, got \(error)")
                return
            }
        }
    }

    func test_split_throws_on_empty_ranges() throws {
        let source = try writePDF(name: "src.pdf", pages: 3)
        XCTAssertThrowsError(try PDFSplitter.split(url: source, ranges: [])) { error in
            guard case PDFSplitter.SplitError.emptyRanges = error else {
                XCTFail("expected emptyRanges, got \(error)")
                return
            }
        }
    }

    func test_split_then_join_round_trips_pageCount() throws {
        let source = try writePDF(name: "src.pdf", pages: 6)
        let chunks = try PDFSplitter.split(
            url: source, ranges: [0...2, 3...5]
        )
        // Write chunks to disk, then join them back.
        let aURL = tempDir.appendingPathComponent("a.pdf")
        let bURL = tempDir.appendingPathComponent("b.pdf")
        try chunks[0].data.write(to: aURL)
        try chunks[1].data.write(to: bURL)
        let joined = try PDFJoiner.join(urls: [aURL, bURL])
        let doc = try XCTUnwrap(PDFDocument(data: joined))
        XCTAssertEqual(doc.pageCount, 6)
    }

    // MARK: - Fixture helpers

    private func writePDF(
        name: String,
        pages: Int,
        pageSize: NSSize = NSSize(width: 100, height: 100)
    ) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let doc = PDFDocument()
        for i in 0..<pages {
            doc.insert(makePage(size: pageSize), at: i)
        }
        XCTAssertTrue(doc.write(to: url))
        return url
    }

    private func makePage(size: NSSize) -> PDFPage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return PDFPage(image: img)!
    }
}
