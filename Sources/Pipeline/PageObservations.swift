import Foundation
import CoreGraphics
import OCR
import Layout

/// All OCR observations from a single rendered page, plus the page geometry
/// needed to interpret bounding boxes.
///
/// `pageBounds` is in pixels (the size of the rasterized page image).
/// Vision returns observation boxes in normalized [0,1] coordinates with
/// origin at the bottom-left, so they can be interpreted without knowing
/// the pixel size — but downstream code that needs absolute positions
/// (e.g. line-height in pixels) reads `pageBounds`.
///
/// `layoutRegions` is non-nil when Phase 4's Surya layout analyzer
/// produced typed regions for this page. The region-aware reflow path
/// uses them to drop running heads/feet/footnotes structurally and
/// to recover reading order across columns. Empty array vs nil:
/// empty means analyzer ran but found nothing; nil means no analyzer.
struct PageObservations: Sendable {
    let pageIndex: Int
    let pageBounds: CGSize
    let observations: [TextObservation]
    let layoutRegions: [LayoutRegion]?

    init(
        pageIndex: Int,
        pageBounds: CGSize,
        observations: [TextObservation],
        layoutRegions: [LayoutRegion]? = nil
    ) {
        self.pageIndex = pageIndex
        self.pageBounds = pageBounds
        self.observations = observations
        self.layoutRegions = layoutRegions
    }
}

/// Identifies one observation within a multi-page collection. Used by the
/// header/footer classifier to mark observations for removal without
/// mutating the collection.
struct ObservationKey: Hashable, Sendable {
    let pageIndex: Int
    let observationIndex: Int
}
