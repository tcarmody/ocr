import Foundation
import CoreGraphics
import OCR

/// All OCR observations from a single rendered page, plus the page geometry
/// needed to interpret bounding boxes.
///
/// `pageBounds` is in pixels (the size of the rasterized page image).
/// Vision returns observation boxes in normalized [0,1] coordinates with
/// origin at the bottom-left, so they can be interpreted without knowing
/// the pixel size — but downstream code that needs absolute positions
/// (e.g. line-height in pixels) reads `pageBounds`.
struct PageObservations: Sendable {
    let pageIndex: Int
    let pageBounds: CGSize
    let observations: [TextObservation]
}

/// Identifies one observation within a multi-page collection. Used by the
/// header/footer classifier to mark observations for removal without
/// mutating the collection.
struct ObservationKey: Hashable, Sendable {
    let pageIndex: Int
    let observationIndex: Int
}
