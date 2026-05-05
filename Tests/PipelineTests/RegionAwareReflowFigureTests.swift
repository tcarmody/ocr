import XCTest
import CoreGraphics
import Document
import Layout
import OCR
@testable import Pipeline

/// Tests the figure-emission path through `RegionAwareReflow.reflow`.
/// Phase 6 wiring: `.picture` regions become `Block.figure`,
/// associated `.caption` regions are absorbed into the figure block
/// and don't double-emit as paragraphs, and the cover-image
/// detection fires for the page-0 dominant figure case.
final class RegionAwareReflowFigureTests: XCTestCase {

    // Helpers ------------------------------------------------------

    private func region(_ kind: LayoutRegion.Kind, _ box: CGRect, _ ord: Int) -> LayoutRegion {
        LayoutRegion(kind: kind, box: box, readingOrder: ord, confidence: 1.0)
    }

    private func obs(_ text: String, _ box: CGRect) -> TextObservation {
        TextObservation(text: text, confidence: 1.0, box: box, source: .vision)
    }

    private func makeFigureExtraction(
        pageIndex: Int, regionIndex: Int, regionBox: CGRect, kind: LayoutRegion.Kind = .picture
    ) -> FigureExtractor.ExtractedFigure {
        FigureExtractor.ExtractedFigure(
            pageIndex: pageIndex,
            regionIndex: regionIndex,
            data: Data([0x89, 0x50, 0x4E, 0x47]),  // 4 PNG bytes — enough for plumbing
            mediaType: "image/png",
            intrinsicSize: CGSize(width: 100, height: 80),
            regionBox: regionBox,
            regionKind: kind
        )
    }

    // MARK: - figure emission

