import XCTest
import Foundation
import EPUB
@testable import Humanist

/// Coverage for `LibraryStore.locateSourcePDFForRescan` — the
/// probe-chain helper the R-Library-Rescan flow uses to find the
/// original source PDF for an existing catalog entry. Three probe
/// sites in priority order: cheap heuristics (sibling / output
/// root / `Input/`), the EPUB's `<dc:source>` metadata, and the
/// entry's `priorPaths` list (filtered to `.pdf`).
@MainActor
final class LibraryRescanResolverTests: XCTestCase {

    private var tempDir: URL!
    private var savedOutputRoot: String?

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rescan-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        savedOutputRoot = UserDefaults.standard.string(
            forKey: ConversionSettingsKeys.outputFolderPath
        )
        // Default to no output root configured so the cheap probes
        // don't accidentally hit one of the tempdir paths.
        UserDefaults.standard.removeObject(
            forKey: ConversionSettingsKeys.outputFolderPath
        )
    }

    override func tearDown() async throws {
        if let saved = savedOutputRoot {
            UserDefaults.standard.set(
                saved, forKey: ConversionSettingsKeys.outputFolderPath
            )
        }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    private func makeEntry(epubURL: URL, priorPaths: [String] = []) -> LibraryEntry {
        LibraryEntry(
            epubURL: epubURL, title: "Test", addedAt: Date(),
            priorPaths: priorPaths
        )
    }

    // MARK: - Cheap heuristic (probe site 1)

    func test_returns_sibling_pdf_via_cheap_probe() throws {
        let epub = tempDir.appendingPathComponent("foo.epub")
        let pdf = tempDir.appendingPathComponent("foo.pdf")
        try Data().write(to: epub)
        try Data("pdf bytes".utf8).write(to: pdf)
        let entry = makeEntry(epubURL: epub)
        let found = LibraryStore.locateSourcePDFForRescan(for: entry)
        XCTAssertEqual(found?.lastPathComponent, "foo.pdf")
    }

    // MARK: - dc:source probe (site 2)

    /// Construct a minimal EPUB whose OPF includes `<dc:source>`
    /// pointing at a PDF on disk. The probe should unpack the
    /// EPUB, read the OPF, and return the PDF URL.
    func test_falls_back_to_dc_source_when_cheap_probes_miss() throws {
        // The source PDF lives in a path the cheap probes won't
        // find (no sibling, no output root configured).
        let pdfDir = tempDir.appendingPathComponent("Far/Away")
        try FileManager.default.createDirectory(
            at: pdfDir, withIntermediateDirectories: true
        )
        let pdf = pdfDir.appendingPathComponent("originals.pdf")
        try Data("pdf bytes".utf8).write(to: pdf)

        let epubDir = tempDir.appendingPathComponent("books")
        try FileManager.default.createDirectory(
            at: epubDir, withIntermediateDirectories: true
        )
        let epub = epubDir.appendingPathComponent("output.epub")
        try writeMinimalEPUB(
            at: epub,
            dcSource: pdf.absoluteString
        )

        let entry = makeEntry(epubURL: epub)
        let found = LibraryStore.locateSourcePDFForRescan(for: entry)
        XCTAssertEqual(found?.canonicalForFile, pdf.canonicalForFile,
            "should resolve via the OPF dc:source after the cheap probes miss")
    }

    func test_dc_source_rejected_when_file_missing() throws {
        let bogusPDF = "/tmp/this-pdf-does-not-exist-\(UUID().uuidString).pdf"
        let epub = tempDir.appendingPathComponent("output.epub")
        try writeMinimalEPUB(
            at: epub, dcSource: "file://" + bogusPDF
        )
        let entry = makeEntry(epubURL: epub)
        let found = LibraryStore.locateSourcePDFForRescan(for: entry)
        XCTAssertNil(found, "dc:source pointing at a missing file should not return it")
    }

    func test_dc_source_rejected_when_not_a_file_url() throws {
        // http(s) dc:source is valid per Dublin Core but the rescan
        // flow needs a local PDF on disk.
        let epub = tempDir.appendingPathComponent("output.epub")
        try writeMinimalEPUB(
            at: epub, dcSource: "https://example.org/source.pdf"
        )
        let entry = makeEntry(epubURL: epub)
        let found = LibraryStore.locateSourcePDFForRescan(for: entry)
        XCTAssertNil(found)
    }

    func test_dc_source_handles_percent_encoded_path() throws {
        // Filename with a space — `URL.absoluteString` percent-
        // encodes it. The probe must decode back via `URL(string:)`,
        // not a naive prefix-strip.
        let pdfDir = tempDir.appendingPathComponent("with spaces")
        try FileManager.default.createDirectory(
            at: pdfDir, withIntermediateDirectories: true
        )
        let pdf = pdfDir.appendingPathComponent("my book.pdf")
        try Data().write(to: pdf)
        let epub = tempDir.appendingPathComponent("output.epub")
        try writeMinimalEPUB(at: epub, dcSource: pdf.absoluteString)
        let entry = makeEntry(epubURL: epub)
        let found = LibraryStore.locateSourcePDFForRescan(for: entry)
        XCTAssertEqual(found?.canonicalForFile, pdf.canonicalForFile)
    }

    // MARK: - priorPaths probe (site 3)

    func test_falls_back_to_priorPaths_pdf() throws {
        // EPUB carries no dc:source; priorPaths records the PDF
        // location from a previous re-drop.
        let pdfDir = tempDir.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(
            at: pdfDir, withIntermediateDirectories: true
        )
        let pdf = pdfDir.appendingPathComponent("source.pdf")
        try Data().write(to: pdf)

        let epub = tempDir.appendingPathComponent("output.epub")
        try writeMinimalEPUB(at: epub, dcSource: nil)
        let entry = makeEntry(epubURL: epub, priorPaths: [pdf.path])
        let found = LibraryStore.locateSourcePDFForRescan(for: entry)
        XCTAssertEqual(found?.canonicalForFile, pdf.canonicalForFile)
    }

    func test_priorPaths_skips_missing_files_and_non_pdf() throws {
        let epub = tempDir.appendingPathComponent("output.epub")
        try writeMinimalEPUB(at: epub, dcSource: nil)

        // A real PDF that exists wins over the leading misses.
        let realPDF = tempDir.appendingPathComponent("real.pdf")
        try Data().write(to: realPDF)

        let entry = makeEntry(epubURL: epub, priorPaths: [
            "/tmp/missing-\(UUID().uuidString).pdf",   // doesn't exist
            tempDir.appendingPathComponent("file.epub").path,  // .epub, not .pdf
            realPDF.path
        ])
        let found = LibraryStore.locateSourcePDFForRescan(for: entry)
        XCTAssertEqual(found?.canonicalForFile, realPDF.canonicalForFile)
    }

    // MARK: - Full miss

    func test_returns_nil_when_every_probe_misses() throws {
        let epub = tempDir.appendingPathComponent("orphan.epub")
        try writeMinimalEPUB(at: epub, dcSource: nil)
        let entry = makeEntry(epubURL: epub)
        let found = LibraryStore.locateSourcePDFForRescan(for: entry)
        XCTAssertNil(found)
    }

    // MARK: - EPUB fixture helper

    /// Write a minimal valid EPUB to `url` with optional
    /// `<dc:source>` metadata. The package has no spine items — we
    /// only need the OPF for the probe.
    private func writeMinimalEPUB(at url: URL, dcSource: String?) throws {
        let dcSourceLine: String
        if let dcSource {
            dcSourceLine = "<dc:source>\(dcSource)</dc:source>"
        } else {
            dcSourceLine = ""
        }
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" \
        unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">test-id</dc:identifier>
            <dc:title>Test Book</dc:title>
            <dc:language>en</dc:language>
            \(dcSourceLine)
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" \
        properties="nav"/>
          </manifest>
          <spine>
            <itemref idref="nav"/>
          </spine>
        </package>
        """
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Nav</title></head>
        <body><nav epub:type="toc"><ol/></nav></body>
        </html>
        """
        let entries: [EPUBPackager.Entry] = [
            .init(path: "mimetype",
                  data: Data("application/epub+zip".utf8), compressed: false),
            .init(path: "META-INF/container.xml",
                  data: Data(container.utf8), compressed: true),
            .init(path: "OEBPS/content.opf",
                  data: Data(opf.utf8), compressed: true),
            .init(path: "OEBPS/nav.xhtml",
                  data: Data(nav.utf8), compressed: true),
        ]
        try EPUBPackager().write(entries, to: url)
    }
}
