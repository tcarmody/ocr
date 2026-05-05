import Foundation
import CoreGraphics

/// A figure / illustration extracted from the source document.
///
/// `Block.figure` references the asset by `id`; the bytes live here on
/// `Chapter.figureAssets` so a chapter can be serialized without
/// duplicating large image data inside the block stream. The EPUB
/// writer copies `data` into `OEBPS/images/<id>.<ext>` and registers
/// it in the OPF manifest with `mediaType`.
public struct FigureAsset: Sendable, Equatable {
    /// Stable, globally unique id (e.g. `fig-00042`). Used as both
    /// the manifest item id and the filename stem in `OEBPS/images/`.
    public let id: String
    /// Raw image bytes. PNG for raster crops; original-encoding bytes
    /// (PNG / JPEG) when the vector path could extract them losslessly.
    public let data: Data
    /// IANA media type matching `data` — `"image/png"` or `"image/jpeg"`.
    public let mediaType: String
    /// Pixel dimensions when known. Used for `<img width height>` in
    /// XHTML so reader pre-layout doesn't reflow once the image loads.
    public let intrinsicSize: CGSize?
    /// True for the page-0 dominant figure. The OPF writer stamps
    /// `properties="cover-image"` on this manifest item.
    public let isCover: Bool

    public init(
        id: String,
        data: Data,
        mediaType: String,
        intrinsicSize: CGSize? = nil,
        isCover: Bool = false
    ) {
        self.id = id
        self.data = data
        self.mediaType = mediaType
        self.intrinsicSize = intrinsicSize
        self.isCover = isCover
    }

    /// File extension (without the dot) inferred from `mediaType`.
    /// Falls back to `"png"` for unknown types.
    public var fileExtension: String {
        switch mediaType {
        case "image/jpeg": return "jpg"
        case "image/png":  return "png"
        default:           return "png"
        }
    }
}
