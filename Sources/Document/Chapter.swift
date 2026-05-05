import Foundation

public struct Chapter: Sendable, Equatable {
    /// Display title for navigation. Optional for chapters that don't get one
    /// in the source (e.g. unstructured Phase-1 walking-skeleton output uses
    /// the source filename as the title).
    public var title: String?
    public var blocks: [Block]
    /// Footnotes referenced by `InlineRun.noterefId` inside `blocks`.
    /// Emitted as `<aside epub:type="footnote">` after the body — readers
    /// pop these up in response to noteref taps.
    public var footnotes: [Footnote]
    /// Page-boundary anchors emitted into `blocks` (as `Block.anchor`)
    /// during reflow. Mirrored here so the EPUB writer can collect a
    /// chapter-by-chapter pagemap without re-walking blocks.
    public var pageAnchors: [PageAnchor]
    /// Image assets referenced by `Block.figure(assetId:)` inside
    /// `blocks`. Bytes live here so blocks stay cheap to copy / log;
    /// the EPUB writer copies these into `OEBPS/images/`.
    public var figureAssets: [FigureAsset]

    public init(title: String? = nil,
                blocks: [Block] = [],
                footnotes: [Footnote] = [],
                pageAnchors: [PageAnchor] = [],
                figureAssets: [FigureAsset] = []) {
        self.title = title
        self.blocks = blocks
        self.footnotes = footnotes
        self.pageAnchors = pageAnchors
        self.figureAssets = figureAssets
    }
}