    func test_picture_region_emits_figure_block_with_extracted_caption() {
        // Simple page: text at top, picture, caption below picture.
        let textBox = CGRect(x: 0.1, y: 0.85, width: 0.8, height: 0.05)
        let pictureBox = CGRect(x: 0.1, y: 0.30, width: 0.8, height: 0.40)
        let captionBox = CGRect(x: 0.1, y: 0.20, width: 0.8, height: 0.05)
        let regions = [
            region(.text, textBox, 0),
            region(.picture, pictureBox, 1),
            region(.caption, captionBox, 2),
        ]
        let observations = [
            obs("Body paragraph text.", CGRect(x: 0.1, y: 0.86, width: 0.8, height: 0.02)),
            obs("Figure 1. A diagram.", CGRect(x: 0.1, y: 0.21, width: 0.8, height: 0.03)),
        ]
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 800, height: 1000),
            observations: observations,
            layoutRegions: regions
        )
        let figureExtractions: [Int: [FigureExtractor.ExtractedFigure]] = [
            0: [makeFigureExtraction(pageIndex: 0, regionIndex: 1, regionBox: pictureBox)],
        ]
        let associations = CaptionAssociator.associate(regionsByPage: [0: regions])

        let result = RegionAwareReflow.reflow(
            pageResults: [page],
            figureExtractions: figureExtractions,
            captionAssociations: associations
        )

        // Expect: anchor, paragraph(body), figure, (no standalone caption paragraph).
        let nonAnchorBlocks = result.blocks.filter {
            if case .anchor = $0 { return false } else { return true }
        }
        XCTAssertEqual(nonAnchorBlocks.count, 2,
                       "Expected paragraph + figure (caption absorbed), got \(nonAnchorBlocks.count)")
        let figureBlock = nonAnchorBlocks.first { if case .figure = $0 { return true } else { return false } }
        guard case let .figure(assetId, alt, captionRuns) = figureBlock! else {
            XCTFail("Expected a .figure block"); return
        }
        XCTAssertEqual(assetId, "fig-00000",
                       "First extracted figure should get id fig-00000")
        XCTAssertEqual(alt, "Figure 1. A diagram.",
                       "Alt text should default to the caption text")
        XCTAssertEqual(captionRuns.map(\.text).joined(), "Figure 1. A diagram.")

        // Asset is in the result.
        XCTAssertEqual(result.figureAssets.count, 1)
        XCTAssertEqual(result.figureAssets[0].id, "fig-00000")
    }

    func test_picture_with_no_caption_emits_figure_with_generic_alt() {
        let pictureBox = CGRect(x: 0.1, y: 0.30, width: 0.8, height: 0.40)
        let regions = [region(.picture, pictureBox, 0)]
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 800, height: 1000),
            observations: [],
            layoutRegions: regions
        )
        let figureExtractions: [Int: [FigureExtractor.ExtractedFigure]] = [
            0: [makeFigureExtraction(pageIndex: 0, regionIndex: 0, regionBox: pictureBox)],
        ]
        let result = RegionAwareReflow.reflow(
            pageResults: [page],
            figureExtractions: figureExtractions
        )
        let figureBlock = result.blocks.first { if case .figure = $0 { return true } else { return false } }
        guard case let .figure(_, alt, captionRuns) = figureBlock! else {
            XCTFail("Expected .figure block"); return
        }
        XCTAssertEqual(alt, "figure")
        XCTAssertTrue(captionRuns.isEmpty)
    }

    func test_unmatched_caption_still_emits_as_paragraph() {
        // Caption region exists but has no horizontally-overlapping
        // picture; it should fall through to the paragraph path so
        // the user doesn't lose the text entirely.
        let pictureBox = CGRect(x: 0.05, y: 0.30, width: 0.30, height: 0.40)
        let captionBox = CGRect(x: 0.65, y: 0.30, width: 0.30, height: 0.05)
        let regions = [
            region(.picture, pictureBox, 0),
            region(.caption, captionBox, 1),
        ]
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 800, height: 1000),
            observations: [
                obs("Standalone caption text.", CGRect(x: 0.65, y: 0.31, width: 0.30, height: 0.03)),
            ],
            layoutRegions: regions
        )
        let figureExtractions: [Int: [FigureExtractor.ExtractedFigure]] = [
            0: [makeFigureExtraction(pageIndex: 0, regionIndex: 0, regionBox: pictureBox)],
        ]
        let associations = CaptionAssociator.associate(regionsByPage: [0: regions])
        XCTAssertTrue(associations.captionByFigure.isEmpty,
                      "Sanity: no horizontal overlap ⇒ no association")

        let result = RegionAwareReflow.reflow(
            pageResults: [page],
            figureExtractions: figureExtractions,
            captionAssociations: associations
        )
        // Expect: figure block + paragraph block.
        let kinds: [String] = result.blocks.compactMap {
            switch $0 {
            case .anchor: return nil
            case .heading: return "h"
            case .paragraph: return "p"
            case .figure: return "f"
            }
        }
        XCTAssertTrue(kinds.contains("f"), "Should have a figure block")
        XCTAssertTrue(kinds.contains("p"), "Unmatched caption should still flow as paragraph")
    }

    // MARK: - cover detection

    func test_dominant_page_zero_picture_is_marked_cover() {
        // Single picture covering ≥50% of page 0 → cover.
        let pictureBox = CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.80)
        let regions = [region(.picture, pictureBox, 0)]
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 800, height: 1000),
            observations: [],
            layoutRegions: regions
        )
        let figureExtractions: [Int: [FigureExtractor.ExtractedFigure]] = [
            0: [makeFigureExtraction(pageIndex: 0, regionIndex: 0, regionBox: pictureBox)],
        ]
        let result = RegionAwareReflow.reflow(
            pageResults: [page],
            figureExtractions: figureExtractions
        )
        XCTAssertEqual(result.figureAssets.count, 1)
        XCTAssertTrue(result.figureAssets[0].isCover,
                      "Dominant page-0 picture should be marked as cover")
    }

    func test_small_page_zero_picture_is_not_cover() {
        // 20% × 20% = 4% area — well below the 50% threshold.
        let pictureBox = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)
        let regions = [region(.picture, pictureBox, 0)]
        let page = PageObservations(
            pageIndex: 0,
            pageBounds: CGSize(width: 800, height: 1000),
            observations: [],
            layoutRegions: regions
        )
        let figureExtractions: [Int: [FigureExtractor.ExtractedFigure]] = [
            0: [makeFigureExtraction(pageIndex: 0, regionIndex: 0, regionBox: pictureBox)],
        ]
        let result = RegionAwareReflow.reflow(
            pageResults: [page],
            figureExtractions: figureExtractions
        )
        XCTAssertEqual(result.figureAssets.count, 1)
        XCTAssertFalse(result.figureAssets[0].isCover,
                       "Small page-0 picture should not be cover")
    }

    func test_picture_on_later_page_is_not_cover() {
        let pictureBox = CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.80)
        let regions = [region(.picture, pictureBox, 0)]
        let pageOne = PageObservations(
            pageIndex: 1,
            pageBounds: CGSize(width: 800, height: 1000),
            observations: [],
            layoutRegions: regions
        )
        let figureExtractions: [Int: [FigureExtractor.ExtractedFigure]] = [
            1: [makeFigureExtraction(pageIndex: 1, regionIndex: 0, regionBox: pictureBox)],
        ]
        let result = RegionAwareReflow.reflow(
            pageResults: [pageOne],
            figureExtractions: figureExtractions
        )
        XCTAssertEqual(result.figureAssets.count, 1)
        XCTAssertFalse(result.figureAssets[0].isCover,
                       "Page-1+ pictures shouldn't be marked as cover")
    }
}
