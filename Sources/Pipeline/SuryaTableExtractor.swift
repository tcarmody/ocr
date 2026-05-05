import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Document
import Layout
import OCR

/// Path-A table extractor: crop the page raster to a `.table` region,
/// send the crop to Surya's `surya-table` model via the shared
/// sidecar connection, then map the OCR observations the pipeline
/// already has onto each cell. Returns a 2D grid of `TableCell`
/// values ready to embed in `Block.table`.
///
/// Why the heuristic still exists: this path requires the sidecar
/// (Surya installed + `table` op available). When the sidecar isn't
/// present, or fails on a particular table, the caller falls back
/// to `TableHeuristic` so the user still gets *some* tabular output.
public struct SuryaTableExtractor {
    public let connection: SuryaConnection

    public init(connection: SuryaConnection) {
        self.connection = connection
    }

    /// Crop `pageImage` to `regionBox`, run table-structure recognition,
    /// and assemble `[[TableCell]]` rows by mapping `observations`
    /// onto cell bboxes. `stagingDir` is used for the temporary PNG
    /// the sidecar reads — caller is responsible for the directory's
    /// lifecycle.
    ///
    /// Returns nil when:
    ///   * the crop fails (degenerate region),
    ///   * the sidecar returns zero cells,
    ///   * fewer than 2 rows or 2 columns total (same floor as the
    ///     heuristic — degenerate output isn't worth a `<table>`).
    public func extract(
        pageImage: CGImage,
        regionBox: CGRect,
        observations: [TextObservation],
        stagingDir: URL,
        pageIndex: Int,
        regionIndex: Int
    ) async -> [[TableCell]]? {
        guard let cropped = RegionCascade.cropImage(pageImage, to: regionBox) else {
            return nil
        }
        let pngURL = stagingDir.appendingPathComponent(
            "table-page\(pageIndex)-region\(regionIndex).png"
        )
        guard Self.savePNG(cropped, to: pngURL) else { return nil }
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let raw: SuryaConnection.RawTableStructure
        do {
            raw = try await connection.table(imageURL: pngURL)
        } catch {
            return nil
        }
        guard !raw.cells.isEmpty,
              raw.imageSize.width > 0, raw.imageSize.height > 0 else {
            return nil
        }

        // Translate each cell's pixel bbox (in cropped-image coords,
        // top-left origin) into full-page normalized coords
        // (bottom-left origin) so we can match against observations.
        let translated = raw.cells.map { cell -> TranslatedCell in
            let normalized = Self.translateCellBox(
                cell.bbox, cropImageSize: raw.imageSize, regionBox: regionBox
            )
            return TranslatedCell(raw: cell, fullPageBox: normalized)
        }

        // For each translated cell, gather observations whose center
        // is inside the cell's bbox. First-claimant wins so a single
        // observation can't end up in two cells whose bboxes touch.
        var claimed = Set<Int>()
        let cellTexts: [Int: String] = Dictionary(uniqueKeysWithValues:
            translated.enumerated().map { (idx, cell) -> (Int, String) in
                var contained: [TextObservation] = []
                for (oi, obs) in observations.enumerated() {
                    if claimed.contains(oi) { continue }
                    let cx = obs.box.midX
                    let cy = obs.box.midY
                    if cell.fullPageBox.contains(CGPoint(x: cx, y: cy)) {
                        contained.append(obs)
                        claimed.insert(oi)
                    }
                }
                let sorted = contained.sorted { a, b in
                    if abs(a.box.midY - b.box.midY) > 0.005 {
                        return a.box.midY > b.box.midY
                    }
                    return a.box.minX < b.box.minX
                }
                return (idx, sorted.map(\.text).joined(separator: " "))
            }
        )

        // Group translated cells by row_id, sort each group by
        // within_row_id, then sort rows by row_id ascending. This
        // produces a clean 2D grid even when cells came back out of
        // order from the model.
        let rowsByID = Dictionary(grouping: translated.enumerated(), by: { $0.element.raw.rowId })
        let sortedRowIds = rowsByID.keys.sorted()
        let rows: [[TableCell]] = sortedRowIds.map { rid in
            let rowCells = (rowsByID[rid] ?? [])
                .sorted { $0.element.raw.withinRowId < $1.element.raw.withinRowId }
            return rowCells.map { (idx, cell) -> TableCell in
                let text = cellTexts[idx] ?? ""
                return TableCell(
                    runs: text.isEmpty ? [] : [InlineRun(text)],
                    isHeader: cell.raw.isHeader,
                    rowspan: max(1, cell.raw.rowspan),
                    colspan: max(1, cell.raw.colspan)
                )
            }
        }

        let maxCols = rows.map(\.count).max() ?? 0
        guard rows.count >= TableHeuristic.minRows,
              maxCols >= TableHeuristic.minCols else {
            return nil
        }
        return rows
    }

    /// Translate a cell's pixel bbox (origin top-left in the cropped
    /// image) to full-page normalized coords (origin bottom-left).
    /// `regionBox` is the original `.table` region the crop was made
    /// from; cropping inflates by `RegionCascade.cropMargin`, so the
    /// crop's footprint in the page is `regionBox.insetBy(-margin)`.
    static func translateCellBox(
        _ pixelBox: CGRect, cropImageSize: CGSize, regionBox: CGRect
    ) -> CGRect {
        let margin = RegionCascade.cropMargin
        let inflated = regionBox.insetBy(dx: -margin, dy: -margin)
        let nx = max(0, min(1, inflated.minX))
        let ny = max(0, min(1, inflated.minY))
        let nMaxX = max(0, min(1, inflated.maxX))
        let nMaxY = max(0, min(1, inflated.maxY))
        let regionW = nMaxX - nx
        let regionH = nMaxY - ny
        guard cropImageSize.width > 0, cropImageSize.height > 0,
              regionW > 0, regionH > 0 else { return .zero }

        // x-axis: pixel space and normalized space share orientation
        // (left ≤ right), only the unit changes.
        let fracX1 = pixelBox.minX / cropImageSize.width
        let fracX2 = pixelBox.maxX / cropImageSize.width
        let fullMinX = nx + fracX1 * regionW
        let fullMaxX = nx + fracX2 * regionW

        // y-axis: pixel y grows downward, normalized y grows upward.
        // Flip via (1 - py / cropH).
        let fracY1 = pixelBox.minY / cropImageSize.height  // top edge in pixel
        let fracY2 = pixelBox.maxY / cropImageSize.height  // bottom edge in pixel
        let fullMaxY = ny + (1 - fracY1) * regionH         // top edge in normalized
        let fullMinY = ny + (1 - fracY2) * regionH         // bottom edge in normalized

        return CGRect(
            x: fullMinX, y: fullMinY,
            width: fullMaxX - fullMinX,
            height: fullMaxY - fullMinY
        )
    }

    private struct TranslatedCell {
        let raw: SuryaConnection.RawTableCell
        let fullPageBox: CGRect
    }

    private static func savePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
