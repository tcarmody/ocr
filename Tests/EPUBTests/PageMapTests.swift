import XCTest
import Foundation
import Document
@testable import EPUB

final class PageMapTests: XCTestCase {

    /// EPUBBuilder writes META-INF/com.humanist.pagemap.json when any
    /// chapter contributes pageAnchors. EPUBUnpacker round-trips it
    /// and PageMap.read decodes the same entries back.
    func test_pageMap_round_trips_through_epub_build_and_unpack() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HumanistTest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let book = Book(
            title: "Test", language: .en,
            chapters: [
                Chapter(
                    title: "Body",
                    blocks: [
                        .anchor(id: "hu-page-0", label: "Page 1"),
                        .paragraph(runs: [InlineRun("Page one body text.")]),
                        .anchor(id: "hu-page-1", label: "Page 2"),
                        .paragraph(runs: [InlineRun("Page two body text.")]),
                    ],
                    pageAnchors: [
                        PageAnchor(pdfPage: 0, anchorId: "hu-page-0"),
                        PageAnchor(pdfPage: 1, anchorId: "hu-page-1"),
                    ]
                )
            ]
        )

        let epubURL = temp.appendingPathComponent("out.epub")
        try EPUBBuilder().write(book: book, to: epubURL)

        let workingDir = try EPUBUnpacker().unpack(epubURL: epubURL, into: temp)
        guard let map = PageMap.read(workingDirectory: workingDir) else {
            XCTFail("PageMap.read returned nil")
            return
        }
        XCTAssertEqual(map.entries.count, 2)
        XCTAssertEqual(map.entries[0].pdfPage, 0)
        XCTAssertEqual(map.entries[0].anchorId, "hu-page-0")
        XCTAssertEqual(map.entries[0].xhtmlFile, "OEBPS/text/chapter-001.xhtml")
        XCTAssertEqual(map.entries[1].pdfPage, 1)
        XCTAssertEqual(map.entries[1].anchorId, "hu-page-1")
    }

    /// Books with no pageAnchors don't get a pagemap sidecar at all
    /// — keeps non-pipeline-produced EPUBs free of editor-only files.
    func test_no_anchors_means_no_pagemap_sidecar() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HumanistTest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let book = Book(
            title: "Plain", language: .en,
            chapters: [
                Chapter(title: "Body", blocks: [
                    .paragraph(runs: [InlineRun("Body text.")])
                ])
            ]
        )

        let epubURL = temp.appendingPathComponent("out.epub")
        try EPUBBuilder().write(book: book, to: epubURL)

        let workingDir = try EPUBUnpacker().unpack(epubURL: epubURL, into: temp)
        XCTAssertNil(PageMap.read(workingDirectory: workingDir))
    }

    /// XHTML emitted for a Block.anchor includes the epub:type=pagebreak
    /// span with the right id and label.
    func test_xhtml_writer_emits_pagebreak_span_for_anchor_block() {
        let chapter = Chapter(
            title: "T",
            blocks: [
                .anchor(id: "hu-page-3", label: "Page 4"),
                .paragraph(runs: [InlineRun("After the anchor.")]),
            ]
        )
        let writer = XHTMLWriter(cssPath: "../css/book.css")
        let xhtml = writer.render(chapter, defaultLanguage: .en, fallbackTitle: "T")
        XCTAssertTrue(
            xhtml.contains("id=\"hu-page-3\""),
            "Expected anchor id in XHTML, got:\n\(xhtml)"
        )
        XCTAssertTrue(
            xhtml.contains("epub:type=\"pagebreak\""),
            "Expected epub:type=pagebreak in XHTML"
        )
        XCTAssertTrue(
            xhtml.contains("aria-label=\"Page 4\""),
            "Expected aria-label in XHTML"
        )
    }
}
