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

    // MARK: - tables

    func test_chapter_with_table_renders_table_markup_with_caption() throws {
        let book = Book(
            title: "Table Test",
            language: .en,
            chapters: [
                Chapter(
                    title: "Ch",
                    blocks: [
                        .heading(level: 1, runs: [InlineRun("Ch")]),
                        .table(
                            rows: [
                                [
                                    TableCell(runs: [InlineRun("Author")], isHeader: true),
                                    TableCell(runs: [InlineRun("Year")], isHeader: true),
                                ],
                                [
                                    TableCell(runs: [InlineRun("Foucault")]),
                                    TableCell(runs: [InlineRun("1971")]),
                                ],
                                [
                                    TableCell(runs: [InlineRun("Weber")]),
                                    TableCell(runs: [InlineRun("1922")]),
                                ],
                            ],
                            caption: [InlineRun("Table 1: Bibliography sample.")]
                        ),
                    ]
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
        XCTAssertTrue(xhtml.contains("<table role=\"table\">"))
        XCTAssertTrue(xhtml.contains("<caption>Table 1: Bibliography sample.</caption>"))
        XCTAssertTrue(xhtml.contains("<thead>"),
                      "Leading all-header row should land in <thead>")
        XCTAssertTrue(xhtml.contains("<tbody>"))
        XCTAssertTrue(xhtml.contains("<th>Author</th><th>Year</th>"))
        XCTAssertTrue(xhtml.contains("<td>Foucault</td><td>1971</td>"))
        XCTAssertTrue(xhtml.contains("<td>Weber</td><td>1922</td>"))
    }

    func test_table_without_header_row_skips_thead() throws {
        let book = Book(
            title: "Table Test 2",
            language: .en,
            chapters: [
                Chapter(
                    title: "Ch",
                    blocks: [
                        .table(
                            rows: [
                                [
                                    TableCell(runs: [InlineRun("a")]),
                                    TableCell(runs: [InlineRun("b")]),
                                ],
                                [
                                    TableCell(runs: [InlineRun("c")]),
                                    TableCell(runs: [InlineRun("d")]),
                                ],
                            ],
                            caption: []
                        ),
                    ]
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
        XCTAssertTrue(xhtml.contains("<table role=\"table\">"))
        XCTAssertFalse(xhtml.contains("<thead>"),
                       "No header cells ⇒ no <thead>")
        XCTAssertFalse(xhtml.contains("<caption>"),
                       "Empty caption ⇒ no <caption>")
        XCTAssertTrue(xhtml.contains("<tbody>"))
    }

    func test_table_cell_with_rowspan_colspan_emits_attributes() throws {
        let book = Book(
            title: "Span Test",
            language: .en,
            chapters: [
                Chapter(
                    title: "Ch",
                    blocks: [
                        .table(
                            rows: [
                                [
                                    TableCell(runs: [InlineRun("merged")], colspan: 2),
                                ],
                                [
                                    TableCell(runs: [InlineRun("a")]),
                                    TableCell(runs: [InlineRun("b")], rowspan: 2),
                                ],
                                [
                                    TableCell(runs: [InlineRun("c")]),
                                ],
                            ],
                            caption: []
                        ),
                    ]
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
        XCTAssertTrue(xhtml.contains("colspan=\"2\""))
        XCTAssertTrue(xhtml.contains("rowspan=\"2\""))
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

    // MARK: - R-Hierarchy (nested nav)

    /// End-to-end: a chapter with H2 (chapter title) + H3 / H4
    /// sub-section headings should produce a nav.xhtml with nested
    /// `<ol>` entries, and the chapter XHTML's sub-section headings
    /// should carry the matching `id` attributes so the nav links
    /// land on the right element.
    func test_nested_nav_for_chapter_with_subsections() throws {
        let book = Book(
            title: "Hierarchy Test",
            language: .en,
            chapters: [
                Chapter(title: "The Will to Power", blocks: [
                    .heading(level: 2, runs: [InlineRun("The Will to Power")]),
                    .paragraph(runs: [InlineRun("Opening.")]),
                    .heading(level: 3, runs: [InlineRun("§1. Antitheses")]),
                    .paragraph(runs: [InlineRun("Body.")]),
                    .heading(level: 4, runs: [InlineRun("Subnote a")]),
                    .paragraph(runs: [InlineRun("Body.")]),
                    .heading(level: 3, runs: [InlineRun("§2. Higher truth")]),
                    .paragraph(runs: [InlineRun("Body.")]),
                ]),
            ]
        )

        let outputURL = makeTempURL(ext: "epub")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try EPUBBuilder(modificationDate: fixedDate).write(book: book, to: outputURL)

        guard let archive = Archive(url: outputURL, accessMode: .read) else {
            XCTFail("Could not open produced EPUB"); return
        }

        // Chapter XHTML should carry id="hu-sec-0-{n}" on each
        // sub-section heading. Block indices: H2 chapter (0),
        // p (1), H3 §1 (2), p (3), H4 (4), p (5), H3 §2 (6), p (7).
        let xhtml = try readEntry("OEBPS/text/chapter-001.xhtml", from: archive)
        XCTAssertTrue(xhtml.contains("<h3 id=\"hu-sec-0-2\">§1. Antitheses</h3>"))
        XCTAssertTrue(xhtml.contains("<h4 id=\"hu-sec-0-4\">Subnote a</h4>"))
        XCTAssertTrue(xhtml.contains("<h3 id=\"hu-sec-0-6\">§2. Higher truth</h3>"))
        // Chapter's own opening H2 must NOT get an id — that's the
        // chapter row in nav already.
        XCTAssertTrue(xhtml.contains("<h2>The Will to Power</h2>"),
            "chapter's own opening heading should not carry a sub-section id")

        // Nav.xhtml should nest the H3/H4 entries underneath the
        // chapter row. §1 has the H4 child; §2 is a leaf.
        let nav = try readEntry("OEBPS/nav.xhtml", from: archive)
        XCTAssertTrue(nav.contains("text/chapter-001.xhtml#hu-sec-0-2"))
        XCTAssertTrue(nav.contains("text/chapter-001.xhtml#hu-sec-0-4"))
        XCTAssertTrue(nav.contains("text/chapter-001.xhtml#hu-sec-0-6"))
        // Verify nesting structurally: the chapter's <li> must contain
        // a child <ol>, and §1's <li> must contain its own child <ol>
        // wrapping the H4. We're not parsing XML here, just looking
        // for the syntactic shape that has to be present.
        XCTAssertTrue(nav.contains("<ol>"),
            "nav.xhtml should contain at least one <ol>")
        let h4LiPattern = "<li><a href=\"text/chapter-001.xhtml#hu-sec-0-4\">Subnote a</a></li>"
        XCTAssertTrue(nav.contains(h4LiPattern),
            "H4 sub-subsection should render as a leaf <li> under the H3")
        // Count <ol> tags — we expect at least 3: the outer toc <ol>,
        // the chapter's child <ol>, and §1's grandchild <ol> wrapping
        // the H4. (Plus possibly a closing tag count match.)
        let openOLCount = nav.components(separatedBy: "<ol>").count - 1
        XCTAssertGreaterThanOrEqual(openOLCount, 3,
            "nested hierarchy needs ≥ 3 <ol> opens (toc + chapter + sub-section)")
    }

    /// Chapters with no sub-headings still render as flat leaf
    /// entries — no spurious empty `<ol>` children.
    func test_flat_nav_when_chapter_has_no_subsections() throws {
        let book = Book(
            title: "Flat Test",
            language: .en,
            chapters: [
                Chapter(title: "Chapter 1", blocks: [
                    .heading(level: 2, runs: [InlineRun("Chapter 1")]),
                    .paragraph(runs: [InlineRun("Body only, no sub-headings.")]),
                ]),
            ]
        )
        let outputURL = makeTempURL(ext: "epub")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try EPUBBuilder(modificationDate: fixedDate).write(book: book, to: outputURL)
        guard let archive = Archive(url: outputURL, accessMode: .read) else {
            XCTFail("Could not open produced EPUB"); return
        }
        let nav = try readEntry("OEBPS/nav.xhtml", from: archive)
        // Exactly one <ol> — the toc root. No nested <ol>.
        let openOLCount = nav.components(separatedBy: "<ol>").count - 1
        XCTAssertEqual(openOLCount, 1,
            "no sub-sections ⇒ no nested <ol> in nav")
        let xhtml = try readEntry("OEBPS/text/chapter-001.xhtml", from: archive)
        XCTAssertFalse(xhtml.contains("hu-sec-"),
            "no sub-sections ⇒ no hu-sec-* ids on headings")
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
