import Foundation
import CoreGraphics
import OCR
import PDFIngest

/// Compare-don't-replace merge of Vision OCR observations and the PDF's
/// embedded text layer.
///
/// Strategy: trust Vision wherever it produced an observation; fall back
/// to the embedded text layer only for lines Vision missed entirely.
/// "Missed" is detected by vertical-overlap: if no Vision observation
/// covers the y-range of an embedded line, the line is added as a
/// synthetic observation tagged `source: .embedded`.
///
/// We deliberately do NOT do fuzzy text matching — Vision's text
/// content is treated as authoritative inside its observation regions.
/// This keeps Vision's OCR quality (which the user has confirmed beats
/// the embedded layer on this corpus) intact, while recovering the
/// occasional line Vision drops on the floor.
struct EmbeddedTextGapFiller {
    /// Two boxes "vertically overlap" if the overlapping height is at
    /// least this fraction of the smaller box's height. 0.5 = they
    /// share at least half a line vertically.
    var verticalOverlapThreshold: CGFloat = 0.5

    func fill(
        visionObservations: [TextObservation],
        embeddedLines: [EmbeddedTextExtractor.Line]
    ) -> [TextObservation] {
        guard !embeddedLines.isEmpty else { return visionObservations }

        var merged = visionObservations
        for line in embeddedLines {
            if Self.isCovered(embedBox: line.box, by: visionObservations,
                              threshold: verticalOverlapThreshold) {
                continue
            }
            merged.append(TextObservation(
                text: line.text,
                confidence: 0.5,  // synthetic — neither Vision-confident nor obviously wrong
                box: line.box,
                source: .embedded
            ))
        }
        return merged
    }

    /// True if any Vision observation vertically overlaps the embedded
    /// line by at least `threshold × min-line-height`. Pure y-axis
    /// check — the embedded line might be wider/narrower or shifted
    /// horizontally and still be covered (e.g., Vision returned the
    /// line in two pieces or one piece spanning a wider region).
    static func isCovered(
        embedBox: CGRect,
        by visionObs: [TextObservation],
        threshold: CGFloat
    ) -> Bool {
        for obs in visionObs {
            let overlap = min(embedBox.maxY, obs.box.maxY) - max(embedBox.minY, obs.box.minY)
            let minH = min(embedBox.height, obs.box.height)
            guard minH > 0 else { continue }
            if overlap >= threshold * minH { return true }
        }
        return false
    }
}
