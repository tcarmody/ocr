import Foundation
import CoreGraphics
import Layout
import OCR

/// P-Math-Region-Detection. Surya's layout model under-classifies
/// display equations: in the Becker corpus, zero of 54 pages had a
/// single `.formula` region despite display equations on dozens of
/// pages. Everything came through as `.text` or `.other`. As a
/// result `P-Math-Cascade`'s `ClaudeMathExtractor` never fired,
/// and equations relied on Surya's lossy per-glyph text OCR
/// (which is what "fumbled math script" looks like to the reader).
///
/// This helper walks Surya's regions and promotes `.text` /
/// `.other` regions to `.formula` when display-equation signals
/// fire. Once promoted, the math extractor runs against the
/// cropped page image and produces clean MathML — the lossy text
/// path is bypassed entirely.
///
/// Two tiers ship together (both deterministic, no model cost):
///   * `promoteGeometric` — pre-OCR. Narrow + centered + isolated
///     + short region. Catches well-typeset textbook display
///     equations.
///   * `promoteByText` — post-OCR. High `<math>` markup density,
///     or LaTeX-style markers + `=` + sparse prose, or trailing
///     `(N)` equation number. Catches anything Surya inline-
///     tagged or that visibly looks like equation text.
public enum FormulaRegionPromoter {

    // MARK: - Diagnostics

    /// Per-promotion decision record. Surfaced in the debug log so
    /// the user can audit why a paragraph became a formula (or
    /// vice-versa) — silent reclassification was the hardest part
    /// of debugging Surya's misses on the Becker corpus.
    public struct Diagnostics: Sendable {
        public struct Decision: Sendable {
            public let regionIndex: Int
            public let fromKind: LayoutRegion.Kind
            public let tier: Int
            public let signals: [String]
        }
        public var promotions: [Decision]

        public init(promotions: [Decision] = []) {
            self.promotions = promotions
        }
    }

    // MARK: - Tier 1: geometric

