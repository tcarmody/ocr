import Foundation
import CoreGraphics

/// The seam every layout analyzer implements. Surya is the only
/// implementation today; future contenders (docTR, LayoutLM, an Apple
/// Intelligence Vision request, etc.) just conform to this protocol.
public protocol LayoutAnalyzer: Sendable {
    /// Analyze the layout of a rendered page image. The image is
    /// passed by file URL — we're not sandboxed and tmpfile paths are
    /// substantially faster than serializing image bytes.
    ///
    /// `pageBounds` is the pixel size of the rendered image. Returned
    /// region boxes are in normalized [0,1] coordinates with bottom-
    /// left origin (Vision convention).
    func analyze(imageURL: URL, pageBounds: CGSize) async throws -> [LayoutRegion]
}
