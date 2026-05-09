import Foundation
import CoreGraphics
import OCR

/// Detect a multi-column layout by finding a vertical "gutter" — a band
/// of x-coordinates that no observation crosses — and split observations
/// into per-column groups in left-to-right reading order.
///
/// Returns a single group when no clear gutter is found, so callers
/// always treat the result as `[column0, column1, ...]`.
///
/// **Spanning observations** (a banner heading, subtitle, or epigraph
/// that crosses both columns at the top of a 2-column page) are
/// detected by width and excluded from gutter scanning — otherwise a
/// single full-width title bin lights up the whole gutter band and
/// detection fails. Spans above the column body are emitted before the
/// columns; spans below are emitted after. Spans interleaved with
/// column body (rare) collapse to the spans-above bucket — this is a
/// known limitation of the heuristic path; the layout-aware reflow
/// handles section breaks via separate Surya regions.
///
/// Heuristic, not a layout model. Handles the dominant case (two-column
/// prose). Three+ columns degrade gracefully to two; pages with figures
/// that create false gutters are guarded against by requiring both
/// candidate columns to span most of the page's vertical text extent.
struct ColumnSplitter {
    /// Minimum width of an empty vertical band to qualify as a gutter,
    /// as a fraction of page width.
    var minGutterFraction: CGFloat = 0.04
    /// Skip the leftmost / rightmost N% when scanning for a gutter — the
    /// page margins always look "empty."
    var marginFraction: CGFloat = 0.15
    /// Each side must contain at least this many observations to count
    /// as a column.
    var minObservationsPerColumn: Int = 3
    /// Each side must vertically span at least this fraction of the
    /// combined text extent. Guards against figures or tables creating
    /// a fake gutter that splits a single-column page in half.
    var minColumnVerticalSpan: CGFloat = 0.4
    /// Number of x-bins to scan. 200 → ~0.5% resolution.
    var bins: Int = 200
    /// Observations whose bounding box is wider than this fraction of
    /// the page (in normalized coords) are treated as **spanning** —
    /// they're excluded from gutter detection and from the per-column
    /// partition, then re-emitted as their own group above (or below)
    /// the columns. A single column line in a 2-column book is at
    /// most ~0.45 of page width, so 0.6 is a comfortable margin that
    /// captures spanning headers/epigraphs without false-flagging
    /// regular body lines.
    var spanWidthFraction: CGFloat = 0.6

    /// Returns groups in reading order. Possible shapes:
    ///   * `[observations]`          — no gutter detected.
    ///   * `[left, right]`           — 2 columns, no spanning content.
    ///   * `[spans, left, right]`    — 2 columns with spanning content
    ///                                  above the columns (or
    ///                                  interleaved — see class docs).
    ///   * `[left, right, spans]`    — 2 columns with spanning content
    ///                                  below the columns.
    ///   * `[above, left, right, below]` — both above- and below-spans.
    func split(_ observations: [TextObservation]) -> [[TextObservation]] {
        guard observations.count >= 8 else { return [observations] }

        // Partition observations into spanning vs column candidates.
        // Gutter detection only sees the column candidates — a single
        // banner heading would otherwise paint coverage across the
        // entire page width and obscure the gutter.
        let spans = observations.filter { $0.box.width >= spanWidthFraction }
        let candidates = observations.filter { $0.box.width < spanWidthFraction }

        // Need enough non-span observations to find a gutter at all.
        guard candidates.count >= 8 else { return [observations] }

        // Build a per-x-bin coverage histogram from the column
        // candidates only.
        var coverage = [Int](repeating: 0, count: bins)
        for obs in candidates {
            let startBin = max(0, min(bins - 1, Int(obs.box.minX * CGFloat(bins))))
            let endBin   = max(0, min(bins - 1, Int(obs.box.maxX * CGFloat(bins))))
            if startBin <= endBin {
                for b in startBin...endBin { coverage[b] += 1 }
            }
        }

        // Scan only the central region for a gutter; margins are noise.
        let leftEdge = max(0, Int(CGFloat(bins) * marginFraction))
        let rightEdge = min(bins, Int(CGFloat(bins) * (1 - marginFraction)))

        var bestStart = 0
        var bestLength = 0
        var runStart = leftEdge
        var runLength = 0
        for b in leftEdge..<rightEdge {
            if coverage[b] == 0 {
                if runLength == 0 { runStart = b }
                runLength += 1
                if runLength > bestLength {
                    bestLength = runLength
                    bestStart = runStart
                }
            } else {
                runLength = 0
            }
        }

        let gutterWidthFraction = CGFloat(bestLength) / CGFloat(bins)
        guard gutterWidthFraction >= minGutterFraction else {
            return [observations]
        }

        let gutterX = (CGFloat(bestStart) + CGFloat(bestLength) / 2) / CGFloat(bins)
        let left  = candidates.filter { $0.box.midX <  gutterX }
        let right = candidates.filter { $0.box.midX >= gutterX }

        // Both columns need real content.
        guard left.count >= minObservationsPerColumn,
              right.count >= minObservationsPerColumn else {
            return [observations]
        }

        // Both columns need to span most of the page's text extent —
        // otherwise we're probably looking at a figure or pull-quote
        // creating a fake gutter, not a real two-column layout. Use
        // candidates' Y range here, not all observations' — including
        // spans would make the column span fraction look smaller than
        // it actually is for the body.
        let allMin = candidates.map(\.box.minY).min() ?? 0
        let allMax = candidates.map(\.box.maxY).max() ?? 1
        let totalH = max(allMax - allMin, 0.0001)

        let leftSpan  = (left.map(\.box.maxY).max() ?? 0)  - (left.map(\.box.minY).min() ?? 0)
        let rightSpan = (right.map(\.box.maxY).max() ?? 0) - (right.map(\.box.minY).min() ?? 0)

        guard leftSpan / totalH >= minColumnVerticalSpan,
              rightSpan / totalH >= minColumnVerticalSpan else {
            return [observations]
        }

        // Partition spans by Y position relative to the column body's
        // vertical extent. "Above" = midY higher than the column body's
        // top (Vision normalized coords have Y=1 at top). "Below" =
        // midY lower than the column body's bottom. Anything inside
        // the column body's Y range collapses to "above" — see class
        // docs.
        guard !spans.isEmpty else { return [left, right] }
        // Only the bottom edge matters for the above/below split: anything
        // above the column or inside its Y range collapses to "above"
        // (see the comment block above), so columnTopY isn't needed.
        let columnBottomY = candidates.map(\.box.minY).min() ?? 0
        var above: [TextObservation] = []
        var below: [TextObservation] = []
        for s in spans {
            if s.box.midY < columnBottomY {
                below.append(s)
            } else {
                // Above OR within column Y range — collapse to above
                // so middle spans don't get emitted after the columns.
                above.append(s)
            }
        }
        // Sort spans top-to-bottom within their group so banner-stack
        // ordering (title → subtitle → epigraph) is preserved.
        above.sort { $0.box.midY > $1.box.midY }
        below.sort { $0.box.midY > $1.box.midY }

        var groups: [[TextObservation]] = []
        if !above.isEmpty { groups.append(above) }
        groups.append(left)
        groups.append(right)
        if !below.isEmpty { groups.append(below) }
        return groups
    }
}