    /// Promote regions whose geometry matches a display-equation
    /// shape: narrow (< 70% of body column width), centered
    /// (`|leftMargin - rightMargin| < 0.10 × pageWidth`), short
    /// (≤ 3 dominant line heights), and isolated from neighbors
    /// (vertical gap ≥ 0.5 line heights to the closest sibling
    /// above or below). Equation-number suffix is a signal-
    /// amplifier: a region ending in `(1)`, `(3.4)`, `(A.2)` etc.
    /// passes a relaxed centering threshold.
    ///
    /// Returns the (possibly updated) region array plus a
    /// `Diagnostics.Decision` list for every promotion. Regions
    /// that don't promote pass through untouched.
    ///
    /// Inputs are in Vision's normalized [0,1] coordinate space.
    /// `observations` is consulted *only* to spot the equation-
    /// number suffix when the page-OCR pass has already populated
    /// them (typical: Vision runs concurrent with Surya layout,
    /// so observations are available by the time this helper
    /// fires). When empty, the equation-number relaxation simply
    /// doesn't trigger — the strict centering test still applies.
    public static func promoteGeometric(
        regions: [LayoutRegion],
        observations: [TextObservation] = []
    ) -> (regions: [LayoutRegion], diagnostics: Diagnostics) {
        guard !regions.isEmpty else { return (regions, Diagnostics()) }

        // Page geometry baselines from the existing region set.
        // `.text` regions are the cleanest proxy for body-column
        // width; falling back to .other / all regions when no
        // `.text` is present (rare, but defensive).
        let bodyWidth = dominantWidth(regions: regions)
        // Line height: prefer observation heights when available
        // (per-observation bboxes are per-line, so the median is
        // the actual line height). Fall back to a fraction of
        // the median region height as a coarse proxy when
        // observations haven't been populated yet.
        let lineHeight = dominantLineHeight(
            regions: regions, observations: observations
        )
        guard bodyWidth > 0, lineHeight > 0 else {
            return (regions, Diagnostics())
        }

        // Sort by midY (top of page first in normalized coords:
        // larger Y) to find vertical neighbors quickly.
        let sortedIndices = (0..<regions.count).sorted {
            regions[$0].box.midY > regions[$1].box.midY
        }
        var topNeighborIdx: [Int: Int] = [:]
        var bottomNeighborIdx: [Int: Int] = [:]
        for (i, idx) in sortedIndices.enumerated() {
            if i > 0 { topNeighborIdx[idx] = sortedIndices[i - 1] }
            if i + 1 < sortedIndices.count {
                bottomNeighborIdx[idx] = sortedIndices[i + 1]
            }
        }

        var out = regions
        var diag = Diagnostics()

        for (idx, region) in regions.enumerated() {
            // Only `.text` and `.other` are candidates — promoting
            // `.sectionHeader` / `.caption` / `.footnote` would
            // erase real structural intent.
            guard region.kind == .text || region.kind == .other else {
                continue
            }
            let box = region.box

            var signals: [String] = []
            var fail = false

            // Test 1: narrow vs body column.
            let widthRatio = box.width / bodyWidth
            if widthRatio < 0.70 {
                signals.append("narrow(w=\(pct(widthRatio))×body)")
            } else { fail = true }

            // Test 2: short — at most 3 line heights.
            let heightInLines = box.height / lineHeight
            if heightInLines <= 3.0 {
                signals.append("short(\(round1(heightInLines))L)")
            } else { fail = true }

            if fail {
                continue
            }

            // Test 3: centered OR has equation number suffix.
            // Centered = `|leftGap - rightGap| < 0.10 × pageWidth`.
            // (pageWidth = 1.0 in normalized coords.)
            let leftGap = box.minX
            let rightGap = 1.0 - box.maxX
            let asymmetry = abs(leftGap - rightGap)
            let centered = asymmetry < 0.10

            let regionText = aggregateText(
                regionBox: box, observations: observations
            )
            let hasEqNumber = endsWithEquationNumber(regionText)

            if centered {
                signals.append("centered(asym=\(pct(asymmetry)))")
            } else if hasEqNumber {
                // Numbered equations are commonly left-flush with
                // the body column but right-aligned to the equation
                // number; relax centering when the suffix fires.
                signals.append("eq#(\"\(equationNumberMatch(regionText) ?? "?")\")")
            } else {
                continue
            }

            // Test 4: isolated — vertical gap above OR below ≥
            // 0.5 line heights. Display equations sit BETWEEN
            // paragraphs, not flush against one.
            let gapAbove = verticalGap(
                from: box,
                toNeighbor: topNeighborIdx[idx].map { regions[$0].box },
                direction: .above
            )
            let gapBelow = verticalGap(
                from: box,
                toNeighbor: bottomNeighborIdx[idx].map { regions[$0].box },
                direction: .below
            )
            let isolatedAbove = gapAbove >= 0.5 * lineHeight
            let isolatedBelow = gapBelow >= 0.5 * lineHeight
            if isolatedAbove || isolatedBelow {
                signals.append(
                    "isolated(gap≥\(round1(max(gapAbove, gapBelow) / lineHeight))L)"
                )
            } else {
                continue
            }

            // Test 5 (when observations are populated): reject
            // promotion when the region's text shows no math
            // signals — title pages and centered chapter headers
            // share the geometric profile of display equations
            // (narrow + centered + short + isolated), and the
            // earlier tests can't tell them apart without text.
            // A region whose Vision-OCR'd text has no `=`, no
            // math symbols, no LaTeX operators, and no equation
            // number is almost certainly NOT math; geometry alone
            // is insufficient evidence to ship it through the
            // math extractor.
            if !regionText.isEmpty {
                let mathSignal = hasEqNumber
                    || containsMathSymbols(regionText)
                    || containsLaTeXOperator(regionText)
                    || regionText.contains("<math")
                if !mathSignal {
                    continue
                }
                signals.append("textHasMathSignal")
            }

            // All tests passed → promote.
            out[idx].kind = .formula
            diag.promotions.append(.init(
                regionIndex: idx,
                fromKind: region.kind,
                tier: 1,
                signals: signals
            ))
        }

        return (out, diag)
    }

