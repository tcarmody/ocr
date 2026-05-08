import XCTest
import PDFKit
@testable import Pipeline
import OCR

/// Smoke test the searchable-PDF writer: starting from a blank PDF
/// fixture, layer invisible OCR text on each page, then re-open the
/// output via PDFKit and confirm the text is extractable + lands on
/// the right page. We don't exercise visible content faithfulness
/// here — the writer copies pages with `drawPDFPage`, which PDFKit /
/// CoreGraphics already cover.
final class SearchablePDFWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("searchable-pdf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func test_overlay_makes_text_extractable_per_page() throws {
        // Two-page blank source.
        let sourceURL = try writeBlankPDF(name: "source.pdf", pages: 2)
        let outputURL = tempDir.appendingPathComponent("source.searchable.pdf")

        let pages: [SearchablePDFWriter.PageData] = [
            .init(pageIndex: 0, observations: [
                obs("ALPHAFIRST", at: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.05))
            ]),
            .init(pageIndex: 1, observations: [
                obs("BETASECOND", at: CGRect(x: 0.1, y: 0.4, width: 0.4, height: 0.05))
            ]),
        ]

        try SearchablePDFWriter().write(
            sourcePDFURL: sourceURL,
            pages: pages,
            to: outputURL
        )

        let doc = try XCTUnwrap(PDFDocument(url: outputURL))
        XCTAssertEqual(doc.pageCount, 2)

        let page0 = try XCTUnwrap(doc.page(at: 0)).string ?? ""
        let page1 = try XCTUnwrap(doc.page(at: 1)).string ?? ""
        XCTAssertTrue(page0.contains("ALPHAFIRST"), "page 0 text was: \(page0)")
        XCTAssertTrue(page1.contains("BETASECOND"), "page 1 text was: \(page1)")
        XCTAssertFalse(page0.contains("BETASECOND"))
        XCTAssertFalse(page1.contains("ALPHAFIRST"))
    }

    func test_pages_without_observations_pass_through_silently() throws {
        let sourceURL = try writeBlankPDF(name: "src.pdf", pages: 3)
        let outputURL = tempDir.appendingPathComponent("src.searchable.pdf")

        // Only page 1 gets an overlay; pages 0 and 2 are blank in.
        let pages: [SearchablePDFWriter.PageData] = [
            .init(pageIndex: 1, observations: [
                obs("MIDDLEMARKER", at: CGRect(x: 0.2, y: 0.5, width: 0.3, height: 0.05))
            ])
        ]

        try SearchablePDFWriter().write(
            sourcePDFURL: sourceURL,
            pages: pages,
            to: outputURL
        )

        let doc = try XCTUnwrap(PDFDocument(url: outputURL))
        XCTAssertEqual(doc.pageCount, 3)
        XCTAssertTrue((doc.page(at: 1)?.string ?? "").contains("MIDDLEMARKER"))
        XCTAssertEqual((doc.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual((doc.page(at: 2)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    // MARK: - helpers

    private func obs(_ text: String, at box: CGRect) -> TextObservation {
        TextObservation(text: text, confidence: 0.95, box: box)
    }

    private func writeBlankPDF(name: String, pages: Int) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let doc = PDFDocument()
        let size = NSSize(width: 200, height: 300)
        for i in 0..<pages {
            let img = NSImage(size: size)
            img.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            img.unlockFocus()
            doc.insert(PDFPage(image: img)!, at: i)
        }
        XCTAssertTrue(doc.write(to: url))
        return url
    }
}
