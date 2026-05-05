import XCTest
import CoreGraphics
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

    // MARK: - figures

    func test_chapter_with_figure_writes_image_bytes_and_manifests_it() throws {
        // 8-byte PNG-like signature only; readers don't validate inside
        // the EPUB, and the test only checks plumbing.
        let pngStub: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let asset = FigureAsset(
            id: "fig-00001",
            data: Data(pngStub),
            mediaType: "image/png",
            intrinsicSize: CGSize(width: 320, height: 240),
            isCover: false
        )
        let book = Book(
            title: "Figure Test",
            language: .en,
            chapters: [
                Chapter(
                    title: "Chapter One",
                    blocks: [
                        .heading(level: 1, runs: [InlineRun("Chapter One")]),
                        .paragraph(runs: [InlineRun("Before the figure.")]),
                        .figure(
                            assetId: "fig-00001",
                            alt: "A drawing",
                            caption: [InlineRun("Figure 1. Sample.")]
                        ),
                        .paragraph(runs: [InlineRun("After the figure.")]),
                    ],
                    figureAssets: [asset]
                ),
            ]
        )

        let outputURL = makeTempURL(ext: "epub")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try EPUBBuilder(modificationDate: fixedDate).write(book: book, to: outputURL)

        guard let archive = Archive(url: outputURL, accessMode: .read) else {
            XCTFail("Could not open produced EPUB"); return
        }
        let paths = Set(archive.map(\.path))
        XCTAssertTrue(paths.contains("OEBPS/images/fig-00001.png"),
                      "Image bytes should land in OEBPS/images/")

        // Manifest entry exists and points at the right href + media-type.
        let opf = try readEntry("OEBPS/content.opf", from: archive)
        XCTAssertTrue(opf.contains("href=\"images/fig-00001.png\""))
        XCTAssertTrue(opf.contains("media-type=\"image/png\""))

        // XHTML references the asset via the relative `../images/` href.
        let xhtml = try readEntry("OEBPS/text/chapter-001.xhtml", from: archive)
        XCTAssertTrue(xhtml.contains("<figure>"),
                      "XHTML should contain a <figure> element")
        XCTAssertTrue(xhtml.contains(#"src="../images/fig-00001.png""#))
        XCTAssertTrue(xhtml.contains(#"alt="A drawing""#))
        XCTAssertTrue(xhtml.contains("<figcaption>Figure 1. Sample.</figcaption>"))
        // The intrinsic size makes it through as width / height attrs.
        XCTAssertTrue(xhtml.contains(#"width="320""#))
        XCTAssertTrue(xhtml.contains(#"height="240""#))
    }

    func test_cover_asset_carries_cover_image_property_in_manifest() throws {
        let pngStub: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let coverAsset = FigureAsset(
            id: "fig-00000",
            data: Data(pngStub),
            mediaType: "image/png",
            isCover: true
        )
        let book = Book(
            title: "Cover Test",
            language: .en,
            chapters: [
                Chapter(
                    title: "Front Matter",
                    blocks: [
                        .figure(assetId: "fig-00000", alt: "cover", caption: []),
                    ],
                    figureAssets: [coverAsset]
                ),
            ]
        )
        let outputURL = makeTempURL(ext: "epub")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try EPUBBuilder(modificationDate: fixedDate).write(book: book, to: outputURL)

        guard let archive = Archive(url: outputURL, accessMode: .read) else {
            XCTFail("Could not open produced EPUB"); return
        }
        let opf = try readEntry("OEBPS/content.opf", from: archive)
        XCTAssertTrue(opf.contains("properties=\"cover-image\""),
                      "Cover asset should carry properties=\"cover-image\"")
    }

    func test_figure_without_caption_omits_figcaption_element() throws {
        let pngStub: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let asset = FigureAsset(
            id: "fig-99999",
            data: Data(pngStub),
            mediaType: "image/png"
        )
        let book = Book(
            title: "No Caption",
            language: .en,
            chapters: [
                Chapter(
                    title: "Ch",
                    blocks: [.figure(assetId: "fig-99999", alt: "x", caption: [])],
                    figureAssets: [asset]
                ),
            ]
        )
        let outputURL = makeTempURL(ext: "epub")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try EPUBBuilder(modificationDate: fixedDate).write(book: book, to: outputURL)

        guard let archive = Archive(url: outputURL, accessMode: .read) else {
            XCTFail("Could not open produced EPUB"); return
        }
        let xhtml = try readEntry("OEBPS/text/chapter-001.xhtml", from: archive)
        XCTAssertTrue(xhtml.contains("<figure>"))
        XCTAssertFalse(xhtml.contains("<figcaption>"),
                       "Empty caption ⇒ no <figcaption> element")
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
