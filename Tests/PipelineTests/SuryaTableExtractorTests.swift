import XCTest
import CoreGraphics
@testable import Pipeline

/// Tests `SuryaTableExtractor.translateCellBox` — the math that
/// converts Surya's pixel/top-left cell bbox (in cropped-image
/// coords) back to the full page's normalized/bottom-left coords.
/// The live sidecar pathway is exercised manually; these unit tests
/// pin the geometry so a refactor of `RegionCascade.cropMargin` or
/// the y-flip can't silently break alignment.
final class SuryaTableExtractorTests: XCTestCase {

    /// Cell occupying the entire cropped image should map back to
    /// the full inflated region (region + 2% crop margin on each
    /// side, clamped to [0,1]).
    func test_full_cell_maps_to_inflated_region() {
        let region = CGRect(x: 0.20, y: 0.30, width: 0.60, height: 0.40)
        // Use realistic crop pixel size — what RegionCascade.cropImage
        // would have produced for this region on a 1000×1000 page.
        let cropSize = CGSize(width: 640, height: 440)
        let fullCell = CGRect(x: 0, y: 0, width: 640, height: 440)
        let mapped = SuryaTableExtractor.translateCellBox(
            fullCell, cropImageSize: cropSize, regionBox: region
        )
        // Inflated by `RegionCascade.cropMargin` (2%).
        let margin: CGFloat = 0.02
        let expected = region.insetBy(dx: -margin, dy: -margin)
        XCTAssertEqual(mapped.minX, expected.minX, accuracy: 0.001)
        XCTAssertEqual(mapped.minY, expected.minY, accuracy: 0.001)
        XCTAssertEqual(mapped.width, expected.width, accuracy: 0.001)
        XCTAssertEqual(mapped.height, expected.height, accuracy: 0.001)
    }

    /// A cell occupying the TOP-LEFT quadrant of the cropped image
    /// (in pixel/top-left coords) should land in the TOP-LEFT
    /// portion of the page in full-page normalized coords. The y-axis
    /// flip is the easiest place to break.
    func test_top_left_pixel_quadrant_maps_to_top_of_page() {
        // Region centered with no margin clipping.
        let region = CGRect(x: 0.30, y: 0.30, width: 0.40, height: 0.40)
        let cropSize = CGSize(width: 200, height: 200)
        let topLeftPixel = CGRect(x: 0, y: 0, width: 100, height: 100)
        let mapped = SuryaTableExtractor.translateCellBox(
            topLeftPixel, cropImageSize: cropSize, regionBox: region
        )
        // y=0..100 in pixel-top-left corresponds to the upper half
        // of the cropped image, which lands in the upper half of the
        // inflated region in full-page normalized coords.
        let margin: CGFloat = 0.02
        let inflated = region.insetBy(dx: -margin, dy: -margin)
        let midNormalizedY = inflated.minY + inflated.height / 2
        XCTAssertEqual(mapped.maxY, inflated.maxY, accuracy: 0.001,
                       "top-of-pixel should map to top-of-region")
        XCTAssertEqual(mapped.minY, midNormalizedY, accuracy: 0.001,
                       "bottom-of-cell at pixel y=100/200 → mid of region in normalized")
        // x-axis: left half maps to left half (no flip).
        XCTAssertEqual(mapped.minX, inflated.minX, accuracy: 0.001)
        XCTAssertEqual(mapped.maxX, inflated.minX + inflated.width / 2, accuracy: 0.001)
    }

    /// Bottom-right pixel quadrant should land in the bottom-right
    /// portion of the region in normalized coords.
    func test_bottom_right_pixel_quadrant_maps_to_bottom_of_page() {
        let region = CGRect(x: 0.30, y: 0.30, width: 0.40, height: 0.40)
        let cropSize = CGSize(width: 200, height: 200)
        let bottomRightPixel = CGRect(x: 100, y: 100, width: 100, height: 100)
        let mapped = SuryaTableExtractor.translateCellBox(
            bottomRightPixel, cropImageSize: cropSize, regionBox: region
        )
        let margin: CGFloat = 0.02
        let inflated = region.insetBy(dx: -margin, dy: -margin)
        XCTAssertEqual(mapped.minY, inflated.minY, accuracy: 0.001,
                       "bottom-of-pixel should map to bottom-of-region")
        XCTAssertEqual(mapped.maxX, inflated.maxX, accuracy: 0.001,
                       "right-of-pixel should map to right-of-region")
    }

    /// Defensive: zero-sized crop returns a zero rect rather than NaN.
    func test_zero_crop_size_returns_zero_rect() {
        let region = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)
        let mapped = SuryaTableExtractor.translateCellBox(
            CGRect(x: 0, y: 0, width: 100, height: 100),
            cropImageSize: .zero,
            regionBox: region
        )
        XCTAssertEqual(mapped, .zero)
    }
}