    // MARK: - Tier 2: text-pattern

    /// Promote regions whose recognized text matches display-
    /// equation patterns:
    ///   * `<math>…</math>` markup spans ≥ 60% of the region's
    ///     text (region is mostly math with prose framing);
    ///   * Single short line containing `=` AND ≤ 5 prose words
    ///     AND a LaTeX-style operator (`\sum`, `\int`, `\frac`,
    ///     `^{...}`, `_{...}`);
    ///   * Text ends with `(N)` / `(N.M)` / `(A.N)` equation
    ///     number AND contains math symbols (greek letters,
    ///     integral signs, `=`, common operators).
    ///
    /// Runs AFTER Surya OCR + RegionCascade + post-OCR cleanup
    /// have populated observations — we want to pattern-match
    /// against the cleanest available text.
    public static func promoteByText(
        regions: [LayoutRegion],
        observations: [TextObservation]
    ) -> (regions: [LayoutRegion], diagnostics: Diagnostics) {
        guard !regions.isEmpty, !observations.isEmpty else {
            return (regions, Diagnostics())
        }

        var out = regions
        var diag = Diagnostics()

        for (idx, region) in regions.enumerated() {
            guard region.kind == .text || region.kind == .other else {
                continue
            }
            let text = aggregateText(
                regionBox: region.box, observations: observations
            )
            guard !text.isEmpty else { continue }

            var signals: [String] = []

            // Signal 1: <math> markup density ≥ 60%.
            let mathLen = mathMarkupLength(in: text)
            let totalLen = text.count
            if totalLen > 0 {
                let density = Double(mathLen) / Double(totalLen)
                if density >= 0.60 {
                    signals.append("mathML≥60%(\(pct(density)))")
                }
            }

            // Signal 2: single line + `=` + ≤ 5 prose words + a
            // LaTeX-style operator.
            if signals.isEmpty {
                let lines = text.split(separator: "\n").count
                let hasEquals = text.contains("=")
                let proseWordCount = countProseWords(in: text)
                let hasLatexOp = containsLaTeXOperator(text)
                if lines == 1, hasEquals, proseWordCount <= 5, hasLatexOp {
                    signals.append("singleLine+latexOp+\(proseWordCount)words")
                }
            }

            // Signal 3: trailing equation number + math symbols.
            if signals.isEmpty {
                if endsWithEquationNumber(text),
                   containsMathSymbols(text) {
                    let num = equationNumberMatch(text) ?? "?"
                    signals.append("eq#(\"\(num)\")+symbols")
                }
            }

            guard !signals.isEmpty else { continue }

            out[idx].kind = .formula
            diag.promotions.append(.init(
                regionIndex: idx,
                fromKind: region.kind,
                tier: 2,
                signals: signals
            ))
        }

        return (out, diag)
    }

    // MARK: - Geometry helpers

    /// Median width across `.text` regions (the cleanest proxy for
    /// body-column width). Falls back to median across all regions
    /// when no `.text` regions exist on the page.
    static func dominantWidth(regions: [LayoutRegion]) -> CGFloat {
        let texts = regions.filter { $0.kind == .text }
        let pool = texts.isEmpty ? regions : texts
        let widths = pool.map { $0.box.width }.sorted()
        return median(widths)
    }

