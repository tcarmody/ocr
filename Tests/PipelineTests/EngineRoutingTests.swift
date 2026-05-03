import XCTest
import Document
@testable import Pipeline

final class EngineRoutingTests: XCTestCase {

    func test_modern_latin_languages_prefer_vision() {
        XCTAssertFalse(PDFToEPUBPipeline.shouldPreferTesseract(for: [.en]))
        XCTAssertFalse(PDFToEPUBPipeline.shouldPreferTesseract(for: [.fr, .de]))
        XCTAssertFalse(PDFToEPUBPipeline.shouldPreferTesseract(for: [.it, .es]))
    }

    func test_ancient_languages_prefer_tesseract() {
        XCTAssertTrue(PDFToEPUBPipeline.shouldPreferTesseract(for: [.grc]))
        XCTAssertTrue(PDFToEPUBPipeline.shouldPreferTesseract(for: [.la]))
        XCTAssertTrue(PDFToEPUBPipeline.shouldPreferTesseract(for: [.la, .en]),
                      "Any ancient language in the list flips the routing")
    }

    func test_subtagged_ancient_languages_prefer_tesseract() {
        XCTAssertTrue(PDFToEPUBPipeline.shouldPreferTesseract(for: [.grcKoine]))
        XCTAssertTrue(PDFToEPUBPipeline.shouldPreferTesseract(for: [.laMedieval]))
    }

    func test_non_latin_modern_scripts_prefer_tesseract() {
        XCTAssertTrue(PDFToEPUBPipeline.shouldPreferTesseract(for: ["he"]))
        XCTAssertTrue(PDFToEPUBPipeline.shouldPreferTesseract(for: ["ar"]))
        XCTAssertTrue(PDFToEPUBPipeline.shouldPreferTesseract(for: ["zh"]))
        XCTAssertTrue(PDFToEPUBPipeline.shouldPreferTesseract(for: ["ru"]))
    }
}
