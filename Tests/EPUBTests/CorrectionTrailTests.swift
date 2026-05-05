import XCTest
import Foundation
import Document
@testable import EPUB

final class CorrectionTrailTests: XCTestCase {

    /// EPUBBuilder writes META-INF/com.humanist.correction-trail.json
    /// when a non-empty trail is passed; CorrectionTrail.read decodes
    /// the same entries back after unpack.
    func test_trail_round_trips_through_epub_build_and_unpack() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HumanistTest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temp, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        let book = Book(
            title: "Test", language: .en,
            chapters: [
                Chapter(title: "Body", blocks: [
                    .paragraph(runs: [InlineRun("Body text.")])
                ])
            ]
        )
        let trail = CorrectionTrail(entries: [
            CorrectionTrail.Entry(
                pageIndex: 0, regionIndex: 0,
                anchorId: "hu-page-0",
                original: "abcdefg hijklmn",
                suggested: "abcdefg hijklmn corrected",
                accepted: true,
                rejectionReason: nil,
                mode: "passages"
            ),
            CorrectionTrail.Entry(
                pageIndex: 1, regionIndex: 2,
                anchorId: "hu-page-1",
                original: "the original",
                suggested: "completely different translation",
                accepted: false,
                rejectionReason: "scriptDrift",
                mode: "vision"
            ),
        ])

        let epubURL = temp.appendingPathComponent("out.epub")
        try EPUBBuilder().write(book: book, correctionTrail: trail, to: epubURL)

        let workingDir = try EPUBUnpacker().unpack(epubURL: epubURL, into: temp)
        guard let decoded = CorrectionTrail.read(workingDirectory: workingDir) else {
            XCTFail("CorrectionTrail.read returned nil")
            return
        }
        XCTAssertEqual(decoded.entries.count, 2)
        XCTAssertEqual(decoded.entries[0].original, "abcdefg hijklmn")
        XCTAssertTrue(decoded.entries[0].accepted)
        XCTAssertEqual(decoded.entries[1].rejectionReason, "scriptDrift")
        XCTAssertEqual(decoded.entries[1].mode, "vision")
    }

    /// Building without a trail (or with an empty trail) leaves no
    /// trail sidecar — keeps non-Cleanup-mode EPUBs clean.
    func test_no_trail_means_no_sidecar() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HumanistTest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temp, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        let book = Book(
            title: "Plain", language: .en,
            chapters: [
                Chapter(title: "Body", blocks: [
                    .paragraph(runs: [InlineRun("Body.")])
                ])
            ]
        )

        let epubURL = temp.appendingPathComponent("out.epub")
        try EPUBBuilder().write(book: book, to: epubURL)
        let workingDir = try EPUBUnpacker().unpack(epubURL: epubURL, into: temp)
        XCTAssertNil(CorrectionTrail.read(workingDirectory: workingDir))

        // Same with an explicitly empty trail.
        let epub2 = temp.appendingPathComponent("out2.epub")
        try EPUBBuilder().write(
            book: book,
            correctionTrail: CorrectionTrail(entries: []),
            to: epub2
        )
        let wd2 = try EPUBUnpacker().unpack(epubURL: epub2, into: temp)
        XCTAssertNil(CorrectionTrail.read(workingDirectory: wd2))
    }
}
