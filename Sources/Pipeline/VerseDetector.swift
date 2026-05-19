import Foundation
import Document
import OCR

/// P-Verse-Layout. High-precision verse classifier + line builder.
/// Given the `[TextObservation]` for a `.text` region (already
/// claimed by `RegionAwareReflow` and sorted top-to-bottom,
/// left-to-right), decides whether the region is poetry. When it
/// is, returns the `[VerseLine]` reconstruction with quantized
/// indent buckets so the XHTML renderer can preserve layout.
///
/// **High precision is the explicit goal**. False positives
/// (prose mis-classified as verse) would garble the reader's
/// experience on entire chapters of academic monographs. The
/// detector requires multiple independent signals to agree
/// before promoting a region to `.verse`. False negatives
/// (verse silently treated as prose) are the acceptable
/// failure mode — they look exactly like today's behavior.
///
/// Detection signals (all must pass, conjunctively):
///
/// 1. **Minimum line count**. Single-line and two-line regions
///    are almost always address blocks, captions, or
///    fragmentary heads. Require ≥ 4 lines.
/// 2. **Ragged-right ratio**. ≥ 70% of lines must end short of
///    the region's right edge by more than 15% of the region
///    width. Prose typically reaches the right margin (justified
///    or unjustified) on most lines.
/// 3. **First-token-x variance**. The standard deviation of
///    per-line leading-x positions, normalized to the region
///    width, must be ≥ 0.05. Prose only indents the first
///    line of a paragraph; verse indents irregularly throughout.
/// 4. **Mean line length below the region width**. The mean
///    line width must be ≤ 80% of the region width. Catches the
///    "even short verse lines fit narrow regions" case while
///    rejecting prose blocks whose lines normally fill the
///    column.
/// 5. **Low end-of-line punctuation rate**. Prose lines almost
///    always end mid-sentence with a terminal punctuation only
///    on the final line of a paragraph. Verse lines frequently
///    end with no punctuation at all (enjambed) or with a
///    non-terminal mark (comma, dash). Required: < 60% of
///    lines end with a terminal punctuation (period, exclamation,
///    question mark, ellipsis, colon, or semicolon).
public enum VerseDetector {

    // MARK: - Tunable thresholds

    /// Minimum lines in a region before verse is even considered.
    static let minLineCount: Int = 4
    /// Lines must end this fraction short of the region's right
    /// margin to count as "ragged."
    static let raggedShortageFraction: Double = 0.15
    /// Fraction of lines that must be ragged.
    static let raggedRightRatioThreshold: Double = 0.70
    /// Normalized stddev of leading-x positions; verse > this.
    static let indentVarianceThreshold: Double = 0.05
    /// Mean line width must be ≤ this fraction of region width.
    static let meanLineLengthCap: Double = 0.80
    /// Maximum fraction of lines ending with terminal punctuation
    /// before the region is considered prose.
    static let maxTerminalPunctRatio: Double = 0.60
    /// Number of indent buckets. Matches the CSS in
    /// `EPUBStaticFiles.bookCSS` (`.indent-1` through `.indent-8`).
    static let indentBucketCount: Int = 8

    // MARK: - Detection

    /// Decide whether a `.text` region is verse. Returns nil when
    /// it isn't (caller falls through to the existing prose path).
    /// Returns a populated `Verdict` with the verse-line
    /// reconstruction when it is — caller emits `Block.verse`.
    ///
    /// `regionBox` is the region's bounding box in normalized
    /// coordinates. The observations should already be filtered
    /// to this region (no need to re-clip) and sorted in reading
    /// order (top-to-bottom, then left-to-right within rows).
    public static func detect(
        observations: [TextObservation],
        regionBox: CGRect
    ) -> Verdict? {
        guard regionBox.width > 0, regionBox.height > 0 else { return nil }
        let lines = buildLines(from: observations)
        guard lines.count >= minLineCount else { return nil }

        // Compute features over the lines.
        let f = computeFeatures(lines: lines, regionBox: regionBox)

        // Conjunctive gate. All five signals must agree.
        guard f.lineCount >= minLineCount,
              f.raggedRightRatio >= raggedRightRatioThreshold,
              f.indentStddev >= indentVarianceThreshold,
              f.meanLineWidth <= meanLineLengthCap,
              f.terminalPunctRatio < maxTerminalPunctRatio
        else { return nil }

        // Build the VerseLine slice. Indent buckets quantize the
        // observed leading-x into 0…8.
        let verseLines = lines.map { line -> VerseLine in
            let leftOffset = line.minX - regionBox.minX
            let fraction = regionBox.width > 0
                ? leftOffset / regionBox.width
                : 0
            let bucket = quantizeIndent(fraction: fraction)
            return VerseLine(
                runs: makeRuns(for: line),
                indent: bucket
            )
        }
        return Verdict(lines: verseLines, features: f)
    }

