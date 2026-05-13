import Foundation
import Document
import PDFIngest  // OutlineEntry

/// Chapter splitter that runs first in the dispatch chain when the
/// source PDF carries an outline (publisher-set bookmarks). The
/// outline is authoritative — each entry has a real PDF page index,
/// so we skip every heuristic in the other splitters (offset
/// learning, title-matching against OCR'd headings) and just map
/// outline → block index → boundary.
///
/// Why this exists: ~73% of professionally-published PDFs carry an
/// outline. For those, the bookmark page numbers are exactly right
/// — much more reliable than parsed-TOC offset learning (ambiguous
/// when page anchors are dense) or OCR-heading title-matching
/// (fails when the OCR loses a chapter title).
///
/// Falls back to `TOCDrivenSplitter` (or the heuristic
/// `ChapterSplitter` further down) when:
///   * No outline present (scanned PDFs without bookmark metadata).
///   * Outline has < 2 entries (too sparse to drive splits).
///   * No page anchors to map outline pages to block indices.
public enum PDFOutlineSplitter {

    /// Result + diagnostics, same shape as the other splitters so
    /// the pipeline's debug log can render uniformly.
    public struct Result: Sendable, Equatable {
        public var chapters: [Chapter]
        public var diagnostics: Diagnostics
        public init(chapters: [Chapter], diagnostics: Diagnostics) {
            self.chapters = chapters
            self.diagnostics = diagnostics
        }
    }

    public struct Diagnostics: Sendable, Equatable {
        /// Total outline entries fed in.
        public var entriesSeen: Int
        /// Entries that resolved to a block index — chapter boundaries.
        public var resolvedEntries: Int
        /// Entries we couldn't resolve (no nearby page anchor; rare).
        public var unresolvedEntries: Int

        public init(
            entriesSeen: Int = 0,
            resolvedEntries: Int = 0,
            unresolvedEntries: Int = 0
        ) {
            self.entriesSeen = entriesSeen
            self.resolvedEntries = resolvedEntries
            self.unresolvedEntries = unresolvedEntries
        }
    }

    /// Title for the pre-first-boundary segment when it carries
    /// substantive content. Matches `TOCDrivenSplitter` / `ChapterSplitter`
    /// conventions.
    public static let frontMatterTitle = "Front Matter"

    /// Minimum outline entries to attempt a split. Below this we
    /// return nil and the caller falls through — a 1-entry outline
    /// is just "the book" and produces a single-chapter EPUB no
    /// better than the degenerate fallback.
    public static let minEntries = 2

    /// Run the split. Returns nil when the outline is too sparse,
    /// page anchors are missing, or no entries map to a block.
    public static func split(
        blocks: [Block],
        footnotes: [Footnote],
        pageAnchors: [PageAnchor],
        figureAssets: [FigureAsset],
        outline: [OutlineEntry]
    ) -> Result? {
        var diag = Diagnostics(entriesSeen: outline.count)
        guard outline.count >= minEntries else { return nil }

        // Use the existing page-anchor → block-index map; the
        // outline entries' pdfPage values get the same lookup
        // treatment as page-offset-derived inferred pages.
        let pdfPageToBlockIndex = TOCDrivenSplitter.indexAnchorsByPDFPage(
            blocks: blocks, pageAnchors: pageAnchors
        )
        guard !pdfPageToBlockIndex.isEmpty else { return nil }
        let sortedAnchorPDFs = pdfPageToBlockIndex.keys.sorted()

        // Resolve each outline entry to a block index. Fuzzy ±2-page
        // window catches the case where a layout glitch dropped the
        // page anchor for the exact target page.
        var boundaries: [(blockIdx: Int, title: String)] = []
        for entry in outline {
            guard let blockIdx = TOCDrivenSplitter.nearestBlockIndex(
                forPDFPage: entry.pdfPage,
                pageMap: pdfPageToBlockIndex,
                sortedAnchorPDFs: sortedAnchorPDFs,
                tolerance: 2
            ) else { continue }
            boundaries.append((blockIdx, entry.title))
        }
        diag.resolvedEntries = boundaries.count
        diag.unresolvedEntries = outline.count - boundaries.count
        guard !boundaries.isEmpty else { return nil }

        // Dedupe block indices (two outline entries on the same
        // page → one boundary, first title wins) + sort by block
        // index ascending. Outline entries are typically already
        // in page order, but defensive sort guards against weird
        // bookmark trees.
        var seen = Set<Int>()
        let unique = boundaries.filter { seen.insert($0.blockIdx).inserted }
        let sorted = unique.sorted { $0.blockIdx < $1.blockIdx }

        let chapters = TOCDrivenSplitter.assembleChapters(
            blocks: blocks,
            boundaries: sorted,
            footnotes: footnotes,
            pageAnchors: pageAnchors,
            figureAssets: figureAssets
        )
        guard !chapters.isEmpty else { return nil }

        return Result(chapters: chapters, diagnostics: diag)
    }
}
