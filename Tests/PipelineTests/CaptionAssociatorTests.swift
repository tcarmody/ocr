import XCTest
import CoreGraphics
import Layout
@testable import Pipeline

/// Tests `CaptionAssociator` — pairs `.picture` / `.formula` regions
/// with their nearest `.caption`, picking orientation (above/below)
/// from a vote across the first 5 figures and applying it book-wide.
final class CaptionAssociatorTests: XCTestCase {

    /// Make a region with all the boilerplate filled in.
    private func region(_ kind: LayoutRegion.Kind, _ box: CGRect, _ ord: Int = 0) -> LayoutRegion {
        LayoutRegion(kind: kind, box: box, readingOrder: ord, confidence: 1.0)
    }

    // MARK: - basic pairing

    func test_caption_below_picture_associates_when_orientation_is_below() {
        // Picture y=0.4..0.7, caption y=0.32..0.36 (just below).
        let regions = [
            region(.picture, CGRect(x: 0.1, y: 0.40, width: 0.8, height: 0.30)),
            region(.caption, CGRect(x: 0.1, y: 0.32, width: 0.8, height: 0.04)),
        ]
        let assoc = CaptionAssociator.associate(regionsByPage: [0: regions])
        XCTAssertEqual(assoc.orientation, .below)
        XCTAssertEqual(assoc.captionByFigure.count, 1)
        let figureKey = CaptionAssociator.PageRegionKey(pageIndex: 0, regionIndex: 0)
        let captionKey = CaptionAssociator.PageRegionKey(pageIndex: 0, regionIndex: 1)
        XCTAssertEqual(assoc.captionByFigure[figureKey], captionKey)
    }

    func test_horizontal_overlap_is_required() {
        // Picture in left half, caption in right half — no overlap.
        let regions = [
            region(.picture, CGRect(x: 0.05, y: 0.40, width: 0.30, height: 0.30)),
            region(.caption, CGRect(x: 0.65, y: 0.32, width: 0.30, height: 0.04)),
        ]
        let assoc = CaptionAssociator.associate(regionsByPage: [0: regions])
        XCTAssertTrue(assoc.captionByFigure.isEmpty)
    }

    // MARK: - orientation voting

    func test_majority_below_locks_orientation_book_wide() {
        // Three pages each with picture + caption-below.
        // One page has caption-above too — the orientation should
        // still resolve to `below` (3 below votes vs 0 above; the
        // page with both still picks the closer side, which is
        // tie-broken to above when distances are equal so we make
        // them unequal here).
        var regionsByPage: [Int: [LayoutRegion]] = [:]
        regionsByPage[0] = [
            region(.picture, CGRect(x: 0.1, y: 0.40, width: 0.8, height: 0.30)),
            region(.caption, CGRect(x: 0.1, y: 0.32, width: 0.8, height: 0.04)),
        ]
        regionsByPage[1] = [
            region(.picture, CGRect(x: 0.1, y: 0.40, width: 0.8, height: 0.30)),
            region(.caption, CGRect(x: 0.1, y: 0.32, width: 0.8, height: 0.04)),
        ]
        regionsByPage[2] = [
            region(.picture, CGRect(x: 0.1, y: 0.40, width: 0.8, height: 0.30)),
            region(.caption, CGRect(x: 0.1, y: 0.32, width: 0.8, height: 0.04)),
        ]
        let assoc = CaptionAssociator.associate(regionsByPage: regionsByPage)
        XCTAssertEqual(assoc.orientation, .below)
        XCTAssertEqual(assoc.captionByFigure.count, 3)
    }

    func test_majority_above_picks_caption_above() {
        // Captions above pictures on three pages.
        var regionsByPage: [Int: [LayoutRegion]] = [:]
        for i in 0..<3 {
            regionsByPage[i] = [
                region(.picture, CGRect(x: 0.1, y: 0.30, width: 0.8, height: 0.30)),
                region(.caption, CGRect(x: 0.1, y: 0.65, width: 0.8, height: 0.04)),
            ]
        }
        let assoc = CaptionAssociator.associate(regionsByPage: regionsByPage)
        XCTAssertEqual(assoc.orientation, .above)
        XCTAssertEqual(assoc.captionByFigure.count, 3)
    }

    // MARK: - empty / no candidates

    func test_no_pictures_yields_empty_associations() {
        let regions = [
            region(.text, CGRect(x: 0.1, y: 0.10, width: 0.8, height: 0.05)),
            region(.caption, CGRect(x: 0.1, y: 0.20, width: 0.8, height: 0.05)),
        ]
        let assoc = CaptionAssociator.associate(regionsByPage: [0: regions])
        XCTAssertTrue(assoc.captionByFigure.isEmpty)
    }

    func test_no_captions_yields_no_associations_but_default_orientation() {
        let regions = [
            region(.picture, CGRect(x: 0.1, y: 0.30, width: 0.8, height: 0.30)),
        ]
        let assoc = CaptionAssociator.associate(regionsByPage: [0: regions])
        XCTAssertTrue(assoc.captionByFigure.isEmpty)
        XCTAssertEqual(assoc.orientation, .below)
    }

    // MARK: - closer caption wins

    func test_closer_caption_wins_when_two_are_below() {
        // Two captions below the picture, one closer than the other.
        let regions = [
            region(.picture, CGRect(x: 0.1, y: 0.50, width: 0.8, height: 0.20)),
            region(.caption, CGRect(x: 0.1, y: 0.45, width: 0.8, height: 0.04)),  // close
            region(.caption, CGRect(x: 0.1, y: 0.10, width: 0.8, height: 0.04)),  // far
        ]
        let assoc = CaptionAssociator.associate(regionsByPage: [0: regions])
        let figureKey = CaptionAssociator.PageRegionKey(pageIndex: 0, regionIndex: 0)
        let closerKey = CaptionAssociator.PageRegionKey(pageIndex: 0, regionIndex: 1)
        XCTAssertEqual(assoc.captionByFigure[figureKey], closerKey)
    }
}
