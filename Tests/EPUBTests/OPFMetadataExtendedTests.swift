import XCTest
import Foundation
@testable import EPUB

/// Coverage for the year / publisher / ISBN fields added to
/// `OPFReader.Metadata` and their round-trip through
/// `EPUBBookSaver.updateMetadataInPlace`. Verifies that:
///   * parsing accepts the common shapes (bare year, ISO date,
///     URN-prefixed ISBN, scheme-attributed ISBN);
///   * the package's `unique-identifier` element is never mistaken
///     for the ISBN even when ISBN-shaped;
///   * the saver adds the ISBN as a *separate* `<dc:identifier>`
///     so the unique-identifier stays untouched.
final class OPFMetadataExtendedTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OPFMetadataExtended-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - parse

    func test_parse_bare_year_dc_date() throws {
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">test-id</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            <dc:date>2003</dc:date>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertEqual(book.metadata.year, "2003")
    }

    func test_parse_iso_timestamp_dc_date_keeps_year_prefix() throws {
        // Real-world EPUBs use the full ISO 8601 form in
        // <dc:date>; only the year is what we want.
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">test-id</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            <dc:date>2003-04-15T00:00:00Z</dc:date>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertEqual(book.metadata.year, "2003")
    }

    func test_parse_publisher() throws {
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">test-id</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            <dc:publisher>Princeton University Press</dc:publisher>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertEqual(book.metadata.publisher, "Princeton University Press")
    }

    func test_parse_urn_prefixed_isbn_identifier() throws {
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">internal-uuid</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            <dc:identifier>urn:isbn:9780691180052</dc:identifier>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertEqual(book.metadata.isbn, "9780691180052")
    }

    func test_parse_scheme_attributed_isbn_strips_hyphens() throws {
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">internal-uuid</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            <dc:identifier opf:scheme="ISBN">978-0-691-18005-2</dc:identifier>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertEqual(book.metadata.isbn, "9780691180052",
            "hyphens should be stripped on read")
    }

    func test_parse_skips_package_unique_identifier_even_when_ISBN_shaped() throws {
        // The package's unique-identifier might *happen* to be
        // ISBN-shaped; that's identity, not bibliographic ISBN.
        // The parser must not promote it.
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">9781234567890</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertNil(book.metadata.isbn,
            "package unique-identifier must not be parsed as ISBN")
    }

    func test_parse_missing_fields_returns_nil() throws {
        // Backward compat: pre-extension EPUBs (just title /
        // author / language) load with nil for the new fields.
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">test-id</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertNil(book.metadata.year)
        XCTAssertNil(book.metadata.publisher)
        XCTAssertNil(book.metadata.isbn)
    }

    // MARK: - save round trip

    func test_save_writes_year_and_publisher_when_set() throws {
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">test-id</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        book.metadata = OPFReader.Metadata(
            title: book.metadata.title,
            author: book.metadata.author,
            language: book.metadata.language,
            year: "2003",
            publisher: "Princeton University Press"
        )
        try EPUBBookSaver().save(book)

        let reloaded = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertEqual(reloaded.metadata.year, "2003")
        XCTAssertEqual(reloaded.metadata.publisher, "Princeton University Press")
    }

    func test_save_adds_isbn_as_separate_identifier_preserving_unique_id() throws {
        // The unique-identifier element must survive the ISBN
        // write — readers + library tools rely on
        // `<package unique-identifier="bookid">` resolving.
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">internal-uuid</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        book.metadata = OPFReader.Metadata(
            title: book.metadata.title,
            author: book.metadata.author,
            language: book.metadata.language,
            isbn: "9780691180052"
        )
        try EPUBBookSaver().save(book)

        let opfText = try String(contentsOf: book.opfURL, encoding: .utf8)
        XCTAssertTrue(opfText.contains(#"id="bookid""#),
            "the unique-identifier element must remain")
        XCTAssertTrue(opfText.contains("internal-uuid"),
            "the unique-identifier value must remain")
        XCTAssertTrue(opfText.contains("urn:isbn:9780691180052"),
            "ISBN should be added as a URN-shaped identifier")
    }

    func test_save_updates_existing_isbn_in_place() throws {
        // Re-saving with a different ISBN should update the
        // existing ISBN element, not append a third identifier.
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">internal-uuid</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            <dc:identifier>urn:isbn:9780000000000</dc:identifier>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertEqual(book.metadata.isbn, "9780000000000")
        book.metadata = OPFReader.Metadata(
            title: book.metadata.title,
            language: book.metadata.language,
            isbn: "9780691180052"
        )
        try EPUBBookSaver().save(book)

        let opfText = try String(contentsOf: book.opfURL, encoding: .utf8)
        // The new value present, the old absent. No third
        // identifier — match URN substring count.
        XCTAssertTrue(opfText.contains("urn:isbn:9780691180052"))
        XCTAssertFalse(opfText.contains("urn:isbn:9780000000000"))
    }

    func test_save_skips_writing_when_metadata_unchanged() throws {
        // Sanity check the existing equality check in
        // updateMetadataInPlace's caller — same metadata in,
        // same metadata out, OPF text shouldn't differ in
        // ways that matter. (The save still runs because
        // dcterms:modified always bumps.)
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">test-id</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            <dc:date>2003</dc:date>
            <dc:publisher>X Press</dc:publisher>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertEqual(book.metadata.year, "2003")
        XCTAssertEqual(book.metadata.publisher, "X Press")
    }

    // MARK: - dc:source round trip

    func test_parse_dc_source_url() throws {
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">test-id</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            <dc:source>file:///Users/me/Documents/foo.pdf</dc:source>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertEqual(
            book.metadata.source,
            "file:///Users/me/Documents/foo.pdf"
        )
    }

    func test_parse_missing_dc_source_is_nil() throws {
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">test-id</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertNil(book.metadata.source)
    }

    func test_save_writes_dc_source_when_set() throws {
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">test-id</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        book.metadata = OPFReader.Metadata(
            title: book.metadata.title,
            language: book.metadata.language,
            source: "file:///Users/me/Documents/foo.pdf"
        )
        try EPUBBookSaver().save(book)

        let reloaded = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertEqual(
            reloaded.metadata.source,
            "file:///Users/me/Documents/foo.pdf"
        )
    }

    func test_save_clearing_dc_source_removes_the_element() throws {
        try buildEPUB(metadataBlock: """
            <dc:identifier id="bookid">test-id</dc:identifier>
            <dc:title>Book</dc:title>
            <dc:language>en</dc:language>
            <dc:source>file:///old/path.pdf</dc:source>
            """)
        let book = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertEqual(book.metadata.source, "file:///old/path.pdf")
        book.metadata = OPFReader.Metadata(
            title: book.metadata.title,
            language: book.metadata.language,
            source: nil
        )
        try EPUBBookSaver().save(book)

        let reloaded = try EPUBBookLoader().load(
            sourceURL: tempDir.appendingPathComponent("source.epub"),
            workingDirectory: tempDir
        )
        XCTAssertNil(reloaded.metadata.source)
    }

    // MARK: - fixture helper

    private func buildEPUB(metadataBlock: String) throws {
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

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter 1</title></head>
        <body><p>body</p></body>
        </html>
        """.write(
            to: oebps.appendingPathComponent("ch01.xhtml"),
            atomically: true, encoding: .utf8
        )
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Nav</title></head>
        <body><nav epub:type="toc"><ol></ol></nav></body>
        </html>
        """.write(
            to: oebps.appendingPathComponent("nav.xhtml"),
            atomically: true, encoding: .utf8
        )

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        \(metadataBlock)
        </metadata>
        <manifest>
        <item id="ch01" href="ch01.xhtml" media-type="application/xhtml+xml"/>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        </manifest>
        <spine>
        <itemref idref="ch01"/>
        </spine>
        </package>
        """
        try opfXML.write(
            to: oebps.appendingPathComponent("content.opf"),
            atomically: true, encoding: .utf8
        )
    }
}