    /// Line-height proxy for the geometric thresholds. Prefers
    /// observation heights when available — per-observation
    /// bboxes are per-line, so the median is the actual line
    /// height (much more reliable than dividing region heights
    /// by an unknown line count). Falls back to a coarse 1/5 of
    /// the median region height when observations haven't been
    /// populated yet (a typical paragraph is ~5 lines).
    static func dominantLineHeight(
        regions: [LayoutRegion],
        observations: [TextObservation] = []
    ) -> CGFloat {
        if !observations.isEmpty {
            let heights = observations.map(\.box.height).sorted()
            let m = median(heights)
            // Clamp to a sane floor so a noisy outlier doesn't
            // disqualify real display equations.
            return max(0.005, m)
        }
        let texts = regions.filter { $0.kind == .text }
        let pool = texts.isEmpty ? regions : texts
        let heights = pool.map { $0.box.height }.sorted()
        let regionMedian = median(heights)
        // Heuristic fallback: paragraphs typically hold ~5 lines,
        // so 1/5 of the region height is a rough line-height
        // proxy. Generous to keep the heuristic catching real
        // display equations.
        return max(0.005, regionMedian / 5)
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let mid = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[mid - 1] + values[mid]) / 2
        }
        return values[mid]
    }

    enum Direction { case above; case below }

    /// Vertical gap between `box` and its `neighbor` in the given
    /// direction. Uses normalized [0,1] coords where Y increases
    /// upward — "above" means the neighbor has a larger maxY than
    /// box.maxY. Returns 0 when there's no neighbor or overlap.
    static func verticalGap(
        from box: CGRect,
        toNeighbor neighbor: CGRect?,
        direction: Direction
    ) -> CGFloat {
        guard let n = neighbor else { return 0 }
        switch direction {
        case .above:
            // Neighbor sits above box; gap = neighbor.minY - box.maxY.
            return max(0, n.minY - box.maxY)
        case .below:
            // Neighbor sits below box; gap = box.minY - neighbor.maxY.
            return max(0, box.minY - n.maxY)
        }
    }

    // MARK: - Text helpers

    /// Aggregate observation text whose box centers fall inside
    /// `regionBox`. Mirrors the reflow stage's claiming logic
    /// (first claimant wins) without the claimed-set side effects.
    /// Joins with newlines so multi-line equations are visible to
    /// the text-pattern heuristics.
    static func aggregateText(
        regionBox: CGRect, observations: [TextObservation]
    ) -> String {
        var lines: [(y: CGFloat, x: CGFloat, text: String)] = []
        for obs in observations {
            let cx = obs.box.midX
            let cy = obs.box.midY
            // Use a small inflation so border lines aren't excluded
            // (same posture as RegionAwareReflow's region inflation).
            let inflated = regionBox.insetBy(dx: -0.005, dy: -0.005)
            if cx >= inflated.minX, cx <= inflated.maxX,
               cy >= inflated.minY, cy <= inflated.maxY {
                lines.append((cy, cx, obs.text))
            }
        }
        // Sort top-down, left-right (Vision coords: larger Y = higher).
        lines.sort { (a, b) in
            if abs(a.y - b.y) > 0.005 { return a.y > b.y }
            return a.x < b.x
        }
        return lines.map(\.text).joined(separator: "\n")
    }

    /// Total length of `<math>…</math>` regions in `text`. Used to
    /// compute math-markup density relative to total text length.
    static func mathMarkupLength(in text: String) -> Int {
        var total = 0
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let open = text.range(
                of: "<math", range: cursor..<text.endIndex
              ),
              let openEnd = text.range(
                of: ">", range: open.upperBound..<text.endIndex
              ),
              let close = text.range(
                of: "</math>", range: openEnd.upperBound..<text.endIndex
              ) {
            total += text.distance(
                from: open.lowerBound, to: close.upperBound
            )
            cursor = close.upperBound
        }
        return total
    }

    /// Match a trailing equation-number pattern: `(1)`, `(3.4)`,
    /// `(A.2)`, `(3.4a)`. Allows trailing whitespace.
    static func endsWithEquationNumber(_ text: String) -> Bool {
        equationNumberMatch(text) != nil
    }

    /// Extract the trailing equation-number pattern (the `(…)`
    /// suffix) when present, else nil. Pattern accepts numbers,
    /// dotted hierarchies, letter prefixes, and an optional letter
    /// suffix — covers `(1)`, `(3.4)`, `(A.2)`, `(3.4a)`.
    static func equationNumberMatch(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")") else { return nil }
        // Walk backward from the closing `)` to find the matching `(`.
        guard let close = trimmed.lastIndex(of: ")") else { return nil }
        // Limit search distance — equation numbers don't run long.
        let searchStart = trimmed.index(
            close, offsetBy: -10, limitedBy: trimmed.startIndex
        ) ?? trimmed.startIndex
        guard let open = trimmed[searchStart..<close].lastIndex(of: "(")
        else { return nil }
        let inside = trimmed[trimmed.index(after: open)..<close]
        // Accept: bare digits (`1`), dotted hierarchies (`3.4`),
        // letter+dot prefix (`A.2`, `B.1.4`), optional trailing
        // lowercase letter (`3.4a`). The `(\.\d+|\d+)` branch
        // handles the lead component for both `A.2` (matches `.2`
        // after the prefix) and `3.4` (matches `3` then continues
        // with `.4`).
        let pattern = #"^[A-Z]?(\.\d+|\d+)(\.\d+)*[a-z]?$"#
        if inside.range(of: pattern, options: .regularExpression) != nil {
            return String(trimmed[open...close])
        }
        return nil
    }

    /// LaTeX-style operators commonly seen in cascade-OCR'd math:
    /// `\frac{`, `\sum`, `\int`, `\prod`, `\sqrt`, `^{`, `_{`.
    static func containsLaTeXOperator(_ text: String) -> Bool {
        let markers = [
            "\\frac{", "\\sum", "\\int", "\\prod", "\\sqrt",
            "\\partial", "\\nabla", "\\infty",
            "^{", "_{",
        ]
        return markers.contains(where: { text.contains($0) })
    }

    /// Math-symbol detection for the equation-number heuristic:
    /// `=`, common Unicode operators (∑ ∫ ∏ √ ∂ ∇ ∞ ≤ ≥ ≠ ± × ÷),
    /// greek letters, sub/superscript Unicode digits.
    static func containsMathSymbols(_ text: String) -> Bool {
        if text.contains("=") { return true }
        let symbols: Set<Character> = [
            "∑", "∫", "∏", "√", "∂", "∇", "∞",
            "≤", "≥", "≠", "≈", "≡", "±", "×", "÷",
            "α", "β", "γ", "δ", "ε", "ζ", "η", "θ",
            "λ", "μ", "ν", "ξ", "π", "ρ", "σ", "τ",
            "φ", "χ", "ψ", "ω",
            "Γ", "Δ", "Θ", "Λ", "Ξ", "Π", "Σ", "Φ", "Ψ", "Ω",
        ]
        for c in text where symbols.contains(c) { return true }
        return false
    }

    /// Count "prose-shaped" tokens in `text` — sequences of two or
    /// more ASCII letters separated by non-letter characters. The
    /// goal isn't precise linguistics; it's distinguishing equation
    /// text (`E = mc²` has 2 prose-shaped tokens: `E`, `mc`) from
    /// real prose (`This means that x equals` has 5+).
    static func countProseWords(in text: String) -> Int {
        // Strip <math>...</math> markup first so the inside doesn't
        // inflate the count — variables inside `<math>` are not
        // prose.
        let stripped = text.replacingOccurrences(
            of: "<math[^>]*>[^<]*</math>",
            with: " ",
            options: .regularExpression
        )
        var count = 0
        var runLength = 0
        for c in stripped {
            if c.isLetter {
                runLength += 1
            } else {
                if runLength >= 2 { count += 1 }
                runLength = 0
            }
        }
        if runLength >= 2 { count += 1 }
        return count
    }

    // MARK: - Formatting helpers (for the diagnostic signal strings)

    static func pct(_ value: CGFloat) -> String {
        String(format: "%.0f%%", value * 100)
    }
    static func round1(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}
