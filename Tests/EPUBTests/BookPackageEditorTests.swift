import XCTest
import Foundation
@testable import EPUB

/// In-memory equivalent of `PackageEditorTests`. The headline property
/// these tests verify, beyond functional equivalence, is that no disk
/// I/O happens during the operations themselves — a snapshot of the
/// working tree before and after the in-memory mutation must be
/// identical. Disk only changes on `EPUBBookSaver.save(_:)`.
final class BookPackageEditorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookPackageEditorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Merge

    func test_merge_appends_next_chapter_body_in_memory() throws {
        let book = try loadBook(chapterCount: 3)
        let editor = BookPackageEditor(book: book)
        try editor.mergeWithNextChapter(at: "ch01")

        let ch01 = try XCTUnwrap(book.resourcesByID["ch01"])
        let merged = try XCTUnwrap(ch01.text)
        XCTAssertTrue(merged.contains("Chapter 1"))
        XCTAssertTrue(merged.contains("Chapter 2"))
        XCTAssertNil(book.resourcesByID["ch02"])
        XCTAssertEqual(book.spine, ["ch01", "ch03"])
    }

    func test_merge_does_not_touch_disk() throws {
        let book = try loadBook(chapterCount: 3)
        let snapshotBefore = try snapshot(of: tempDir)

        try BookPackageEditor(book: book).mergeWithNextChapter(at: "ch01")

        let snapshotAfter = try snapshot(of: tempDir)
        XCTAssertEqual(snapshotBefore, snapshotAfter,
            "merge mutated disk despite operating on in-memory book")
    }

    func test_merge_throws_alreadyLastInSpine_for_last_chapter() throws {
        let book = try loadBook(chapterCount: 2)
        XCTAssertThrowsError(
            try BookPackageEditor(book: book).mergeWithNextChapter(at: "ch02")
        ) { error in
            guard case BookPackageEditor.EditError.alreadyLastInSpine = error else {
                XCTFail("expected alreadyLastInSpine, got \(error)")
                return
            }
        }
    }

    func test_merge_round_trips_through_save() throws {
        let book = try loadBook(chapterCount: 3)
        try BookPackageEditor(book: book).mergeWithNextChapter(at: "ch01")
        try EPUBBookSaver().save(book)

        // Re-read OPF from disk: ch02 should be gone from manifest +
        // spine, the file unlinked, and the merged text in ch01.
        let pkg = try OPFReader().read(rootDir: tempDir)
        XCTAssertNil(pkg.manifestById["ch02"])
        XCTAssertEqual(pkg.spine, ["ch01", "ch03"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("OEBPS/ch02.xhtml").path
        ))
        let mergedOnDisk = try String(
            contentsOf: tempDir.appendingPathComponent("OEBPS/ch01.xhtml"),
            encoding: .utf8
        )
        XCTAssertTrue(mergedOnDisk.contains("Chapter 1"))
        XCTAssertTrue(mergedOnDisk.contains("Chapter 2"))
    }

    // MARK: - Split

    func test_split_creates_new_resource_after_original_in_spine() throws {
        let book = try loadBook(chapterCount: 1)
        let editor = BookPackageEditor(book: book)

        let ch01Text = try XCTUnwrap(book.resourcesByID["ch01"]?.text)
        guard let bodyRange = PackageEditor.bodyRange(in: ch01Text) else {
            return XCTFail("expected body in ch01")
        }
        let bodyStart = ch01Text.distance(
            from: ch01Text.startIndex, to: bodyRange.lowerBound
        )
        // Cursor inside the body, far enough in to exercise the
        // forward-snap to the next element-on-its-own-line.
        let new = try editor.splitChapter(
            resourceID: "ch01", splitOffset: bodyStart + 30
        )

        XCTAssertEqual(book.spine.firstIndex(of: new.id),
                       book.spine.firstIndex(of: "ch01")! + 1)
        XCTAssertNotNil(book.resourcesByID[new.id])
        XCTAssertTrue(new.isDirty)
    }

    func test_split_does_not_touch_disk() throws {
        let book = try loadBook(chapterCount: 1)
        let snapshotBefore = try snapshot(of: tempDir)

        let editor = BookPackageEditor(book: book)
        let ch01Text = try XCTUnwrap(book.resourcesByID["ch01"]?.text)
        let bodyStart = try ch01Text.distance(
            from: ch01Text.startIndex,
            to: XCTUnwrap(PackageEditor.bodyRange(in: ch01Text)).lowerBound
        )
        _ = try editor.splitChapter(
            resourceID: "ch01", splitOffset: bodyStart + 30
        )

        let snapshotAfter = try snapshot(of: tempDir)
        XCTAssertEqual(snapshotBefore, snapshotAfter,
            "split mutated disk despite operating on in-memory book")
    }

    func test_split_assigns_unique_href_and_id() throws {
        let book = try loadBook(chapterCount: 1)
        let editor = BookPackageEditor(book: book)
        let ch01Text = try XCTUnwrap(book.resourcesByID["ch01"]?.text)
        let bodyStart = try ch01Text.distance(
            from: ch01Text.startIndex,
            to: XCTUnwrap(PackageEditor.bodyRange(in: ch01Text)).lowerBound
        )
        let new = try editor.splitChapter(
            resourceID: "ch01", splitOffset: bodyStart + 30
        )
        XCTAssertNotEqual(new.id, "ch01")
        XCTAssertNotEqual(new.hrefRelativeToOPF, "ch01.xhtml")
        XCTAssertTrue(new.hrefRelativeToOPF.hasSuffix(".xhtml"))
    }

    func test_split_throws_when_offset_has_no_safe_boundary_ahead() throws {
        let book = try loadBook(chapterCount: 1)
        let editor = BookPackageEditor(book: book)
        let ch01Text = try XCTUnwrap(book.resourcesByID["ch01"]?.text)
        let bodyEnd = try ch01Text.distance(
            from: ch01Text.startIndex,
            to: XCTUnwrap(PackageEditor.bodyRange(in: ch01Text)).upperBound
        )
        // Cursor at body end → no further `\n<` boundary.
        XCTAssertThrowsError(
            try editor.splitChapter(resourceID: "ch01", splitOffset: bodyEnd)
        ) { error in
            guard case BookPackageEditor.EditError.splitOffsetOutOfBounds = error else {
                XCTFail("expected splitOffsetOutOfBounds, got \(error)")
                return
            }
        }
    }

    func test_split_round_trips_through_save() throws {
        let book = try loadBook(chapterCount: 1)
        let editor = BookPackageEditor(book: book)
        let ch01Text = try XCTUnwrap(book.resourcesByID["ch01"]?.text)
        let bodyStart = try ch01Text.distance(
            from: ch01Text.startIndex,
            to: XCTUnwrap(PackageEditor.bodyRange(in: ch01Text)).lowerBound
        )
        let new = try editor.splitChapter(
            resourceID: "ch01", splitOffset: bodyStart + 30
        )
        try EPUBBookSaver().save(book)

        let pkg = try OPFReader().read(rootDir: tempDir)
        XCTAssertNotNil(pkg.manifestById[new.id])
        XCTAssertEqual(pkg.spine, ["ch01", new.id])
        let onDisk = try String(
            contentsOf: tempDir.appendingPathComponent(
                "OEBPS/" + new.hrefRelativeToOPF
            ),
            encoding: .utf8
        )
        XCTAssertFalse(onDisk.isEmpty)
    }

    // MARK: - regenerateNav

    func test_regenerateNav_uses_first_heading_when_present() throws {
        let book = try loadBook(chapterCount: 2)
        try BookPackageEditor(book: book).regenerateNav()

        let nav = try XCTUnwrap(book.navResource)
        let navText = try XCTUnwrap(nav.text)
        XCTAssertTrue(navText.contains("Chapter 1"))
        XCTAssertTrue(navText.contains("Chapter 2"))
    }

    func test_regenerateNav_falls_back_to_chapter_N_when_no_heading() throws {
        let book = try loadBook(chapterCount: 1)
        let ch01 = try XCTUnwrap(book.resourcesByID["ch01"])
        ch01.text = "<html><body><p>plain</p></body></html>"

        try BookPackageEditor(book: book).regenerateNav()

        let nav = try XCTUnwrap(book.navResource)
        let navText = try XCTUnwrap(nav.text)
        XCTAssertTrue(navText.contains("Chapter 1"))
    }

    func test_regenerateNav_marks_nav_dirty() throws {
        let book = try loadBook(chapterCount: 1)
        let nav = try XCTUnwrap(book.navResource)
        XCTAssertFalse(nav.isDirty)
        try BookPackageEditor(book: book).regenerateNav()
        XCTAssertTrue(nav.isDirty)
    }

    // MARK: - Helpers

    private func loadBook(chapterCount: Int) throws -> EPUBBook {
        try buildMinimalEPUB(chapterCount: chapterCount)
        return try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
    }

    /// Snapshot every regular file under `dir` as a (path → SHA-ish
    /// dictionary). For our purposes "did it change" is good enough,
    /// so we use file size + modification date to detect changes
    /// without hashing content. The point is to catch `splitChapter`
    /// or `mergeWithNextChapter` accidentally writing to disk.
    private func snapshot(of dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey])
                .isRegularFile) ?? false
            guard isFile else { continue }
            // Read the full content — this is a tiny test fixture so
            // hashing properly is overkill; equality of bytes is
            // strongest correctness signal anyway.
            out[url.path] = try Data(contentsOf: url)
        }
        return out
    }

    /// Same fixture shape as `EPUBBookTests` and `PackageEditorTests`.
    /// Inlined here so each test file is self-contained.
    private func buildMinimalEPUB(chapterCount: Int) throws {
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
            <p>second paragraph for chapter \(i + 1) with extra body content</p>
            <p>third paragraph trailing content for chapter \(i + 1)</p>
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
        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">test-id</dc:identifier>
        <dc:title>Test Book</dc:title>
        <dc:language>en</dc:language>
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
