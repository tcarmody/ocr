import XCTest
import Foundation
@testable import EPUB

/// Foundation tests for the in-memory EPUB model. Exercises the
/// load → mutate → save round trip without involving any editor or
/// PackageEditor code — that wiring is a separate refactor step.
final class EPUBBookTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBBookTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Load

    func test_load_pulls_text_resources_into_memory() throws {
        try buildMinimalEPUB(chapterCount: 2)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )

        let chapter1 = try XCTUnwrap(book.resourcesByID["ch01"])
        XCTAssertTrue(chapter1.isText)
        XCTAssertNotNil(chapter1.text)
        XCTAssertTrue(chapter1.text!.contains("first paragraph"))
        XCTAssertEqual(chapter1.mediaType, "application/xhtml+xml")
        XCTAssertEqual(chapter1.hrefRelativeToOPF, "ch01.xhtml")
        XCTAssertFalse(chapter1.isDirty)
    }

    func test_load_keeps_binary_resources_as_disk_refs() throws {
        try buildMinimalEPUB(chapterCount: 1, includeImage: true)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )

        let img = try XCTUnwrap(book.resourcesByID["cover"])
        XCTAssertFalse(img.isText)
        XCTAssertNil(img.text)
        if case .binary(let url) = img.content {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        } else {
            XCTFail("expected binary content for image")
        }
    }

    func test_load_records_spine_and_resource_order() throws {
        try buildMinimalEPUB(chapterCount: 3)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )

        XCTAssertEqual(book.spine, ["ch01", "ch02", "ch03"])
        XCTAssertTrue(book.resourceOrder.contains("nav"))
        XCTAssertTrue(book.resourceOrder.contains("ch01"))
    }

    func test_load_captures_metadata_fields() throws {
        try buildMinimalEPUB(chapterCount: 1)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertEqual(book.metadata.title, "Test Book")
        XCTAssertEqual(book.metadata.language, "en")
    }

    // MARK: - Save: clean book

    func test_save_is_noop_when_book_is_clean() throws {
        try buildMinimalEPUB(chapterCount: 1)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        let originalOPFOnDisk = try String(
            contentsOf: book.opfURL, encoding: .utf8
        )
        XCTAssertFalse(book.isDirty)
        try EPUBBookSaver().save(book)
        let afterSave = try String(contentsOf: book.opfURL, encoding: .utf8)
        XCTAssertEqual(originalOPFOnDisk, afterSave)
    }

    // MARK: - Save: dirty text resource

    func test_dirty_text_resource_is_flushed_to_disk() throws {
        try buildMinimalEPUB(chapterCount: 1)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )

        let chapter1 = try XCTUnwrap(book.resourcesByID["ch01"])
        chapter1.text = "<html><body><p>rewritten</p></body></html>"
        XCTAssertTrue(chapter1.isDirty)
        XCTAssertTrue(book.isDirty)

        try EPUBBookSaver().save(book)
        XCTAssertFalse(chapter1.isDirty)
        XCTAssertFalse(book.isDirty)

        let onDisk = try String(
            contentsOf: book.absoluteURL(for: chapter1), encoding: .utf8
        )
        XCTAssertEqual(onDisk, "<html><body><p>rewritten</p></body></html>")
    }

    // MARK: - Save: structural removal

    func test_removed_resource_is_unlinked_and_dropped_from_OPF() throws {
        try buildMinimalEPUB(chapterCount: 3)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )

        let ch02 = try XCTUnwrap(book.resourcesByID["ch02"])
        let ch02URL = book.absoluteURL(for: ch02)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ch02URL.path))

        book.removeResource(id: "ch02")
        XCTAssertFalse(book.spine.contains("ch02"))
        XCTAssertNil(book.resourcesByID["ch02"])
        XCTAssertTrue(book.isDirty)

        try EPUBBookSaver().save(book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ch02URL.path))

        // Re-read OPF — ch02 must be gone from manifest and spine.
        let pkg = try OPFReader().read(rootDir: tempDir)
        XCTAssertNil(pkg.manifestById["ch02"])
        XCTAssertEqual(pkg.spine, ["ch01", "ch03"])
    }

    // MARK: - Save: structural addition

    func test_appended_resource_is_serialized_into_OPF() throws {
        try buildMinimalEPUB(chapterCount: 1)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )

        let new = Resource(
            id: "ch99",
            hrefRelativeToOPF: "ch99.xhtml",
            mediaType: "application/xhtml+xml",
            content: .text("<html><body><p>new</p></body></html>"),
            isDirty: true
        )
        try book.appendResource(new)
        book.insertInSpine(id: "ch99", after: "ch01")
        try EPUBBookSaver().save(book)

        let pkg = try OPFReader().read(rootDir: tempDir)
        XCTAssertNotNil(pkg.manifestById["ch99"])
        XCTAssertEqual(pkg.spine, ["ch01", "ch99"])

        let onDisk = try String(
            contentsOf: tempDir
                .appendingPathComponent("OEBPS/ch99.xhtml"),
            encoding: .utf8
        )
        XCTAssertTrue(onDisk.contains("new"))
    }

    func test_insertResource_after_places_in_manifest_order() throws {
        try buildMinimalEPUB(chapterCount: 3)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        let new = Resource(
            id: "ch02_split",
            hrefRelativeToOPF: "ch02_split.xhtml",
            mediaType: "application/xhtml+xml",
            content: .text(""),
            isDirty: true
        )
        try book.insertResource(new, after: "ch02")
        let ch02Idx = try XCTUnwrap(book.resourceOrder.firstIndex(of: "ch02"))
        let ch03Idx = try XCTUnwrap(book.resourceOrder.firstIndex(of: "ch03"))
        let newIdx = try XCTUnwrap(book.resourceOrder.firstIndex(of: "ch02_split"))
        XCTAssertEqual(newIdx, ch02Idx + 1)
        XCTAssertEqual(ch03Idx, newIdx + 1)
    }

    func test_moveInSpine_up_swaps_with_previous() throws {
        try buildMinimalEPUB(chapterCount: 3)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        book.moveInSpine(id: "ch02", direction: .up)
        XCTAssertEqual(book.spine, ["ch02", "ch01", "ch03"])
        // Manifest order tracks reading order so the OPF emits
        // chapters in the new sequence.
        let chapterOrder = book.resourceOrder.filter { $0.hasPrefix("ch") }
        XCTAssertEqual(chapterOrder, ["ch02", "ch01", "ch03"])
        XCTAssertTrue(book.structuralIsDirty)
    }

    func test_moveInSpine_down_swaps_with_next() throws {
        try buildMinimalEPUB(chapterCount: 3)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        book.moveInSpine(id: "ch02", direction: .down)
        XCTAssertEqual(book.spine, ["ch01", "ch03", "ch02"])
    }

    func test_moveInSpine_at_top_is_noop_when_moving_up() throws {
        try buildMinimalEPUB(chapterCount: 3)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        book.moveInSpine(id: "ch01", direction: .up)
        XCTAssertEqual(book.spine, ["ch01", "ch02", "ch03"])
    }

    func test_moveInSpine_at_bottom_is_noop_when_moving_down() throws {
        try buildMinimalEPUB(chapterCount: 3)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        book.moveInSpine(id: "ch03", direction: .down)
        XCTAssertEqual(book.spine, ["ch01", "ch02", "ch03"])
    }

    func test_moveInSpine_unknown_id_is_noop() throws {
        try buildMinimalEPUB(chapterCount: 3)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        book.moveInSpine(id: "does-not-exist", direction: .up)
        XCTAssertEqual(book.spine, ["ch01", "ch02", "ch03"])
    }

    func test_moveInSpine_round_trips_through_save() throws {
        try buildMinimalEPUB(chapterCount: 3)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        book.moveInSpine(id: "ch03", direction: .up)
        try EPUBBookSaver().save(book)

        let pkg = try OPFReader().read(rootDir: tempDir)
        XCTAssertEqual(pkg.spine, ["ch01", "ch03", "ch02"])
    }

    func test_insertResource_after_unknown_anchor_falls_back_to_append() throws {
        try buildMinimalEPUB(chapterCount: 1)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        let new = Resource(
            id: "stray",
            hrefRelativeToOPF: "stray.xhtml",
            mediaType: "application/xhtml+xml",
            content: .text(""),
            isDirty: true
        )
        try book.insertResource(new, after: "does-not-exist")
        XCTAssertEqual(book.resourceOrder.last, "stray")
    }

    func test_appendResource_throws_on_duplicate_id() throws {
        try buildMinimalEPUB(chapterCount: 1)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        let dupe = Resource(
            id: "ch01",
            hrefRelativeToOPF: "ch01-dup.xhtml",
            mediaType: "application/xhtml+xml",
            content: .text(""),
            isDirty: true
        )
        XCTAssertThrowsError(try book.appendResource(dupe)) { error in
            guard case EPUBBook.BookError.duplicateResourceID = error else {
                XCTFail("expected duplicateResourceID, got \(error)")
                return
            }
        }
    }

    // MARK: - Save: metadata preservation

    func test_save_preserves_unmodeled_metadata_elements() throws {
        // The model only knows title/creator/language. Anything else
        // in the metadata block (publisher, identifiers, custom
        // <meta>) must round-trip untouched. This is the property we
        // were missing with from-scratch OPF re-emission.
        try buildMinimalEPUB(
            chapterCount: 1,
            extraMetadata: """
            <dc:publisher>Acme Press</dc:publisher>
            <meta property="custom:flag">on</meta>
            """
        )
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )

        // Trigger a save by mutating a chapter (structural OPF rewrite
        // happens on any save, so manifest passes through the same
        // path even when the trigger is purely text).
        let chapter1 = try XCTUnwrap(book.resourcesByID["ch01"])
        chapter1.text = (chapter1.text ?? "") + "<!-- touched -->"
        try EPUBBookSaver().save(book)

        let opfText = try String(contentsOf: book.opfURL, encoding: .utf8)
        XCTAssertTrue(opfText.contains("Acme Press"))
        XCTAssertTrue(opfText.contains("custom:flag"))
    }

    // MARK: - Save: metadata mutation

    func test_metadata_title_change_round_trips() throws {
        try buildMinimalEPUB(chapterCount: 1)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        book.metadata = OPFReader.Metadata(
            title: "Renamed Book",
            author: book.metadata.author,
            language: book.metadata.language
        )
        try EPUBBookSaver().save(book)

        let pkg = try OPFReader().read(rootDir: tempDir)
        XCTAssertEqual(pkg.metadata.title, "Renamed Book")
    }

    // MARK: - Save: dcterms:modified

    func test_save_bumps_dcterms_modified() throws {
        try buildMinimalEPUB(chapterCount: 1)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        let chapter1 = try XCTUnwrap(book.resourcesByID["ch01"])
        chapter1.text = (chapter1.text ?? "") + " "
        try EPUBBookSaver().save(book)

        let opfText = try String(contentsOf: book.opfURL, encoding: .utf8)
        XCTAssertTrue(opfText.contains("dcterms:modified"))
        // ISO-8601 form ends in Z; weakly assert the timestamp shape.
        XCTAssertTrue(opfText.contains(":") && opfText.contains("Z<"))
    }

    // MARK: - Working-dir ownership

    func test_disownWorkingDirectory_prevents_deinit_cleanup() throws {
        try buildMinimalEPUB(chapterCount: 1)
        var book: EPUBBook? = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        book?.disownWorkingDirectory()
        book = nil
        // Working dir should still be present after deinit because
        // ownership was transferred away.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
    }

    // MARK: - Fixture builder

    /// Build a minimal EPUB working tree under `tempDir`. Mirrors the
    /// shape used by `PackageEditorTests` so coverage is comparable.
    private func buildMinimalEPUB(
        chapterCount: Int,
        includeImage: Bool = false,
        extraMetadata: String = ""
    ) throws {
        let metaInf = tempDir.appendingPathComponent("META-INF")
        try FileManager.default.createDirectory(
            at: metaInf, withIntermediateDirectories: true
        )
        try """
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(
            to: metaInf.appendingPathComponent("container.xml"),
            atomically: true, encoding: .utf8
        )

        let oebps = tempDir.appendingPathComponent("OEBPS")
        try FileManager.default.createDirectory(
            at: oebps, withIntermediateDirectories: true
        )

        var manifestItems: [String] = []
        var spineItems: [String] = []
        for i in 0..<chapterCount {
            let id = String(format: "ch%02d", i + 1)
            let href = "ch\(String(format: "%02d", i + 1)).xhtml"
            try """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter \(i + 1)</title></head>
            <body>
            <h1>Chapter \(i + 1)</h1>
            <p>first paragraph</p>
            <p>second paragraph for chapter \(i + 1)</p>
            </body>
            </html>
            """.write(
                to: oebps.appendingPathComponent(href),
                atomically: true, encoding: .utf8
            )
            manifestItems.append(
                "<item id=\"\(id)\" href=\"\(href)\" media-type=\"application/xhtml+xml\"/>"
            )
            spineItems.append("<itemref idref=\"\(id)\"/>")
        }
        // Nav item — text resource.
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Contents</title></head>
        <body><nav epub:type="toc"><ol></ol></nav></body>
        </html>
        """.write(
            to: oebps.appendingPathComponent("nav.xhtml"),
            atomically: true, encoding: .utf8
        )
        manifestItems.append(
            "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        )

        // Optional image — binary resource.
        if includeImage {
            // Tiny 1×1 PNG byte sequence is overkill; any non-empty
            // bytes are fine since the loader doesn't decode images.
            let imgURL = oebps.appendingPathComponent("cover.png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imgURL)
            manifestItems.append(
                "<item id=\"cover\" href=\"cover.png\" media-type=\"image/png\"/>"
            )
        }

        let extraMetadataBlock = extraMetadata.isEmpty
            ? ""
            : "\n" + extraMetadata + "\n"
        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">test-id</dc:identifier>
        <dc:title>Test Book</dc:title>
        <dc:language>en</dc:language>\(extraMetadataBlock)
        </metadata>
        <manifest>
        \(manifestItems.joined(separator: "\n"))
        </manifest>
        <spine>
        \(spineItems.joined(separator: "\n"))
        </spine>
        </package>
        """
        try opfXML.write(
            to: oebps.appendingPathComponent("content.opf"),
            atomically: true, encoding: .utf8
        )
    }
}
