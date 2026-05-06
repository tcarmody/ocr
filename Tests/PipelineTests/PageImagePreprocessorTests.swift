import XCTest
import CoreGraphics
@testable import PDFIngest

/// Smoke tests for `PageImagePreprocessor`. These verify shape +
/// stability rather than visual output — Core Image filter
/// behavior is platform-tested upstream; what we want to catch
/// here is "the filter chain crashed" or "output dimensions
/// changed" or "a missing filter silently returned the input."
final class PageImagePreprocessorTests: XCTestCase {

    /// Build a small RGB CGImage filled with a gradient — gives
    /// the filters a non-trivial input without bringing in fixture
    /// PNGs.
    private func makeImage(width: Int = 200, height: Int = 200) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: info
        )!
        // Vertical gradient — black at top, white at bottom.
        for y in 0..<height {
            let g = CGFloat(y) / CGFloat(height)
            ctx.setFillColor(red: g, green: g, blue: g, alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return ctx.makeImage()!
    }

    func test_preserves_dimensions() {
        let input = makeImage(width: 200, height: 300)
        let p = PageImagePreprocessor()
        let output = p.process(input)
        XCTAssertEqual(output.width, 200)
        XCTAssertEqual(output.height, 300)
    }

    func test_all_filters_disabled_passes_through() {
        let input = makeImage()
        var p = PageImagePreprocessor()
        p.stretchContrast = false
        p.denoise = false
        p.sharpen = false
        let output = p.process(input)
        // No-op filter stack still re-renders through CIContext;
        // we just want dimensions to match — visual equality
        // through CI isn't guaranteed even for identity passes.
        XCTAssertEqual(output.width, input.width)
        XCTAssertEqual(output.height, input.height)
    }

    func test_each_filter_in_isolation_preserves_dimensions() {
        let input = makeImage(width: 150, height: 100)
        for (label, mutate) in [
            ("contrast only", { (p: inout PageImagePreprocessor) in
                p.stretchContrast = true; p.denoise = false; p.sharpen = false
            }),
            ("denoise only",  { (p: inout PageImagePreprocessor) in
                p.stretchContrast = false; p.denoise = true; p.sharpen = false
            }),
            ("sharpen only",  { (p: inout PageImagePreprocessor) in
                p.stretchContrast = false; p.denoise = false; p.sharpen = true
            }),
        ] {
            var p = PageImagePreprocessor()
            mutate(&p)
            let output = p.process(input)
            XCTAssertEqual(output.width, 150, "\(label): width changed")
            XCTAssertEqual(output.height, 100, "\(label): height changed")
        }
    }

    func test_full_chain_is_stable_under_re_run() {
        // Idempotency-ish: running the pipeline twice in a row
        // shouldn't crash or produce drastically different sizes
        // (Core Image filters can sometimes grow extents under
        // sharpen/blur — verify we're staying stable).
        let input = makeImage(width: 256, height: 256)
        let p = PageImagePreprocessor()
        let once = p.process(input)
        let twice = p.process(once)
        XCTAssertEqual(twice.width, 256)
        XCTAssertEqual(twice.height, 256)
    }
}
