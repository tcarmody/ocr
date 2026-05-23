import Foundation
import CoreGraphics
import Document
import Layout
import OCR

/// Heuristic table extractor — cluster a `.table` region's
/// observations into rows by Y position, then into cells by X
/// position within each row. The plan calls this **Path B**;
/// **Path A** (Surya's `surya-table` model integration) will
/// produce richer cell metadata (header flags, merged-cell spans,
/// rotated headers). Path A can later sit behind the same
/// `TableExtractor` protocol shape this type defines.
///
/// Quality target per the Phase 6 plan: 60-70% cell accuracy on a
/// first pass against scanned-book tables. Brittle on:
///   * merged cells (always emits as a single non-merged cell of
///     the leftmost column),
///   * rotated headers,
///   * tables whose body wraps within a cell across multiple lines
///     (treated as multiple rows; usually wrong),
///   * tables with empty cells (column count varies row-to-row).
///
/// Good enough for the common case of regular grids.
public enum TableHeuristic {

    /// Y tolerance, in units of median observation height, that
    /// considers two observations to be on the same row. 0.6 means
    /// observations whose midY differs by less than 60% of one line
    /// height land in the same row — typical baseline noise on a
    /// scan stays well under this; line-to-line gaps exceed it.
    private static let rowYTolerance: CGFloat = 0.6

    /// Minimum number of rows AND minimum columns the heuristic
    /// requires before emitting a `Block.table`. Anything below this
    /// is most likely a misclassified region — better to fall
    /// through to the regular paragraph path than emit a degenerate
    /// `<table>` with one cell.
    public static let minRows = 2
    public static let minCols = 2

    /// Run the heuristic on observations whose center sits inside
    /// `regionBox` (with `regionInflation` already applied by the
    /// caller). Returns nil when the result doesn't pass the
    /// rows × cols floor — caller should fall back to paragraph
    /// emission.
    public static func extract(
        observations: [TextObservation]
    ) -> [[TableCell]]? {
        // Reject trivially small sets up-front.
        guard observations.count >= minRows * minCols else { return nil }

        // Group observations into rows by midY. We sort top-to-bottom
        // first (highest Y first, since y=1 is the top of the page),
        // then walk in order and start a new row each time the Y
        // gap exceeds the tolerance.
        let sortedByY = observations.sorted { $0.box.midY > $1.box.midY }
        let medianHeight = medianHeight(sortedByY)
        guard medianHeight > 0 else { return nil }
        let yTolerance = medianHeight * rowYTolerance

        var rowObservations: [[TextObservation]] = []
        var currentRow: [TextObservation] = []
        var currentRowMidY: CGFloat = sortedByY.first!.box.midY
        for obs in sortedByY {
            if currentRow.isEmpty {
                currentRow.append(obs)
                currentRowMidY = obs.box.midY
                continue
            }
            if abs(obs.box.midY - currentRowMidY) <= yTolerance {
                currentRow.append(obs)
            } else {
                rowObservations.append(currentRow)
                currentRow = [obs]
                currentRowMidY = obs.box.midY
            }
        }
        if !currentRow.isEmpty { rowObservations.append(currentRow) }

        guard rowObservations.count >= minRows else { return nil }

        // Per row, sort observations left-to-right and emit each as
        // its own cell. This loses merged cells and treats wrapped
        // multi-line cells as separate rows — both are deferred
        // refinements per the plan's "60-70% accuracy" target.
        let rows: [[TableCell]] = rowObservations.map { row in
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            return sorted.map { obs in
                TableCell(runs: InlineMathSplitter.split([InlineRun(obs.text)]))
            }
        }
        let maxCols = rows.map(\.count).max() ?? 0
        guard maxCols >= minCols else { return nil }
        return rows
    }

    // MARK: - helpers

    private static func medianHeight(_ observations: [TextObservation]) -> CGFloat {
        let heights = observations.map(\.box.height).sorted()
        guard !heights.isEmpty else { return 0 }
        return heights[heights.count / 2]
    }
}
