import XCTest
import CoreGraphics
import AppKit
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

    // MARK: - Helpers

    /// Build a synthetic CGImage filled with a noise-like pattern
    /// (each pixel a different color) so PNG compression can't trivialize
    /// the file size. Real OCR pages have similar entropy from text
    /// rendering, so this is a representative test fixture.
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
