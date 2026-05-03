import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Document
@testable import OCR

final class TesseractOCREngineTests: XCTestCase {

    // MARK: - language mapping (pure, no binary needed)

    func test_tesseractLangCode_modern_scripts() {
        XCTAssertEqual(TesseractOCREngine.tesseractLangCode(.en), "eng")
        XCTAssertEqual(TesseractOCREngine.tesseractLangCode(.fr), "fra")
        XCTAssertEqual(TesseractOCREngine.tesseractLangCode(.de), "deu")
    }

    func test_tesseractLangCode_ancient_scripts() {
        XCTAssertEqual(TesseractOCREngine.tesseractLangCode(.grc), "grc")
        XCTAssertEqual(TesseractOCREngine.tesseractLangCode(.la),  "lat")
    }

    func test_tesseractLangCode_strips_subtags() {
        // "la-x-medieval" should still resolve to lat.
        XCTAssertEqual(TesseractOCREngine.tesseractLangCode(.laMedieval), "lat")
        XCTAssertEqual(TesseractOCREngine.tesseractLangCode(.grcKoine),   "grc")
    }

    // MARK: - TSV parsing (pure, no binary needed)

    func test_parseTSV_returns_one_observation_per_line() {
        // Minimal Tesseract TSV: header + 1 page row + 1 block + 1 par +
        // 1 line + 2 word rows. Should produce one observation joining
        // the two words.
        let tsv = """
        level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
        1\t1\t0\t0\t0\t0\t0\t0\t1000\t2000\t-1\t
        2\t1\t1\t0\t0\t0\t100\t200\t800\t100\t-1\t
        3\t1\t1\t1\t0\t0\t100\t200\t800\t100\t-1\t
        4\t1\t1\t1\t1\t0\t100\t200\t800\t100\t-1\t
        5\t1\t1\t1\t1\t1\t100\t200\t300\t100\t95\tHello
        5\t1\t1\t1\t1\t2\t450\t200\t450\t100\t90\tworld
        """
        let result = TesseractOCREngine.parseTSV(tsv, imageWidth: 1000, imageHeight: 2000)
        XCTAssertEqual(result.observations.count, 1)
        let obs = result.observations[0]
        XCTAssertEqual(obs.text, "Hello world")
        XCTAssertEqual(obs.source, .tesseract)
        // Confidence is mean of 95 and 90 → 92.5 → 0.925.
        XCTAssertEqual(obs.confidence, 0.925, accuracy: 0.001)
        // Bounding box converted to Vision normalized: x=100/1000=0.1,
        // top=200, height=100 → bottomY = 1 - (200+100)/2000 = 0.85.
        XCTAssertEqual(obs.box.minX, 0.1, accuracy: 0.001)
        XCTAssertEqual(obs.box.minY, 0.85, accuracy: 0.001)
        XCTAssertEqual(obs.box.width, 0.8, accuracy: 0.001)
        XCTAssertEqual(obs.box.height, 0.05, accuracy: 0.001)
    }

    func test_parseTSV_groups_multiple_lines() {
        // Two lines of two words each.
        let tsv = """
        level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
        4\t1\t1\t1\t1\t0\t100\t100\t800\t50\t-1\t
        5\t1\t1\t1\t1\t1\t100\t100\t300\t50\t90\tFirst
        5\t1\t1\t1\t1\t2\t450\t100\t450\t50\t88\tline
        4\t1\t1\t1\t2\t0\t100\t200\t800\t50\t-1\t
        5\t1\t1\t1\t2\t1\t100\t200\t300\t50\t92\tSecond
        5\t1\t1\t1\t2\t2\t450\t200\t450\t50\t91\tline
        """
        let result = TesseractOCREngine.parseTSV(tsv, imageWidth: 1000, imageHeight: 1000)
        XCTAssertEqual(result.observations.count, 2)
        // Sorted top-to-bottom (higher midY first).
        XCTAssertEqual(result.observations[0].text, "First line")
        XCTAssertEqual(result.observations[1].text, "Second line")
    }

    func test_parseTSV_skips_empty_lines_and_header() {
        let tsv = """
        level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
        5\t1\t1\t1\t1\t1\t10\t10\t100\t20\t90\t
        5\t1\t1\t1\t1\t2\t120\t10\t100\t20\t-1\t
        """
        let result = TesseractOCREngine.parseTSV(tsv, imageWidth: 1000, imageHeight: 1000)
        XCTAssertEqual(result.observations.count, 0,
                       "Words with empty text and no recognized text should produce no observation")
    }

    // MARK: - end-to-end (skipped if tesseract not installed)

    func test_endToEnd_recognizesEnglishText_skippedIfNotInstalled() async throws {
        guard let engine = TesseractOCREngine.detect() else {
            throw XCTSkip("tesseract binary not installed; run `brew install tesseract tesseract-lang`")
        }

        // Render a known-text image: white background, big black text.
        let image = renderTextImage(
            text: "Humanist Tesseract end to end test",
            width: 1200, height: 240
        )
        let result = try await engine.recognize(
            image: image,
            hints: OCRHints(languages: [.en], quality: .accurate)
        )
        XCTAssertFalse(result.observations.isEmpty,
                       "Tesseract should produce at least one observation for clean printed text")
        XCTAssertTrue(result.text.contains("Humanist"),
                      "Should recognize 'Humanist' in the rendered text. Got: \(result.text)")
        XCTAssertTrue(result.observations.allSatisfy { $0.source == .tesseract })
    }

    // MARK: - helpers

    private func renderTextImage(text: String, width: Int, height: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue
                   | CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: bitmap
        )!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 60, y: 80)
        CTLineDraw(line, ctx)

        return ctx.makeImage()!
    }
}
