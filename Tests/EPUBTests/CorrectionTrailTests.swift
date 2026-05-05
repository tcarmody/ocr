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

    /// nav.xhtml entries come from the parsed TOC when one is
    /// passed and at least one entry resolves to a known anchor.
    /// Each entry's href points to the chapter file + page anchor
    /// matching its display page (after offset).
    func test_nav_uses_parsed_TOC_when_offset_resolves() {
        let chapterItems: [OPFWriter.Item] = [
            .init(id: "chapter-001", href: "text/chapter-001.xhtml",
                  mediaType: "application/xhtml+xml", properties: nil),
        ]
        let pageMap: [PageMap.Entry] = [
            .init(pdfPage: 0, xhtmlFile: "OEBPS/text/chapter-001.xhtml",
                  anchorId: "hu-page-0"),
            .init(pdfPage: 22, xhtmlFile: "OEBPS/text/chapter-001.xhtml",
                  anchorId: "hu-page-22"),
        ]
        let toc = ParsedTOC(
            entries: [
                ParsedTOC.Entry(title: "Body", displayPage: "1"),
                ParsedTOC.Entry(title: "Conclusion", displayPage: "23"),
            ],
            inferredOffset: 0
        )
        let chapters = [
            Chapter(title: "Heuristic Title", blocks: [],
                    pageAnchors: [
                        PageAnchor(pdfPage: 0, anchorId: "hu-page-0"),
                        PageAnchor(pdfPage: 22, anchorId: "hu-page-22"),
                    ])
        ]
        let nav = EPUBBuilder.makeNavEntries(
            chapters: chapters,
            chapterItems: chapterItems,
            pageMapEntries: pageMap,
            parsedTOC: toc
        )
        XCTAssertEqual(nav.count, 2)
        XCTAssertEqual(nav[0].title, "Body")
        XCTAssertEqual(nav[0].href, "text/chapter-001.xhtml#hu-page-0")
        XCTAssertEqual(nav[1].title, "Conclusion")
        XCTAssertEqual(nav[1].href, "text/chapter-001.xhtml#hu-page-22")
    }

    /// When the parsed TOC has no inferred offset (offset learner
    /// couldn't disambiguate), nav falls back to one entry per
    /// chapter — same as the no-TOC case.
    func test_nav_falls_back_to_chapters_when_no_offset() {
        let chapterItems: [OPFWriter.Item] = [
            .init(id: "chapter-001", href: "text/chapter-001.xhtml",
                  mediaType: "application/xhtml+xml", properties: nil),
        ]
        let toc = ParsedTOC(
            entries: [ParsedTOC.Entry(title: "Body", displayPage: "1")],
            inferredOffset: nil
        )
        let chapters = [Chapter(title: "Single Heuristic", blocks: [])]
        let nav = EPUBBuilder.makeNavEntries(
            chapters: chapters,
            chapterItems: chapterItems,
            pageMapEntries: [],
            parsedTOC: toc
        )
        XCTAssertEqual(nav.count, 1)
        XCTAssertEqual(nav[0].title, "Single Heuristic")
        XCTAssertEqual(nav[0].href, "text/chapter-001.xhtml")
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
