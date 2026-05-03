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

    /// Returns `[observations]` (single group) when no columns detected,
    /// or `[leftColumn, rightColumn]` when a 2-column layout is found.
    func split(_ observations: [TextObservation]) -> [[TextObservation]] {
        guard observations.count >= 8 else { return [observations] }

        // Build a per-x-bin coverage histogram: how many observation
        // bounding boxes overlap each bin.
        var coverage = [Int](repeating: 0, count: bins)
        for obs in observations {
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
        let left  = observations.filter { $0.box.midX <  gutterX }
        let right = observations.filter { $0.box.midX >= gutterX }

        // Both columns need real content.
        guard left.count >= minObservationsPerColumn,
              right.count >= minObservationsPerColumn else {
            return [observations]
        }

        // Both columns need to span most of the page's text extent —
        // otherwise we're probably looking at a figure or pull-quote
        // creating a fake gutter, not a real two-column layout.
        let allMin = observations.map(\.box.minY).min() ?? 0
        let allMax = observations.map(\.box.maxY).max() ?? 1
        let totalH = max(allMax - allMin, 0.0001)

        let leftSpan  = (left.map(\.box.maxY).max() ?? 0)  - (left.map(\.box.minY).min() ?? 0)
        let rightSpan = (right.map(\.box.maxY).max() ?? 0) - (right.map(\.box.minY).min() ?? 0)

        guard leftSpan / totalH >= minColumnVerticalSpan,
              rightSpan / totalH >= minColumnVerticalSpan else {
            return [observations]
        }

        return [left, right]
    }
}
