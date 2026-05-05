import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import PDFIngest

/// `DocumentProfiler` tests. Build small fixture PDFs that carry
/// embedded text on demand, then verify the profiler picks the right
/// language and aggregates samples reasonably.
///
/// Living in PipelineTests because the test target already depends on
/// PDFIngest there. No new test target needed.
final class DocumentProfilerTests: XCTestCase {

    // MARK: - sampleIndices

    func test_sampleIndices_short_doc_returns_what_it_has() {
        XCTAssertEqual(DocumentProfiler.sampleIndices(pageCount: 0, target: 3), [])
        XCTAssertEqual(DocumentProfiler.sampleIndices(pageCount: 1, target: 3), [0])
        // 2 pages: skip cover (0), so just page 1.
        XCTAssertEqual(DocumentProfiler.sampleIndices(pageCount: 2, target: 3), [1])
    }

    func test_sampleIndices_skips_cover_and_spaces_evenly() {
        // 100 pages, target 3: indices roughly 25%, 50%, 75% of body.
        // Body is pages 1..99 (99 pages). Target 3 → positions at
        // 1/4, 2/4, 3/4 = ~25, ~50, ~75. Plus body offset 1.
        let idx = DocumentProfiler.sampleIndices(pageCount: 100, target: 3)
        XCTAssertEqual(idx.count, 3)
        XCTAssertGreaterThan(idx[0], 0, "Should skip cover")
        XCTAssertGreaterThan(idx[1], idx[0])
        XCTAssertGreaterThan(idx[2], idx[1])
        XCTAssertLessThan(idx[2], 100)
    }

    func test_sampleIndices_target_larger_than_body_returns_all_body() {
        // 5 pages, target 10: body is pages 1..4 (4 pages, less than
        // target). Return all 4.
        XCTAssertEqual(
            DocumentProfiler.sampleIndices(pageCount: 5, target: 10),
            [1, 2, 3, 4]
        )
    }

    // MARK: - profile() integration

    func test_profile_english_pdf_detects_en_with_high_confidence() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTextPDF(pages: [Self.englishParagraph, Self.englishParagraph], to: url)

        let profile = DocumentProfiler.profile(pdfURL: url)
        XCTAssertEqual(profile.primaryLanguage, "en")
        XCTAssertGreaterThan(profile.confidence, 0.7)
        XCTAssertFalse(profile.isLikelyScan)
        XCTAssertEqual(profile.pageCount, 2)
    }

    func test_profile_no_embedded_text_flags_likely_scan() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeBlankPDF(pages: 3, to: url)

        let profile = DocumentProfiler.profile(pdfURL: url)
        XCTAssertNil(profile.primaryLanguage)
        XCTAssertEqual(profile.confidence, 0)
        XCTAssertTrue(profile.isLikelyScan)
    }

    func test_profile_mixed_languages_picks_dominant() throws {
        // 1 cover (skipped) + 3 English body pages + 1 short Italian
        // page. English wins on weight (more characters with high
        // confidence), but Italian shows up as secondary if it crosses
        // the 20% weight floor.
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTextPDF(
            pages: [
                Self.coverPlaceholder,
                Self.englishParagraph, Self.englishParagraph, Self.englishParagraph,
                Self.italianParagraph,
            ],
            to: url
        )
        let profile = DocumentProfiler.profile(pdfURL: url)
        XCTAssertEqual(profile.primaryLanguage, "en")
    }

    func test_profile_empty_pdf_returns_zeroed_profile() {
        // Empty/missing URL → no doc opens → zeroed profile.
        let bogus = URL(fileURLWithPath: "/no/such/file.pdf")
        let profile = DocumentProfiler.profile(pdfURL: bogus)
        XCTAssertNil(profile.primaryLanguage)
        XCTAssertEqual(profile.pageCount, 0)
        XCTAssertEqual(profile.samplesAnalyzed, 0)
    }

    // MARK: - fixtures

    private static let englishParagraph = """
        This is a paragraph of clean English prose. It contains several \
        sentences with proper words, normal punctuation, and a length \
        sufficient to give the natural-language recognizer something \
        solid to work with. We expect the profiler to detect English \
        with high confidence on a passage like this one.
        """

    private static let italianParagraph = """
        Questa è una breve paragrafo di prosa italiana per il \
        rilevamento linguistico. Contiene parole abbastanza comuni e \
        una struttura coerente.
        """

    private static let coverPlaceholder = "Cover"

    private func makeTempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("profiler-test-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
    }

    /// Generate a multi-page PDF where each entry in `pages` is the
    /// full text of one page. `CTLineDraw` to a `CGPDFContext` emits
    /// real text glyphs (not rasterized images) so PDFKit's
    /// `page.string` will return the embedded text.
    private func writeTextPDF(pages: [String], to url: URL) throws {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        var box = pageRect
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(
                domain: "ProfilerTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "PDF context creation failed"]
            )
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(
                red: 0, green: 0, blue: 0, alpha: 1
            ),
        ]
        for body in pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(pageRect)
            // Frame-set the paragraph so it wraps within the page
            // margins. CTFramesetter handles line breaking + draws
            // glyphs into the PDF as text.
            let attributed = CFAttributedStringCreate(
                kCFAllocatorDefault, body as CFString, attrs as CFDictionary
            )!
            let frameSetter = CTFramesetterCreateWithAttributedString(attributed)
            let textRect = pageRect.insetBy(dx: 60, dy: 60)
            let path = CGMutablePath()
            path.addRect(textRect)
            let frame = CTFramesetterCreateFrame(
                frameSetter, CFRangeMake(0, 0), path, nil
            )
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// PDF with the requested number of blank pages — no embedded
    /// text. Mimics the flatbed-scan case the profiler should flag
    /// as a likely scan.
    private func writeBlankPDF(pages: Int, to url: URL) throws {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        var box = pageRect
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "ProfilerTest", code: 1)
        }
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(pageRect)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
