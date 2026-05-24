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
    /// P-Diagram-Description Tier 2/3. Per-figure machine-
    /// readable metadata (alt text, longer description, label
    /// list) keyed by `FigureAsset.id`. Populated by the Cloud
    /// diagram extractor when enabled; empty otherwise. The
    /// XHTML writer emits the description + labels as a hidden
    /// `<aside>` next to each figure so the existing paragraph-
    /// based chat / search indexer picks them up without
    /// changing what readers see.
    public var figureMetadata: [String: FigureMetadata]
    /// EPUB 3 Structural Semantics Vocabulary token for this chapter
    /// — `chapter`, `preface`, `appendix`, `bibliography`, etc.
    /// Emitted as `<body epub:type="...">` and on the corresponding
    /// nav.xhtml entry so EPUB readers can navigate semantically
    /// (skip front matter, jump to bibliography). Nil when no
    /// classification was assigned (Cloud Phase 6d disabled, or
    /// the classifier returned nothing).
    public var epubType: String?

    public init(title: String? = nil,
                blocks: [Block] = [],
                footnotes: [Footnote] = [],
                pageAnchors: [PageAnchor] = [],
                figureAssets: [FigureAsset] = [],
                figureMetadata: [String: FigureMetadata] = [:],
                epubType: String? = nil) {
        self.title = title
        self.blocks = blocks
        self.footnotes = footnotes
        self.pageAnchors = pageAnchors
        self.figureAssets = figureAssets
        self.figureMetadata = figureMetadata
        self.epubType = epubType
    }
}