    // MARK: - Line construction

    /// Group observations into visual lines by y-overlap.
    /// Observations whose y-centers fall within `lineHeight / 2`
    /// of the running line's mean y join that line; otherwise
    /// start a new one. Within a line, observations are sorted
    /// left-to-right.
    static func buildLines(
        from observations: [TextObservation]
    ) -> [Line] {
        let nonEmpty = observations.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        guard !nonEmpty.isEmpty else { return [] }
        // Sort top-to-bottom (Vision coords: y=1 at top, y=0 at
        // bottom — so larger midY = higher on page).
        let sorted = nonEmpty.sorted { $0.box.midY > $1.box.midY }
        var lines: [Line] = []
        for obs in sorted {
            let h = obs.box.height
            if let last = lines.last,
               abs(last.meanY - obs.box.midY) < max(h, 0.005) / 2 {
                lines[lines.count - 1].observations.append(obs)
            } else {
                lines.append(Line(observations: [obs]))
            }
        }
        // Sort each line left-to-right and compute aggregates.
        for i in lines.indices {
            lines[i].observations.sort { $0.box.minX < $1.box.minX }
            lines[i].recomputeAggregates()
        }
        return lines
    }

    // MARK: - Features

    static func computeFeatures(
        lines: [Line], regionBox: CGRect
    ) -> Features {
        let regionWidth = max(regionBox.width, 0.0001)
        let regionRight = regionBox.maxX
        let regionLeft = regionBox.minX

        // Ragged-right ratio.
        var raggedCount = 0
        for line in lines {
            let shortage = regionRight - line.maxX
            if shortage / regionWidth > raggedShortageFraction {
                raggedCount += 1
            }
        }
        let raggedRatio = Double(raggedCount) / Double(lines.count)

        // Leading-x stddev (normalized).
        let leadingFractions: [Double] = lines.map { line in
            Double((line.minX - regionLeft) / regionWidth)
        }
        let meanLead = leadingFractions.reduce(0, +)
            / Double(leadingFractions.count)
        let leadVariance = leadingFractions
            .map { ($0 - meanLead) * ($0 - meanLead) }
            .reduce(0, +) / Double(leadingFractions.count)
        let leadStddev = leadVariance.squareRoot()

        // Mean line width as fraction of region.
        let meanWidth = lines
            .map { Double(($0.maxX - $0.minX) / regionWidth) }
            .reduce(0, +) / Double(lines.count)

        // Terminal-punctuation ratio.
        var termCount = 0
        let terminals: Set<Character> = [
            ".", "!", "?", ":", ";", "…"
        ]
        for line in lines {
            let text = line.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            // Quote-following case: a line ending in `."` still
            // counts as terminal punctuation.
            var probe = text
            while let last = probe.last,
                  ["\"", "”", "’", "'", ")"].contains(last) {
                probe.removeLast()
            }
            if let last = probe.last, terminals.contains(last) {
                termCount += 1
            }
        }
        let termRatio = Double(termCount) / Double(lines.count)

        return Features(
            lineCount: lines.count,
            raggedRightRatio: raggedRatio,
            indentStddev: leadStddev,
            meanLineWidth: meanWidth,
            terminalPunctRatio: termRatio
        )
    }

    /// Map a normalized leading-x fraction (0.0–1.0) to an
    /// indent bucket (0…8). Bucket 0 = flush left (fraction <
    /// 0.05); bucket 8 = past 80% of region width. Linear
    /// interpolation in between with rounding.
    static func quantizeIndent(fraction: CGFloat) -> Int {
        guard fraction > 0.05 else { return 0 }
        let scaled = Double(fraction) * Double(indentBucketCount)
        let bucket = Int(scaled.rounded())
        return max(0, min(indentBucketCount, bucket))
    }

