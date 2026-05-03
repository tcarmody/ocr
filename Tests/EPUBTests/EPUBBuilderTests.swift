import XCTest
import Foundation
import Document
@testable import EPUB
import ZIPFoundation

final class EPUBBuilderTests: XCTestCase {

    func test_endToEnd_minimalBookProducesValidStructure() throws {
        let book = Book(
            title: "Test Book",
            author: "Test Author",
            language: .en,
            chapters: [
                Chapter(title: "Chapter 1", blocks: [
                    .heading(level: 1, runs: [InlineRun("Hello")]),
                    .paragraph(runs: [
                        InlineRun("Some English text. "),
                        InlineRun("ἐν ἀρχῇ ἦν ὁ λόγος", language: .grc),
                        InlineRun(" — quoted in the body."),
                    ]),
                ]),
            ]
        )

        let outputURL = makeTempURL(ext: "epub")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try EPUBBuilder(modificationDate: fixedDate).write(book: book, to: outputURL)

        // Open the produced archive and verify the file inventory matches
        // what we expect a minimal EPUB 3 to contain.
        guard let archive = Archive(url: outputURL, accessMode: .read) else {
            XCTFail("Could not open produced EPUB as archive"); return
        }
        let paths = Set(archive.map(\.path))
        let expected: Set<String> = [
            "mimetype",
            "META-INF/container.xml",
            "OEBPS/css/book.css",
            "OEBPS/text/chapter-001.xhtml",
            "OEBPS/nav.xhtml",
            "OEBPS/content.opf",
        ]
        XCTAssertEqual(paths, expected)

        // Spot-check that polytonic Greek made it through with xml:lang.
        let xhtml = try readEntry("OEBPS/text/chapter-001.xhtml", from: archive)
        XCTAssertTrue(xhtml.contains(#"xml:lang="grc""#),
                      "Greek inline run should produce a span with xml:lang=\"grc\"")
        XCTAssertTrue(xhtml.contains("ἐν ἀρχῇ"),
                      "Polytonic Greek text must round-trip unmodified")

        // Spot-check OPF metadata.
        let opf = try readEntry("OEBPS/content.opf", from: archive)
        XCTAssertTrue(opf.contains("<dc:title>Test Book</dc:title>"))
        XCTAssertTrue(opf.contains("<dc:creator>Test Author</dc:creator>"))
        XCTAssertTrue(opf.contains("<dc:language>en</dc:language>"))
        XCTAssertTrue(opf.contains("properties=\"nav\""),
                      "Nav doc must be marked properties=\"nav\" in the manifest")
    }

    // MARK: helpers

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14

    private func makeTempURL(ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub-builder-test-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    private func readEntry(_ path: String, from archive: Archive) throws -> String {
        guard let entry = archive[path] else {
            throw NSError(domain: "EPUBBuilderTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Entry not found: \(path)"
            ])
        }
        var collected = Data()
        _ = try archive.extract(entry, consumer: { collected.append($0) })
        return String(data: collected, encoding: .utf8) ?? ""
    }
}
