import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Document
import Layout

/// Extracts image bytes for `.picture` (and `.formula`) regions on a
/// page, producing assets the EPUB writer can embed. Phase A ships
/// the **raster** path: crop the rendered page CGImage to the
/// region's bbox + a 2% page-height margin and re-encode as PNG.
///
/// A vector path — walking `CGPDFContentStream` for `Do` operators
/// referencing image XObjects whose placement bbox intersects the
/// region — is a quality optimization that can land later. For
/// scanned books (the dominant input today) it would yield the same
/// page-sized image we already raster-cropped, so the raster path is
/// already the correct answer. For born-digital art books with
/// embedded JPEG figures the vector path would preserve original
/// encoding; until then those figures are re-encoded as PNG at the
/// page's render DPI, which is lossless for the visible result and
/// still much smaller than the source page raster.
public struct FigureExtractor {
    public init() {}

    /// One extracted figure, keyed by the index of its source region
    /// within the page's region array. The caller assigns final asset
    /// ids — this type stays decoupled from the book-wide id space.
    public struct ExtractedFigure: Sendable, Codable {
        public let pageIndex: Int
        public let regionIndex: Int
        public let data: Data
        public let mediaType: String
        public let intrinsicSize: CGSize
        /// The source region's normalized bbox (passed through so the
        /// caller can pair it with a caption later without re-scanning
        /// the regions array).
        public let regionBox: CGRect
        /// The source region's `kind` — `.picture` or `.formula`.
        public let regionKind: LayoutRegion.Kind
    }

    /// Pull every `.picture` and `.formula` region out of `regions`,
    /// crop them from `pageImage`, and encode as PNG. Order matches
    /// the input region array; callers should not assume reading
    /// order.
    public func extract(
        pageIndex: Int,
        regions: [LayoutRegion],
        pageImage: CGImage
    ) -> [ExtractedFigure] {
        var out: [ExtractedFigure] = []
        for (idx, region) in regions.enumerated() {
            guard region.kind == .picture || region.kind == .formula else { continue }
            guard let cropped = RegionCascade.cropImage(pageImage, to: region.box) else {
                continue
            }
            guard let png = Self.encodePNG(cropped) else { continue }
            out.append(ExtractedFigure(
                pageIndex: pageIndex,
                regionIndex: idx,
                data: png,
                mediaType: "image/png",
                intrinsicSize: CGSize(width: cropped.width, height: cropped.height),
                regionBox: region.box,
                regionKind: region.kind
            ))
        }
        return out
    }

    /// PNG-encode a CGImage to in-memory Data. Returns nil on
    /// `CGImageDestination` failure (rare; would indicate a corrupt
    /// crop).
    static func encodePNG(_ image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}
