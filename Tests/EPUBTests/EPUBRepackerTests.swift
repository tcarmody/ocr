import XCTest
@testable import EPUB

final class EPUBRepackerTests: XCTestCase {

    /// Round-trip: build a tiny EPUB working tree on disk, repack it,
    /// re-unpack, and verify file paths + contents survive.
    func test_repack_roundtrip_preserves_files() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HumanistTest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Source working dir
        let srcDir = temp.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try EPUBStaticFiles.mimetype.write(
            to: srcDir.appendingPathComponent("mimetype"),
            atomically: true, encoding: .utf8
        )
        let metaDir = srcDir.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try EPUBStaticFiles.containerXML.write(
            to: metaDir.appendingPathComponent("container.xml"),
            atomically: true, encoding: .utf8
        )
        let oebpsDir = srcDir.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: oebpsDir, withIntermediateDirectories: true)
        let chapterText = "<?xml version=\"1.0\"?><html><body><p>Hello round-trip.</p></body></html>"
        try chapterText.write(
            to: oebpsDir.appendingPathComponent("chapter-001.xhtml"),
            atomically: true, encoding: .utf8
        )

        // Repack → re-unpack
        let epubURL = temp.appendingPathComponent("out.epub")
        try EPUBRepacker().repack(workingDirectory: srcDir, to: epubURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: epubURL.path))

        let unpackDir = try EPUBUnpacker().unpack(epubURL: epubURL, into: temp)
        let chapterURL = unpackDir
            .appendingPathComponent("OEBPS")
            .appendingPathComponent("chapter-001.xhtml")
        XCTAssertEqual(
            try String(contentsOf: chapterURL, encoding: .utf8),
            chapterText
        )
        let mimeURL = unpackDir.appendingPathComponent("mimetype")
        XCTAssertEqual(
            try String(contentsOf: mimeURL, encoding: .utf8),
            EPUBStaticFiles.mimetype
        )
    }

    func test_repack_fails_when_mimetype_missing() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HumanistTest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let srcDir = temp.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        // No mimetype written.

        let epubURL = temp.appendingPathComponent("out.epub")
        XCTAssertThrowsError(
            try EPUBRepacker().repack(workingDirectory: srcDir, to: epubURL)
        ) { error in
            guard let e = error as? EPUBRepacker.RepackError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            XCTAssertEqual(e, .missingMimetype)
        }
    }
}

extension EPUBRepacker.RepackError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.missingMimetype, .missingMimetype),
             (.mimetypeContentMismatch, .mimetypeContentMismatch):
            return true
        case (.readFailed(let a), .readFailed(let b)):
            return a == b
        default:
            return false
        }
    }
}
