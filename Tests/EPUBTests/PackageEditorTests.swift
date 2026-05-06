import XCTest
import Foundation
@testable import EPUB

/// PackageEditor performs in-place edits on an unpacked EPUB working
/// directory: split a chapter at a cursor offset, merge two adjacent
/// chapters, regenerate nav.xhtml. These tests build a minimal but
/// realistic working tree on disk, run the operation, then re-read
/// the OPF to check the spine + manifest landed where expected.
final class PackageEditorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackageEditorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Body range / safe boundary helpers

    func test_bodyRange_finds_body_content() {
        let xhtml = """
        <html><body>Hello world</body></html>
        """
        let range = PackageEditor.bodyRange(in: xhtml)
        XCTAssertNotNil(range)
        XCTAssertEqual(String(xhtml[range!]), "Hello world")
    }

    func test_bodyRange_handles_attributes_on_body_tag() {
        let xhtml = #"""
        <html><body class="ch" lang="en">content</body></html>
        """#
        let range = PackageEditor.bodyRange(in: xhtml)
        XCTAssertEqual(range.map { String(xhtml[$0]) }, "content")
    }

    func test_snapToSafeBoundary_lands_at_line_start_with_tag() {
        // Multi-line body: snap should jump forward to the start of
        // the next element-on-its-own-line. Cursor inside `<p>foo</p>`
        // → snap to start of `<p>bar` line.
        let xhtml = "<p>foo</p>\n<p>bar</p>\n<p>baz</p>"
        let snapped = PackageEditor.snapToSafeBoundary(
            in: xhtml, near: 5, bodyEnd: xhtml.count
        )
        XCTAssertEqual(
            String(xhtml.suffix(from: xhtml.index(xhtml.startIndex, offsetBy: snapped))),
            "<p>bar</p>\n<p>baz</p>"
        )
    }

    func test_snapToSafeBoundary_returns_bodyEnd_when_no_more_lines() {
        // No newlines after cursor → no safe boundary → returns bodyEnd.
        let xhtml = "<p>foo</p>"
        let snapped = PackageEditor.snapToSafeBoundary(
            in: xhtml, near: 4, bodyEnd: xhtml.count
        )
        XCTAssertEqual(snapped, xhtml.count)
    }

    // MARK: - End-to-end: split + reload

    func test_splitChapter_creates_new_file_and_updates_spine() throws {
        let pkg = try buildMinimalEPUB(chapterCount: 1)
        let editor = PackageEditor(workingDirectory: tempDir, package: pkg)

        let chapter1 = editor.absoluteURL(forManifestHref: "ch01.xhtml")
        let original = try String(contentsOf: chapter1, encoding: .utf8)
        // The split offset lands inside `<p>second paragraph</p>`,
        // which should snap forward to right after that paragraph's
        // closing tag.
        guard let bodyRange = PackageEditor.bodyRange(in: original) else {
            XCTFail("expected body in test fixture")
            return
        }
        let body = String(original[bodyRange])
        // Find offset of "second paragraph" mid-string in the full
        // document so we cross a safe boundary.
        guard let pPos = original.range(of: "<p>second") else {
            XCTFail("missing <p>second in fixture")
            return
        }
        let splitOffset = original.distance(from: original.startIndex, to: pPos.lowerBound) + 5
        _ = body  // silence unused

        let newURL = try editor.splitChapter(at: chapter1, splitOffset: splitOffset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))

        // Re-read the OPF: spine should now have two entries; the
        // new one should be right after the original.
        let pkg2 = try OPFReader().read(rootDir: tempDir)
        XCTAssertEqual(pkg2.spine.count, 2,
            "split should add one entry to the spine")
        // Original chapter's manifest id stays first; new entry is second.
        XCTAssertEqual(pkg2.spine.first, pkg.spine.first)

        // Snap-forward semantics: cursor's element stays in first
        // half; everything from the NEXT line-starting-with-`<`
        // moves to the second half.
        let firstHalf = try String(contentsOf: chapter1, encoding: .utf8)
        XCTAssertTrue(firstHalf.contains("<p>first paragraph</p>"))
        XCTAssertTrue(firstHalf.contains("<p>second"),
            "cursor's element stays in the first half")
        XCTAssertFalse(firstHalf.contains("<p>third"),
            "third paragraph should have moved to the new file")

        let secondHalf = try String(contentsOf: newURL, encoding: .utf8)
        XCTAssertTrue(secondHalf.contains("<p>third paragraph"))
        XCTAssertFalse(secondHalf.contains("<p>first paragraph"))
    }

    // MARK: - End-to-end: merge

    func test_mergeWithNextChapter_combines_files_and_drops_one() throws {
        let pkg = try buildMinimalEPUB(chapterCount: 2)
        let editor = PackageEditor(workingDirectory: tempDir, package: pkg)
        let chapter1 = editor.absoluteURL(forManifestHref: "ch01.xhtml")
        let chapter2 = editor.absoluteURL(forManifestHref: "ch02.xhtml")

        try editor.mergeWithNextChapter(at: chapter1)

        // Chapter 2 file should be gone; chapter 1 should have the
        // combined body.
        XCTAssertFalse(FileManager.default.fileExists(atPath: chapter2.path),
            "merged-from file should be deleted")
        let combined = try String(contentsOf: chapter1, encoding: .utf8)
        XCTAssertTrue(combined.contains("first paragraph"))
        XCTAssertTrue(combined.contains("Chapter Two"),
            "merged file should contain chapter 2's heading text")

        // Re-read OPF: spine has one entry now.
        let pkg2 = try OPFReader().read(rootDir: tempDir)
        XCTAssertEqual(pkg2.spine.count, 1)
    }

    func test_mergeWithNextChapter_throws_on_last_chapter() throws {
        let pkg = try buildMinimalEPUB(chapterCount: 2)
        let editor = PackageEditor(workingDirectory: tempDir, package: pkg)
        let chapter2 = editor.absoluteURL(forManifestHref: "ch02.xhtml")
        XCTAssertThrowsError(
            try editor.mergeWithNextChapter(at: chapter2)
        ) { error in
            guard let editError = error as? PackageEditor.EditError else {
                XCTFail("expected PackageEditor.EditError, got \(error)")
                return
            }
            if case .alreadyLastInSpine = editError {} else {
                XCTFail("expected alreadyLastInSpine, got \(editError)")
            }
        }
    }

    // MARK: - End-to-end: regenerate nav

    func test_regenerateNav_extracts_titles_from_chapters() throws {
        let pkg = try buildMinimalEPUB(chapterCount: 2)
        let editor = PackageEditor(workingDirectory: tempDir, package: pkg)
        try editor.regenerateNav()

        guard let nav = editor.navItem() else {
            XCTFail("expected nav item")
            return
        }
        let navContent = try String(
            contentsOf: editor.absoluteURL(forManifestHref: nav.href),
            encoding: .utf8
        )
        XCTAssertTrue(navContent.contains("Chapter One"))
        XCTAssertTrue(navContent.contains("Chapter Two"))
        XCTAssertTrue(navContent.contains("href=\"ch01.xhtml\""))
        XCTAssertTrue(navContent.contains("href=\"ch02.xhtml\""))
    }

    // MARK: - First heading title

    func test_firstHeadingTitle_picks_h1() throws {
        let url = tempDir.appendingPathComponent("h1.xhtml")
        let html = """
        <html><body>
          <h2>Section</h2>
          <h1>Real Title</h1>
        </body></html>
        """
        try html.write(to: url, atomically: true, encoding: .utf8)
        let title = try PackageEditor.firstHeadingTitle(in: url)
        XCTAssertEqual(title, "Real Title")
    }

    func test_firstHeadingTitle_falls_through_h1_h2_h3() throws {
        let url = tempDir.appendingPathComponent("h3only.xhtml")
        let html = "<html><body><h3>Only h3</h3></body></html>"
        try html.write(to: url, atomically: true, encoding: .utf8)
        let title = try PackageEditor.firstHeadingTitle(in: url)
        XCTAssertEqual(title, "Only h3")
    }

    func test_firstHeadingTitle_returns_nil_for_no_headings() throws {
        let url = tempDir.appendingPathComponent("plain.xhtml")
        let html = "<html><body><p>No headings here.</p></body></html>"
        try html.write(to: url, atomically: true, encoding: .utf8)
        let title = try PackageEditor.firstHeadingTitle(in: url)
        XCTAssertNil(title)
    }

    // MARK: - Fixture builder

    /// Build a minimal EPUB working tree under `tempDir` with
    /// `chapterCount` chapters, each containing two paragraphs and an
    /// h1 heading. Returns the parsed package.
    private func buildMinimalEPUB(chapterCount: Int) throws -> OPFReader.Package {
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

        let titles = ["Chapter One", "Chapter Two", "Chapter Three"]
        var manifestItems: [String] = []
        var spineItems: [String] = []
        for i in 0..<chapterCount {
            let title = titles[i]
            let id = String(format: "ch%02d", i + 1)
            let href = "ch\(String(format: "%02d", i + 1)).xhtml"
            try """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>\(title)</title></head>
            <body>
            <h1>\(title)</h1>
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
        // Nav item.
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
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
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

        return try OPFReader().read(rootDir: tempDir)
    }
}
