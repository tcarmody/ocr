import Foundation
import CoreGraphics
import Layout

/// Pair `.picture` (and `.formula`) regions with their nearest
/// `.caption` regions on the same page.
///
/// Why book-wide orientation detection:
///   Surya emits `.caption` regions independently of `.picture`. On
///   any single page, a caption could sit above the figure (older
///   typography, art books that label first) or below it (modern
///   convention, scientific publishing). Picking direction per page
///   independently misclassifies in either context. We let the first
///   handful of figures vote on the book's orientation and apply the
///   majority decision book-wide — a single typographic convention
///   per book is the overwhelming norm.
public enum CaptionAssociator {

    /// Where captions sit relative to their figure across this book.
    public enum Orientation: String, Sendable, Equatable {
        case above
        case below
    }

    /// Identifies a region within a multi-page document.
    public struct PageRegionKey: Sendable, Hashable {
        public let pageIndex: Int
        public let regionIndex: Int

        public init(pageIndex: Int, regionIndex: Int) {
            self.pageIndex = pageIndex
            self.regionIndex = regionIndex
        }
    }

    /// Output of `associate`: for each picture/formula region, the
    /// matching caption region (if any), plus the orientation that
    /// was chosen across the book.
    public struct Associations: Sendable, Equatable {
        public let captionByFigure: [PageRegionKey: PageRegionKey]
        public let orientation: Orientation

        public init(
            captionByFigure: [PageRegionKey: PageRegionKey],
            orientation: Orientation
        ) {
            self.captionByFigure = captionByFigure
            self.orientation = orientation
        }
    }

    /// Number of figures we'll vote with before locking orientation.
    /// Five is enough to overwhelm any single noisy pair while still
    /// firing on books with relatively few figures.
    private static let orientationSampleSize = 5

    /// Default orientation when a book has zero figures (no associations
    /// returned anyway) or when sample votes tie. `.below` matches the
    /// modern Western convention.
    private static let defaultOrientation: Orientation = .below

    /// Horizontal-overlap fraction below which a (picture, caption)
    /// pair is rejected outright. A caption that sits in a different
    /// column shouldn't be paired with this column's figure even if
    /// it happens to be vertically nearest.
    private static let minHorizontalOverlap: CGFloat = 0.20

    /// Pair every `.picture` and `.formula` across the book with the
    /// closest `.caption` in the book's dominant orientation. Returns
    /// associations and the chosen orientation.
    public static func associate(
        regionsByPage: [Int: [LayoutRegion]]
    ) -> Associations {
        // Pass 1: collect per-figure best candidates from each side.
        // Skip figures with no caption on the page entirely.
        let perFigure = regionsByPage.flatMap { (pageIndex, regions) -> [FigureCandidates] in
            collectCandidates(pageIndex: pageIndex, regions: regions)
        }

        guard !perFigure.isEmpty else {
            return Associations(captionByFigure: [:], orientation: defaultOrientation)
        }

        // Pass 2: vote orientation from the first N figures that had
        // candidates on both sides (or only one side — the side that
        // exists wins that vote). Figures with neither side don't vote.
        var votesAbove = 0
        var votesBelow = 0
        for c in perFigure.prefix(orientationSampleSize) {
            switch (c.bestAbove, c.bestBelow) {
            case (.some(let a), .some(let b)):
                if a.distance <= b.distance { votesAbove += 1 } else { votesBelow += 1 }
            case (.some, .none): votesAbove += 1
            case (.none, .some): votesBelow += 1
            case (.none, .none): break
            }
        }
        let orientation: Orientation = {
            if votesAbove > votesBelow { return .above }
            if votesBelow > votesAbove { return .below }
            return defaultOrientation
        }()

        // Pass 3: emit associations using the chosen orientation.
        // Fall back to the other side only when the chosen side has
        // no candidate — better a likely-wrong caption than dropping
        // text from the EPUB entirely.
        var captionByFigure: [PageRegionKey: PageRegionKey] = [:]
        for c in perFigure {
            let primary = orientation == .above ? c.bestAbove : c.bestBelow
            let fallback = orientation == .above ? c.bestBelow : c.bestAbove
            let chosen = primary ?? fallback
            if let chosen {
                captionByFigure[c.figure] = chosen.caption
            }
        }
        return Associations(
            captionByFigure: captionByFigure,
            orientation: orientation
        )
    }

    // MARK: - candidates

    private struct CaptionCandidate: Sendable {
        let caption: PageRegionKey
        let distance: CGFloat
    }

    private struct FigureCandidates: Sendable {
        let figure: PageRegionKey
        let bestAbove: CaptionCandidate?
        let bestBelow: CaptionCandidate?
    }

    private static func collectCandidates(
        pageIndex: Int, regions: [LayoutRegion]
    ) -> [FigureCandidates] {
        let figures = regions.enumerated().filter { (_, r) in
            r.kind == .picture || r.kind == .formula
        }
        guard !figures.isEmpty else { return [] }
        let captions = regions.enumerated().filter { (_, r) in r.kind == .caption }
        guard !captions.isEmpty else {
            // Still emit per-figure entries with nil candidates so the
            // counter and ordering match the figure list. They simply
            // don't get an association.
            return figures.map { (idx, _) in
                FigureCandidates(
                    figure: PageRegionKey(pageIndex: pageIndex, regionIndex: idx),
                    bestAbove: nil,
                    bestBelow: nil
                )
            }
        }

        return figures.map { (figIdx, figure) in
            var bestAbove: CaptionCandidate?
            var bestBelow: CaptionCandidate?
            for (capIdx, caption) in captions {
                guard horizontalOverlapFraction(figure.box, caption.box) >= minHorizontalOverlap else {
                    continue
                }
                let key = PageRegionKey(pageIndex: pageIndex, regionIndex: capIdx)
                // y=0 is bottom, y=1 is top in our coordinate system.
                if caption.box.minY >= figure.box.maxY {
                    let dist = caption.box.minY - figure.box.maxY
                    if bestAbove == nil || dist < bestAbove!.distance {
                        bestAbove = CaptionCandidate(caption: key, distance: dist)
                    }
                } else if caption.box.maxY <= figure.box.minY {
                    let dist = figure.box.minY - caption.box.maxY
                    if bestBelow == nil || dist < bestBelow!.distance {
                        bestBelow = CaptionCandidate(caption: key, distance: dist)
                    }
                }
                // Captions overlapping the figure vertically are
                // ignored — that's a layout we don't expect, and
                // pairing one risks treating a body region poking
                // into the figure's bbox as its caption.
            }
            return FigureCandidates(
                figure: PageRegionKey(pageIndex: pageIndex, regionIndex: figIdx),
                bestAbove: bestAbove,
                bestBelow: bestBelow
            )
        }
    }

    /// Fraction of `a`'s horizontal extent that overlaps `b`'s. Returns
    /// 0 when `a` has zero width or there is no overlap.
    private static func horizontalOverlapFraction(_ a: CGRect, _ b: CGRect) -> CGFloat {
        guard a.width > 0 else { return 0 }
        let overlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        return overlap / a.width
    }
}