    // MARK: - Inline runs

    /// Build the `[InlineRun]` for one verse line. Splits at
    /// script boundaries — consecutive Greek codepoints get
    /// `language = BCP47("grc")`; everything else stays untagged
    /// (defaulting to the parent block language). Italic /
    /// bold flags propagate when *every* observation in the line
    /// reports them (same strict-consensus posture as
    /// `RegionAwareReflow.blockForRegion`).
    static func makeRuns(for line: Line) -> [InlineRun] {
        let italic = !line.observations.isEmpty
            && line.observations.allSatisfy(\.isItalic)
        let bold = !line.observations.isEmpty
            && line.observations.allSatisfy(\.isBold)
        let text = line.text
        guard !text.isEmpty else { return [] }
        // Walk codepoints, group consecutive same-script chars.
        var segments: [(String, BCP47?)] = []
        var currentChars: [Character] = []
        var currentScript: Script = .other
        for ch in text {
            let script = Self.script(of: ch)
            if currentChars.isEmpty {
                currentScript = script
                currentChars.append(ch)
                continue
            }
            // Merge same-script runs; whitespace stays with the
            // preceding run so we don't produce empty-text spans.
            if script == currentScript
                || ch.isWhitespace {
                currentChars.append(ch)
            } else {
                segments.append((
                    String(currentChars),
                    Self.language(for: currentScript)
                ))
                currentChars = [ch]
                currentScript = script
            }
        }
        if !currentChars.isEmpty {
            segments.append((
                String(currentChars),
                Self.language(for: currentScript)
            ))
        }
        return segments.map { (segText, lang) in
            InlineRun(
                segText,
                language: lang,
                isItalic: italic,
                isBold: bold
            )
        }
    }

    enum Script { case latin, greek, other }

    static func script(of ch: Character) -> Script {
        for scalar in ch.unicodeScalars {
            // Greek and Coptic block + Greek Extended block.
            if (0x0370...0x03FF).contains(scalar.value)
                || (0x1F00...0x1FFF).contains(scalar.value) {
                return .greek
            }
            // Basic Latin + Latin-1 Supplement + Latin Extended.
            if (0x0041...0x005A).contains(scalar.value)
                || (0x0061...0x007A).contains(scalar.value)
                || (0x00C0...0x024F).contains(scalar.value) {
                return .latin
            }
        }
        return .other
    }

    static func language(for script: Script) -> BCP47? {
        switch script {
        case .greek: return BCP47("grc")
        // Latin / other: leave nil so the parent block's lang
        // attribute applies. Italian / Latin / French distinction
        // requires lexicon lookup — out of scope for v1-narrow.
        case .latin, .other: return nil
        }
    }

    // MARK: - Types

    /// Aggregated geometry for a visual line. Built from
    /// observations belonging to the same y-cluster.
    public struct Line {
        public var observations: [TextObservation]
        public var minX: CGFloat = 0
        public var maxX: CGFloat = 0
        public var meanY: CGFloat = 0
        public var text: String = ""

        init(observations: [TextObservation]) {
            self.observations = observations
            recomputeAggregates()
        }

        mutating func recomputeAggregates() {
            guard !observations.isEmpty else { return }
            minX = observations.map { $0.box.minX }.min() ?? 0
            maxX = observations.map { $0.box.maxX }.max() ?? 0
            let yTotal = observations.map { $0.box.midY }.reduce(0, +)
            meanY = yTotal / CGFloat(observations.count)
            text = observations.map(\.text).joined(separator: " ")
        }
    }

    /// Computed signal values, returned for diagnostic logging in
    /// debug-mode conversions.
    public struct Features: Equatable, Sendable {
        public let lineCount: Int
        public let raggedRightRatio: Double
        public let indentStddev: Double
        public let meanLineWidth: Double
        public let terminalPunctRatio: Double
    }

    /// Detector verdict. Caller uses `lines` for `Block.verse`
    /// and may surface `features` in the debug log.
    public struct Verdict: Sendable {
        public let lines: [VerseLine]
        public let features: Features
    }
}
