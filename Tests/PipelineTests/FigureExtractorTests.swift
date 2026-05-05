import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Layout
@testable import Pipeline

/// Tests `FigureExtractor` — the raster-crop path that pulls
/// `.picture` and `.formula` region bytes out of a rendered page.
final class FigureExtractorTests: XCTestCase {

    /// Build a 800x600 white CGImage with a colored rectangle drawn
    /// in normalized region coordinates (y=0 bottom, y=1 top, mapped
    /// to top-left CGImage coords). Lets us verify the cropper
    /// returns the right region.
    private func makePageImage(
        width: Int = 800, height: Int = 600,
        regionsToFill: [(rect: CGRect, color: CGColor)] = []
    ) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: info
        )!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for entry in regionsToFill {
            // Convert normalized bottom-left to pixel top-left for
            // CGContext (which is bottom-left, but our region coords
            // already are too — easy match).
            let pixelRect = CGRect(
                x: entry.rect.minX * CGFloat(width),
                y: entry.rect.minY * CGFloat(height),
                width: entry.rect.width * CGFloat(width),
                height: entry.rect.height * CGFloat(height)
            )
            ctx.setFillColor(entry.color)
            ctx.fill(pixelRect)
        }
        return ctx.makeImage()!
    }

    // MARK: - tests

    func test_extract_picture_region_returns_png_bytes_and_size() {
        let pictureBox = CGRect(x: 0.20, y: 0.30, width: 0.60, height: 0.40)
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let pageImage = makePageImage(regionsToFill: [(pictureBox, red)])

        let regions: [LayoutRegion] = [
            LayoutRegion(kind: .text, box: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
                         readingOrder: 0, confidence: 1.0),
            LayoutRegion(kind: .picture, box: pictureBox,
                         readingOrder: 1, confidence: 1.0),
        ]
        let figures = FigureExtractor().extract(
            pageIndex: 0, regions: regions, pageImage: pageImage
        )
        XCTAssertEqual(figures.count, 1)
        let fig = figures[0]
        XCTAssertEqual(fig.regionIndex, 1)
        XCTAssertEqual(fig.regionKind, .picture)
        XCTAssertEqual(fig.mediaType, "image/png")
        XCTAssertGreaterThan(fig.data.count, 0)
        // PNG signature: 89 50 4E 47 0D 0A 1A 0A
        let expected: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(fig.data.prefix(8)), expected,
                       "Output bytes should be a valid PNG file")
        // Intrinsic size matches the cropped pixel dimensions
        // (region width/height × page width/height + 2% margin
        // each side, then `.integral`-rounded by RegionCascade).
        XCTAssertGreaterThan(fig.intrinsicSize.width, 0)
        XCTAssertGreaterThan(fig.intrinsicSize.height, 0)
    }

    func test_extract_formula_region_treated_as_image() {
        let formulaBox = CGRect(x: 0.30, y: 0.40, width: 0.40, height: 0.10)
        let pageImage = makePageImage()
        let regions: [LayoutRegion] = [
            LayoutRegion(kind: .formula, box: formulaBox,
                         readingOrder: 0, confidence: 1.0),
        ]
        let figures = FigureExtractor().extract(
            pageIndex: 5, regions: regions, pageImage: pageImage
        )
        XCTAssertEqual(figures.count, 1)
        XCTAssertEqual(figures[0].regionKind, .formula)
        XCTAssertEqual(figures[0].pageIndex, 5)
    }

    func test_extract_skips_non_picture_kinds() {
        let pageImage = makePageImage()
        let regions: [LayoutRegion] = [
            LayoutRegion(kind: .text, box: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.1),
                         readingOrder: 0, confidence: 1.0),
            LayoutRegion(kind: .caption, box: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.05),
                         readingOrder: 1, confidence: 1.0),
            LayoutRegion(kind: .table, box: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.1),
                         readingOrder: 2, confidence: 1.0),
        ]
        let figures = FigureExtractor().extract(
            pageIndex: 0, regions: regions, pageImage: pageImage
        )
        XCTAssertEqual(figures.count, 0)
    }

    func test_extract_preserves_region_index_for_caption_pairing() {
        let pageImage = makePageImage()
        let regions: [LayoutRegion] = [
            LayoutRegion(kind: .text,    box: CGRect(x: 0.1, y: 0.85, width: 0.8, height: 0.05),
                         readingOrder: 0, confidence: 1.0),
            LayoutRegion(kind: .picture, box: CGRect(x: 0.1, y: 0.30, width: 0.8, height: 0.40),
                         readingOrder: 1, confidence: 1.0),
            LayoutRegion(kind: .caption, box: CGRect(x: 0.1, y: 0.20, width: 0.8, height: 0.05),
                         readingOrder: 2, confidence: 1.0),
            LayoutRegion(kind: .picture, box: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.10),
                         readingOrder: 3, confidence: 1.0),
        ]
        let figures = FigureExtractor().extract(
            pageIndex: 0, regions: regions, pageImage: pageImage
        )
        XCTAssertEqual(figures.count, 2)
        XCTAssertEqual(figures.map(\.regionIndex), [1, 3])
    }
}
