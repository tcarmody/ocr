import XCTest
import Foundation
import CoreGraphics
import CoreText
import ZIPFoundation
import Document
import EPUB
@testable import Pipeline

/// End-to-end pipeline test: generate a PDF with known text, run it through
/// the full PDF → OCR → EPUB pipeline, verify the EPUB exists and contains
/// the expected text. Slower than unit tests (Vision OCR runs) but the only
/// place that exercises the entire wire-up.
final class PDFToEPUBPipelineTests: XCTestCase {

    func test_generatedPDF_runsThroughFullPipeline_andProducesEPUBContainingText() async throws {
        // Vision needs reasonably large, high-contrast text to read reliably.
        let lines = [
            "Humanist end to end test",
            "The quick brown fox jumps over the lazy dog",
            "Walking skeleton phase one",
        ]

        let pdfURL = makeTempURL(ext: "pdf")
        let epubURL = makeTempURL(ext: "epub")
        defer {
            try? FileManager.default.removeItem(at: pdfURL)
            try? FileManager.default.removeItem(at: epubURL)
        }

        try writeTextPDF(lines: lines, to: pdfURL)

        let pipeline = PDFToEPUBPipeline()
        try await pipeline.convert(
            pdfURL: pdfURL,
            outputURL: epubURL,
            options: .init(dpi: 300, languages: [.en], ocrQuality: .accurate)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: epubURL.path))
        let archive = try Archive(url: epubURL, accessMode: .read)
        let xhtml = try readEntry("OEBPS/text/chapter-001.xhtml", from: archive)

        // Vision is not perfect — we shouldn't require an exact match.
        // Demand that at least one of the lines appears in the body and
        // that the body is rendered as paragraphs (post-Phase-1.5: no
        // more "Page N" debug headings).
        XCTAssertTrue(xhtml.contains("<p>"), "Body should be wrapped in paragraphs")
        XCTAssertFalse(xhtml.contains("Page 1"),
                       "Phase 1.5 removes the per-page debug headings")
        let matches = lines.filter { xhtml.contains($0) }
        XCTAssertFalse(matches.isEmpty,
                       "Vision should have recognized at least one of: \(lines). Got XHTML:\n\(xhtml)")
    }

    // MARK: helpers

    private func makeTempURL(ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pipeline-test-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    /// Render `lines` to a single-page PDF using Core Graphics. We rasterize
    /// the text via Core Text + CGContext rather than emitting it as PDF
    /// text glyphs so the OCR path actually exercises Vision (otherwise
    /// PDFKit's text extraction would short-circuit it later).
    private func writeTextPDF(lines: [String], to url: URL) throws {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)  // US Letter, points
        var box = pageRect
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "PipelineTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create PDF context at \(url.path)"
            ])
        }
        ctx.beginPDFPage(nil)

        // White page.
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(pageRect)

        // Big, high-contrast text via Core Text — rasterized to PDF.
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]

        var y: CGFloat = 700
        for line in lines {
            let attr = CFAttributedStringCreate(kCFAllocatorDefault, line as CFString, attrs as CFDictionary)!
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(ctLine, ctx)
            y -= 60
        }

        ctx.endPDFPage()
        ctx.closePDF()
    }

    private func readEntry(_ path: String, from archive: Archive) throws -> String {
        guard let entry = archive[path] else {
            throw NSError(domain: "PipelineTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Entry not found: \(path)"
            ])
        }
        var collected = Data()
        _ = try archive.extract(entry, consumer: { collected.append($0) })
        return String(data: collected, encoding: .utf8) ?? ""
    }
}
