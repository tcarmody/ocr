import Foundation
import CoreGraphics
import OCR

/// Common shape for any backend that turns a `.formula` region into
/// MathML markup. Returning `nil` means "skip / fall back to the
/// raster figure" — the cascade emits a `Block.figure` with the
/// region's PNG as the user-visible fallback.
///
/// Today only `ClaudeMathExtractor` (Sonnet 4.6) conforms; future
/// Gemini Flash and Mathpix implementations will conform without
/// touching the cascade-loop call site (mirrors `TableExtractor`).
///
/// Returned string MUST be a single `<math>` element with its own
/// `xmlns="http://www.w3.org/1998/Math/MathML"` (or empty / nil if
/// the backend can't produce valid MathML). The reflow stage
/// drops it verbatim into an `InlineRun.rawXHTML`; the EPUB writer
/// emits it without escaping.
public protocol MathExtractor: Sendable {
    func extract(
        pageImage: CGImage,
        regionBox: CGRect,
        stagingDir: URL,
        pageIndex: Int,
        regionIndex: Int
    ) async -> String?
}
