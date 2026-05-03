import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Document
@testable import OCR

final class TesseractOCREngineTests: XCTestCase {

    // MARK: - language mapping (pure, no library needed)

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
        XCTAssertEqual(TesseractOCREngine.tesseractLangCode(.laMedieval), "lat")
        XCTAssertEqual(TesseractOCREngine.tesseractLangCode(.grcKoine),   "grc")
    }

    // MARK: - end-to-end (skipped if tessdata not installed)

    func test_endToEnd_recognizesEnglishText_skippedIfNotInstalled() async throws {
        guard let engine = TesseractOCREngine.detect() else {
            throw XCTSkip("tessdata not installed; run `brew install tesseract tesseract-lang`")
        }

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
