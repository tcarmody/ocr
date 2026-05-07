import Foundation
import CoreGraphics
import Document
import OCR

/// Groups Vision per-line text observations into paragraphs.
///
/// Vision returns one observation per visual line, each with a normalized
/// bounding box (origin bottom-left, [0,1]). The walking-skeleton pipeline
/// emitted one `<p>` per observation, which made the EPUB read like a
/// poem. This pass uses geometry to recover paragraphs:
///
///   * Sort observations into reading order: top-to-bottom, then
///     left-to-right within each visual line.
///   * Detect a paragraph break before a line if any of:
///       - the vertical gap from the previous baseline is greater than
///         `paragraphGapMultiplier × medianLineHeight`
///       - the line's left edge is indented vs the body left margin
///         (first-line-indent style)
///       - the previous line ended with a sentence terminator AND
///         this line starts with a capital letter AND the gap exceeds
///         `softParagraphGapMultiplier × medianLineHeight`
///   * Within a paragraph, join lines with a space, dehyphenating soft
///     hyphens (see `Dehyphenation`).
///
/// Single-column assumption. Multi-column reading order is Phase 4.
struct ParagraphReflow {
    var paragraphGapMultiplier: CGFloat = 1.6
    var softParagraphGapMultiplier: CGFloat = 1.15
    var indentThreshold: CGFloat = 0.015  // fraction of page width

    /// Reflow a single page's observations into paragraph blocks.
    /// Detects column layout first, then reflows each column in
    /// left-to-right order. Empty input → empty output.
    func reflow(_ observations: [TextObservation]) -> [Block] {
        reflowWithBoxes(observations).map(\.block)
    }

    /// Same as `reflow` but also returns each paragraph's bounding
    /// box in normalized page coordinates (Vision/Surya convention:
    /// origin bottom-left, [0, 1]). Used by the paragraph-map
    /// sidecar (`ParagraphMap`) so the editor can re-OCR and align
    /// at paragraph granularity. Bbox is the union of every
    /// observation that contributed to the paragraph.
    func reflowWithBoxes(
        _ observations: [TextObservation]
    ) -> [(block: Block, bbox: CGRect)] {
        guard !observations.isEmpty else { return [] }
        let columns = ColumnSplitter().split(observations)
        return columns.flatMap { reflowColumnWithBoxes($0) }
    }

    /// Reflow a single column's worth of observations.
    private func reflowColumn(_ observations: [TextObservation]) -> [Block] {
        guard !observations.isEmpty else { return [] }
        let lines = sortedReadingOrder(observations)

        // Establish line metrics from the data we have.
        let lineHeights = lines.map(\.box.height)
        let medianLineHeight = median(lineHeights)
        // Body left margin: minimum left edge across lines (excluding clear outliers).
        let leftEdges = lines.map(\.box.minX).sorted()
        let bodyLeft = quantile(leftEdges, 0.10)  // 10th percentile, robust to indent outliers

        // Walk the lines, accumulating paragraphs.
        var paragraphs: [[TextObservation]] = []
        var current: [TextObservation] = []
        var previousBaselineY: CGFloat? = nil
        var previousText: String? = nil

        for line in lines {
            let baselineY = line.box.minY
            var startsNewParagraph = false

            if let prevY = previousBaselineY {
                let gap = prevY - line.box.maxY  // positive when this line is below the previous
                if gap > paragraphGapMultiplier * medianLineHeight {
                    startsNewParagraph = true
                } else if line.box.minX > bodyLeft + indentThreshold,
                          gap > 0 {
                    startsNewParagraph = true
                } else if let prev = previousText,
                          endsWithSentenceTerminator(prev),
                          line.text.first?.isUppercase == true,
                          gap > softParagraphGapMultiplier * medianLineHeight {
                    startsNewParagraph = true
                } else if Self.startsWithListMarker(line.text) {
                    // "1. ", "12) " etc. are paragraph starters even at
                    // normal line spacing — books rarely insert blank
                    // lines between numbered list items.
                    startsNewParagraph = true
                }
            }

            if startsNewParagraph, !current.isEmpty {
                paragraphs.append(current)
                current = []
            }
            current.append(line)
            previousBaselineY = baselineY
            previousText = line.text
        }
        if !current.isEmpty { paragraphs.append(current) }

        return paragraphs.map { lines in
            .paragraph(runs: [InlineRun(joinLines(lines))])
        }
    }

