import XCTest
import CoreGraphics
import AppKit
import AI
@testable import Pipeline

/// Tests that `ClaudePageOCREngine.encodeForAnthropic` produces
/// output that fits the Anthropic Messages-API image-input limits:
/// max 8000 px on either dimension, max 5 MB base64-encoded. Big
/// scan-DPI source images get downsized; small images pass through
/// untouched. The actual issue this fixes (which produced blank
/// EPUBs across an entire conversion run): API rejected every
/// page's request with "exceeds 5 MB maximum" / "exceeds max
/// allowed size: 8000 pixels", and the per-page error swallow
/// hid the failure — claude-pages.txt was the diagnostic that
/// surfaced it.
final class ClaudePageImageResizeTests: XCTestCase {

    func test_oversized_image_gets_resized_under_5MB() throws {
        // 9000 × 6000 px synthetic image — both blows the 8000-px
        // limit AND would produce a > 5 MB PNG.
        let image = makeImage(width: 9000, height: 6000)
        let result = try XCTUnwrap(ClaudePageOCREngine.encodeForAnthropic(image))
        XCTAssertLessThanOrEqual(result.data.count, 5 * 1024 * 1024)
        XCTAssertLessThanOrEqual(result.longEdge, 8000)
    }

    func test_already_small_image_passes_through_untouched_dimension() throws {
        // 1000 × 800 — well under all limits. Should pass through
        // at original dimensions (no upscaling).
        let image = makeImage(width: 1000, height: 800)
        let result = try XCTUnwrap(ClaudePageOCREngine.encodeForAnthropic(image))
        XCTAssertEqual(result.longEdge, 1000)
    }

    func test_at_preferred_dim_passes_through() throws {
        // 1568 × 1024 — exactly the preferred max dim. Should not
        // get downsized.
        let image = makeImage(width: 1568, height: 1024)
        let result = try XCTUnwrap(ClaudePageOCREngine.encodeForAnthropic(image))
        XCTAssertEqual(result.longEdge, 1568)
    }

    func test_high_res_models_keep_2576_px_when_under_3_75_MP() throws {
        // 2:1 landscape: 2576 × 1288 = 3.3 MP, under the pixel cap,
        // so the long edge lands exactly on the model max. Flat image
        // compresses well, so the 5 MB cap never forces a step down.
        let image = makeFlatImage(width: 5152, height: 2576)
        for model in [CloudModel.sonnet5_5, .opus5_5] {
            let result = try XCTUnwrap(ClaudePageOCREngine.encodeForAnthropic(
                image,
                maxLongEdge: model.maxImageLongEdge,
                maxPixels: model.maxImagePixels
            ))
            XCTAssertEqual(result.longEdge, 2576, model.rawValue)
        }
    }

    func test_portrait_page_is_capped_at_3_75_MP() throws {
        // A4-ish portrait at scan DPI: 2576 px long edge would be
        // ~4.7 MP, so the pixel cap wins (~2300 px long edge).
        let image = makeFlatImage(width: 4960, height: 7016)
        for model in [CloudModel.sonnet5_5, .opus5_5] {
            let result = try XCTUnwrap(ClaudePageOCREngine.encodeForAnthropic(
                image,
                maxLongEdge: model.maxImageLongEdge,
                maxPixels: model.maxImagePixels
            ))
            let decoded = try XCTUnwrap(NSImage(data: result.data)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertLessThanOrEqual(decoded.width * decoded.height, 3_750_000, model.rawValue)
            XCTAssertGreaterThan(result.longEdge, 2200, model.rawValue)
            XCTAssertLessThan(result.longEdge, 2576, model.rawValue)
        }
    }

    func test_longEdgeFitting() {
        let small = makeFlatImage(width: 1000, height: 800)
        XCTAssertEqual(ClaudePageOCREngine.longEdgeFitting(small, maxPixels: 3_750_000), Int.max)
        XCTAssertEqual(ClaudePageOCREngine.longEdgeFitting(small, maxPixels: nil), Int.max)
        let big = makeFlatImage(width: 3000, height: 4000)  // 12 MP, 4:3
        let edge = ClaudePageOCREngine.longEdgeFitting(big, maxPixels: 3_750_000)
        // sqrt(3.75M × 4/3) ≈ 2236
        XCTAssertEqual(Double(edge), 2235, accuracy: 2)
    }

    func test_other_models_still_cap_at_1568_px() throws {
        let image = makeFlatImage(width: 4000, height: 3000)
        let result = try XCTUnwrap(ClaudePageOCREngine.encodeForAnthropic(
            image,
            maxLongEdge: CloudModel.opus4_7.maxImageLongEdge,
            maxPixels: CloudModel.opus4_7.maxImagePixels
        ))
        XCTAssertEqual(result.longEdge, 1568)
    }

    func test_oversized_2576_page_fits_base64_limit() throws {
        // Noise-pattern image overflows 5 MB at 2576 px; the encoder
        // must step down and the *base64* payload must fit.
        let image = makeImage(width: 9000, height: 6000)
        let result = try XCTUnwrap(ClaudePageOCREngine.encodeForAnthropic(
            image, maxLongEdge: 2576
        ))
        XCTAssertLessThanOrEqual(
            ClaudePageOCREngine.base64Length(result.data.count), 5 * 1024 * 1024
        )
        XCTAssertLessThanOrEqual(result.longEdge, 2576)
    }

    func test_base64_length() {
        XCTAssertEqual(ClaudePageOCREngine.base64Length(0), 0)
        XCTAssertEqual(ClaudePageOCREngine.base64Length(1), 4)
        XCTAssertEqual(ClaudePageOCREngine.base64Length(3), 4)
        XCTAssertEqual(ClaudePageOCREngine.base64Length(4), 8)
    }

    // MARK: - Helpers

    /// Build a synthetic CGImage filled with a noise-like pattern
    /// (each pixel a different color) so PNG compression can't trivialize
    /// the file size. Real OCR pages have similar entropy from text
    /// rendering, so this is a representative test fixture.
    /// Single-color image — compresses to a tiny PNG at any size.
    private func makeFlatImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * bytesPerRow) + (x * 4)
                bytes[i + 0] = UInt8((x * 7 + y * 11) & 0xFF)
                bytes[i + 1] = UInt8((x * 13 + y * 17) & 0xFF)
                bytes[i + 2] = UInt8((x * 19 + y * 23) & 0xFF)
                bytes[i + 3] = 255
            }
        }
        let ctx = CGContext(
            data: &bytes,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }
}
