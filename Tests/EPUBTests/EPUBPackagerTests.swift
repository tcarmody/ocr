import XCTest
import Foundation
@testable import EPUB

final class EPUBPackagerTests: XCTestCase {

    // MARK: validate()

    func test_validate_rejects_when_first_entry_is_not_mimetype() {
        let entries = [
            EPUBPackager.Entry(path: "META-INF/container.xml", data: Data("x".utf8)),
        ]
        XCTAssertThrowsError(try EPUBPackager.validate(entries: entries)) { error in
            XCTAssertEqual(error as? EPUBPackager.PackagingError, .firstEntryMustBeMimetype)
        }
    }

    func test_validate_rejects_compressed_mimetype() {
        let entries = [
            EPUBPackager.Entry(
                path: "mimetype",
                data: Data("application/epub+zip".utf8),
                compressed: true
            ),
        ]
        XCTAssertThrowsError(try EPUBPackager.validate(entries: entries)) { error in
            XCTAssertEqual(error as? EPUBPackager.PackagingError, .mimetypeMustBeUncompressed)
        }
    }

    func test_validate_rejects_wrong_mimetype_content() {
        let entries = [
            EPUBPackager.Entry(
                path: "mimetype",
                data: Data("application/epub+zip\n".utf8),  // trailing newline is wrong
                compressed: false
            ),
        ]
        XCTAssertThrowsError(try EPUBPackager.validate(entries: entries)) { error in
            XCTAssertEqual(error as? EPUBPackager.PackagingError, .mimetypeContentMismatch)
        }
    }

    func test_validate_passes_minimal_valid_entries() throws {
        let entries = [
            EPUBPackager.Entry(
                path: "mimetype",
                data: Data("application/epub+zip".utf8),
                compressed: false
            ),
            EPUBPackager.Entry(path: "META-INF/container.xml", data: Data("<container/>".utf8)),
        ]
        XCTAssertNoThrow(try EPUBPackager.validate(entries: entries))
    }

    // MARK: write() — inspect actual ZIP byte layout

    func test_writeProducesZipWithMimetypeAsFirstEntryUncompressed() throws {
        let outputURL = makeTempURL(ext: "epub")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let entries = [
            EPUBPackager.Entry(
                path: "mimetype",
                data: Data("application/epub+zip".utf8),
                compressed: false
            ),
            EPUBPackager.Entry(path: "META-INF/container.xml", data: Data("<container/>".utf8)),
            EPUBPackager.Entry(path: "OEBPS/content.opf", data: Data("<package/>".utf8)),
        ]

        try EPUBPackager().write(entries, to: outputURL)

        let header = try Data(contentsOf: outputURL).prefix(64)

        // ZIP local file header magic: "PK\x03\x04" at offset 0.
        XCTAssertEqual(Array(header.prefix(4)), [0x50, 0x4B, 0x03, 0x04],
                       "EPUB must start with a local file header")

        // The ZIP local file header's compression-method field is 2 bytes
        // at offset 8 (little-endian). For 'mimetype' it must be 0 (stored).
        let compressionMethod = UInt16(header[8]) | (UInt16(header[9]) << 8)
        XCTAssertEqual(compressionMethod, 0,
                       "First entry (mimetype) must be stored uncompressed (method 0)")

        // The filename starts after the 30-byte fixed header. It should be
        // exactly "mimetype" (8 bytes).
        let filenameStart = 30
        let filenameLength = 8
        let filenameBytes = header.dropFirst(filenameStart).prefix(filenameLength)
        XCTAssertEqual(String(data: Data(filenameBytes), encoding: .ascii), "mimetype",
                       "First entry filename must be 'mimetype'")
    }

    // MARK: helpers

    private func makeTempURL(ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub-packager-test-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }
}
