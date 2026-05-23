import XCTest
import Foundation
import EPUB
@testable import Humanist

/// Coverage for `ConversionOutputResolver.siblingsForEPUB` — the
/// Library "Move to Trash" action uses it to find every per-
/// conversion sibling (markdown, plain text, HTML, DOCX, searchable
/// PDF, consolidated source PDF, debug-staging dir) so the user
/// doesn't have to chase down a dozen related files in a dozen
/// subfolders after removing a book.
@MainActor
final class ConversionOutputResolverSiblingsTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sib-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Mirror the production layout: `<root>/Books/<stem>.epub`.
    private func makeEPUB(stem: String = "TestBook") throws -> URL {
        let books = root.appendingPathComponent("Books", isDirectory: true)
        try FileManager.default.createDirectory(
            at: books, withIntermediateDirectories: true
        )
        let epub = books.appendingPathComponent("\(stem).epub")
        FileManager.default.createFile(atPath: epub.path, contents: Data())
        return epub
    }

    /// Create a sibling at the canonical output-root subfolder path.
    @discardableResult
    private func makeSibling(
        stem: String, subfolder: String, ext: String
    ) throws -> URL {
        let dir = root.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent("\(stem).\(ext)")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    // MARK: - Output-root siblings

    func test_finds_markdown_and_text_siblings_under_output_root() throws {
        let epub = try makeEPUB()
        let txt = try makeSibling(
            stem: "TestBook",
            subfolder: ConversionOutputSubfolder.textFiles,
            ext: "txt"
        )
        let md = try makeSibling(
            stem: "TestBook",
            subfolder: ConversionOutputSubfolder.markdown,
            ext: "md"
        )
        let siblings = ConversionOutputResolver.siblingsForEPUB(epub)
        XCTAssertTrue(siblings.contains(txt))
        XCTAssertTrue(siblings.contains(md))
    }

    func test_finds_html_and_docx_siblings_under_output_root() throws {
        let epub = try makeEPUB()
        let html = try makeSibling(
            stem: "TestBook",
            subfolder: ConversionOutputSubfolder.html,
            ext: "html"
        )
        let docx = try makeSibling(
            stem: "TestBook",
            subfolder: ConversionOutputSubfolder.docx,
            ext: "docx"
        )
        let siblings = ConversionOutputResolver.siblingsForEPUB(epub)
        XCTAssertTrue(siblings.contains(html))
        XCTAssertTrue(siblings.contains(docx))
    }

    func test_finds_searchable_pdf_with_compound_extension() throws {
        let epub = try makeEPUB()
        let pdf = try makeSibling(
            stem: "TestBook",
            subfolder: ConversionOutputSubfolder.searchablePDFs,
            ext: "searchable.pdf"
        )
        let siblings = ConversionOutputResolver.siblingsForEPUB(epub)
        XCTAssertTrue(siblings.contains(pdf),
            "expected `TestBook.searchable.pdf` in: \(siblings)")
    }

    func test_finds_consolidated_pdf_under_pdfs_subfolder() throws {
        let epub = try makeEPUB()
        let pdf = try makeSibling(
            stem: "TestBook",
            subfolder: ConversionOutputSubfolder.pdfs,
            ext: "pdf"
        )
        let siblings = ConversionOutputResolver.siblingsForEPUB(epub)
        XCTAssertTrue(siblings.contains(pdf))
    }

    func test_finds_debug_staging_directory_under_logs() throws {
        let epub = try makeEPUB()
        let dir = root
            .appendingPathComponent(ConversionOutputSubfolder.logs, isDirectory: true)
            .appendingPathComponent("TestBook.humanist-debug")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let siblings = ConversionOutputResolver.siblingsForEPUB(epub)
        // URL equality is brittle for directories — `appendingPath
        // Component` queries the filesystem and adds a trailing
        // slash when the target already exists as a dir, so the
        // dir URL created before `createDirectory` (in `dir` above)
        // and the URL the resolver constructs afterwards may not
        // be `==` even though they point at the same path.
        // Compare paths instead, which the production trash loop
        // uses too (it just passes URLs to `trashItem`).
        XCTAssertTrue(siblings.contains(where: { $0.path == dir.path }))
    }

    // MARK: - Next-to-EPUB siblings

    func test_finds_next_to_epub_siblings_when_no_output_root_layout() throws {
        // Simulate the "no output root" pipeline shape — the EPUB
        // and its siblings live in the same directory rather than
        // in `<root>/Books/`, `<root>/Text Files/`, etc.
        let dir = root.appendingPathComponent("FlatLayout", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let epub = dir.appendingPathComponent("Solo.epub")
        FileManager.default.createFile(atPath: epub.path, contents: Data())
        let txt = dir.appendingPathComponent("Solo.txt")
        let md = dir.appendingPathComponent("Solo.md")
        FileManager.default.createFile(atPath: txt.path, contents: Data())
        FileManager.default.createFile(atPath: md.path, contents: Data())

        let siblings = ConversionOutputResolver.siblingsForEPUB(epub)
        XCTAssertTrue(siblings.contains(txt))
        XCTAssertTrue(siblings.contains(md))
    }

    // MARK: - Linked source PDF

    func test_includes_explicit_linked_source_pdf() throws {
        let epub = try makeEPUB()
        let pdfDir = root.appendingPathComponent("custom-pdfs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pdfDir, withIntermediateDirectories: true
        )
        let linkedPDF = pdfDir.appendingPathComponent("TestBook.pdf")
        FileManager.default.createFile(atPath: linkedPDF.path, contents: Data())

        let siblings = ConversionOutputResolver.siblingsForEPUB(
            epub, linkedSourcePDF: linkedPDF
        )
        XCTAssertTrue(siblings.contains(linkedPDF))
    }

    func test_linked_pdf_in_conventional_path_not_double_listed() throws {
        // When the linked PDF happens to live at the conventional
        // `<root>/PDFs/<stem>.pdf` path, it should appear once —
        // not twice (once from the geometric scan, once from the
        // explicit parameter).
        let epub = try makeEPUB()
        let pdf = try makeSibling(
            stem: "TestBook",
            subfolder: ConversionOutputSubfolder.pdfs,
            ext: "pdf"
        )
        let siblings = ConversionOutputResolver.siblingsForEPUB(
            epub, linkedSourcePDF: pdf
        )
        let pdfCount = siblings.filter { $0 == pdf }.count
        XCTAssertEqual(pdfCount, 1, "expected unique entry; got: \(siblings)")
    }

    // MARK: - Filtering

    func test_returns_only_extant_paths() throws {
        // No siblings created — even though candidate URLs exist
        // conceptually for every known subfolder, none of them
        // are on disk. Expect empty result.
        let epub = try makeEPUB()
        let siblings = ConversionOutputResolver.siblingsForEPUB(epub)
        XCTAssertTrue(siblings.isEmpty,
            "expected zero siblings for bare EPUB; got: \(siblings)")
    }

    func test_does_not_match_other_books_stems() throws {
        // Create siblings for stem "Other", then ask for siblings
        // of "TestBook" — none should match.
        _ = try makeEPUB(stem: "TestBook")
        let _ = try makeSibling(
            stem: "Other",
            subfolder: ConversionOutputSubfolder.textFiles,
            ext: "txt"
        )
        let epub = root.appendingPathComponent("Books/TestBook.epub")
        let siblings = ConversionOutputResolver.siblingsForEPUB(epub)
        XCTAssertTrue(
            siblings.allSatisfy { !$0.lastPathComponent.hasPrefix("Other") },
            "siblings should not cross-match other stems; got: \(siblings)"
        )
    }
}
