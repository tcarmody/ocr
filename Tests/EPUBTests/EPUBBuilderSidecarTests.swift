import XCTest
import Document
@testable import EPUB
import ZIPFoundation

/// Verifies `EPUBBuilder.write` writes the Humanist sidecar with the
/// absolute path of the source PDF when one is supplied — required
/// so the editor's `resolveSourcePDF` finds the source even when the
/// EPUB has been moved into a per-format output subfolder away from
/// the source PDF.
final class EPUBBuilderSidecarTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBBuilderSidecarTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func test_sidecar_carries_source_pdf_absolute_path_when_supplied() throws {
        let pdfURL = tempDir.appendingPathComponent("Drops/foo.pdf")
        try FileManager.default.createDirectory(
            at: pdfURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdfURL)

        let outputURL = tempDir.appendingPathComponent("Books/foo.epub")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let book = Book(
            title: "Test", language: .en,
            chapters: [
                Chapter(title: "Chapter 1", blocks: [
                    .heading(level: 1, runs: [InlineRun("Chapter 1")]),
                    .paragraph(runs: [InlineRun("Body.")])
                ])
            ]
        )
        try EPUBBuilder().write(
            book: book,
            sourcePDFURL: pdfURL,
            to: outputURL
        )

        // Crack open the EPUB and pull the sidecar out of META-INF.
        let archive = try XCTUnwrap(Archive(url: outputURL, accessMode: .read))
        let entry = try XCTUnwrap(archive[HumanistSidecar.pathInsideEPUB])
        var sidecarBytes = Data()
        _ = try archive.extract(entry) { chunk in sidecarBytes.append(chunk) }
        let sidecar = try JSONDecoder().decode(HumanistSidecar.self, from: sidecarBytes)
        XCTAssertEqual(
            sidecar.sourcePDFPath,
            pdfURL.canonicalForFile.path
        )
    }

    func test_sidecar_omitted_when_no_source_pdf_supplied() throws {
        let outputURL = tempDir.appendingPathComponent("nopdf.epub")
        let book = Book(
            title: "Test", language: .en,
            chapters: [Chapter(title: "x", blocks: [
                .paragraph(runs: [InlineRun("body")])
            ])]
        )
        try EPUBBuilder().write(book: book, to: outputURL)

        let archive = try XCTUnwrap(Archive(url: outputURL, accessMode: .read))
        XCTAssertNil(archive[HumanistSidecar.pathInsideEPUB])
    }

    /// The editor's `resolveSourcePDF` must accept an absolute path
    /// stored verbatim in the sidecar — verify that direction
    /// end-to-end with a moved EPUB.
    func test_resolve_finds_source_pdf_after_epub_moves() throws {
        let pdfURL = tempDir.appendingPathComponent("Drops/foo.pdf")
        try FileManager.default.createDirectory(
            at: pdfURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdfURL)

        // Simulate the in-editor world: working directory holds the
        // unpacked META-INF/. The sidecar carries the source PDF's
        // absolute path; the EPUB's location is irrelevant.
        let workingDir = tempDir.appendingPathComponent("Working")
        try FileManager.default.createDirectory(
            at: workingDir.appendingPathComponent("META-INF"),
            withIntermediateDirectories: true
        )
        let sidecar = HumanistSidecar(
            sourcePDFPath: pdfURL.canonicalForFile.path
        )
        try sidecar.write(workingDirectory: workingDir)

        let resolved = HumanistSidecar
            .read(workingDirectory: workingDir)
            .resolveSourcePDF(epubURL: tempDir.appendingPathComponent("Books/foo.epub"))
        XCTAssertEqual(resolved?.canonicalForFile, pdfURL.canonicalForFile)
    }
}
