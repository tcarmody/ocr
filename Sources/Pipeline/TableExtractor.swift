import Foundation
import CoreGraphics
import Document
import Layout
import OCR

/// Common shape for any backend that turns a `.table` region into a
/// 2D `[[TableCell]]` grid. Two implementations today:
///
/// * `SuryaTableExtractor` — Path A (offline): the Python sidecar's
///   `surya-table` model returns row/column cell structure for the
///   cropped region, and we map this page's existing OCR observations
///   onto each cell's bbox.
/// * `ClaudeTableExtractor` — Cloud Phase 5 (online): Sonnet 4.6
///   reads the cropped region image and returns a structured JSON
///   grid directly. The cell text is the model's transcription; OCR
///   observations aren't consulted.
///
/// Both return `nil` on degenerate output (sub-2×2 grid, network or
/// sidecar failure, model refusal). The pipeline dispatches based on
/// `Options.processingMode` and falls back to `TableHeuristic` when
/// every wired extractor returns nil for a given region.
public protocol TableExtractor: Sendable {
    /// Extract a 2D grid for the `.table` region described by
    /// `regionBox` (full-page normalized coords) on the rendered
    /// `pageImage`. `observations` are the page's OCR observations —
    /// some backends (Surya path) need them to fill cell text;
    /// others (Claude path) ignore them and read the image directly.
    /// `stagingDir` is for any temporary files the backend needs;
    /// caller owns its lifecycle.
    func extract(
        pageImage: CGImage,
        regionBox: CGRect,
        observations: [TextObservation],
        stagingDir: URL,
        pageIndex: Int,
        regionIndex: Int
    ) async -> [[TableCell]]?
}