    /// Same as `reflowColumn` but emits `(Block, bbox)` per
    /// paragraph. Bbox is the union of all observations that
    /// landed in that paragraph.
    private func reflowColumnWithBoxes(
        _ observations: [TextObservation]
    ) -> [(block: Block, bbox: CGRect)] {
        guard !observations.isEmpty else { return [] }
        let lines = sortedReadingOrder(observations)
        let lineHeights = lines.map(\.box.height)
        let medianLineHeight = median(lineHeights)
        let leftEdges = lines.map(\.box.minX).sorted()
        let bodyLeft = quantile(leftEdges, 0.10)

        var paragraphs: [[TextObservation]] = []
        var current: [TextObservation] = []
        var previousBaselineY: CGFloat? = nil
        var previousText: String? = nil

        for line in lines {
            let baselineY = line.box.minY
            var startsNewParagraph = false
            if let prevY = previousBaselineY {
                let gap = prevY - line.box.maxY
                if gap > paragraphGapMultiplier * medianLineHeight {
                    startsNewParagraph = true
                } else if line.box.minX > bodyLeft + indentThreshold,
                          gap > 0 {
                    startsNewParagraph = true
                } else if let prev = previousText,
                          endsWithSentenceTerminator(prev),
                          line.text.first?.isUppercase == true,
                          gap > softParagraphGapMultiplier * medianLineHeight {
                    startsNewParagraph = true
                } else if Self.startsWithListMarker(line.text) {
                    startsNewParagraph = true
                }
            }
            if startsNewParagraph, !current.isEmpty {
                paragraphs.append(current)
                current = []
            }
            current.append(line)
            previousBaselineY = baselineY
            previousText = line.text
        }
        if !current.isEmpty { paragraphs.append(current) }

        return paragraphs.map { obs in
            let block = Block.paragraph(runs: [InlineRun(joinLines(obs))])
            let union = obs.dropFirst().reduce(obs[0].box) { $0.union($1.box) }
            return (block, union)
        }
    }

    // MARK: - line ordering

    /// Sort observations top-to-bottom, then left-to-right within each
    /// visual line. We treat boxes whose y midpoints are within half a
    /// median line-height as belonging to the same visual line.
    private func sortedReadingOrder(_ observations: [TextObservation]) -> [TextObservation] {
        // First pass: group by visual line.
        let medianH = median(observations.map(\.box.height))
        let groupTolerance = max(medianH * 0.5, 0.005)

        // Sort by y descending (top first in Vision coordinates).
        let byY = observations.sorted { a, b in
            // Vision: higher y = closer to top. Use midY for stability.
            let amid = a.box.midY, bmid = b.box.midY
            return amid > bmid
        }

        var groups: [[TextObservation]] = []
        for obs in byY {
            if var last = groups.last,
               let ref = last.first,
               abs(ref.box.midY - obs.box.midY) <= groupTolerance {
                last.append(obs)
                groups[groups.count - 1] = last
            } else {
                groups.append([obs])
            }
        }

        // Within each visual line, sort left to right.
        return groups.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    // MARK: - text join

    private func joinLines(_ lines: [TextObservation]) -> String {
        guard let first = lines.first else { return "" }
        var acc = first.text.trimmingCharacters(in: .whitespaces)
        for next in lines.dropFirst() {
            acc = Dehyphenation.join(acc, next.text)
        }
        return acc
    }

    // MARK: - text predicates

    /// True if `s` starts with a numbered-list marker like "1. ", "12) ",
    /// "3. Foo". Tolerates leading whitespace.
    static func startsWithListMarker(_ s: String) -> Bool {
        let trimmed = s.drop { $0.isWhitespace }
        var i = trimmed.startIndex
        var sawDigit = false
        while i < trimmed.endIndex, trimmed[i].isNumber {
            sawDigit = true
            i = trimmed.index(after: i)
        }
        guard sawDigit, i < trimmed.endIndex else { return false }
        let punct = trimmed[i]
        guard punct == "." || punct == ")" else { return false }
        let after = trimmed.index(after: i)
        guard after < trimmed.endIndex else { return false }
        return trimmed[after].isWhitespace
    }

    private func endsWithSentenceTerminator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let last = t.unicodeScalars.last else { return false }
        // ASCII period/?/! plus common Unicode equivalents.
        return ".?!\u{2026}".unicodeScalars.contains(last)
    }

    // MARK: - stats helpers

    private func median(_ xs: [CGFloat]) -> CGFloat {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    private func quantile(_ sorted: [CGFloat], _ q: Double) -> CGFloat {
        guard !sorted.isEmpty else { return 0 }
        let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * q)))
        return sorted[idx]
    }
}
