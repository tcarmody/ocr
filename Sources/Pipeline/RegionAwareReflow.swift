import Foundation
import CoreGraphics
import Document
import Layout
import OCR

/// Block-stream builder that uses Surya's typed regions instead of the
/// heuristic H/F + column-splitter + paragraph-reflow chain. The
/// heuristic path is still there as a fallback for pages where the
/// layout analyzer produced no regions or isn't available.
///
/// Algorithm per page:
///   1. Drop regions we treat as page furniture: pageHeader,
///      pageFooter, footnote, picture, table, formula. Footnote popup
///      linking is Phase 5; figures are Phase 6.
///   2. Sort surviving regions by reading order. Surya's reading order
///      is column-aware — left column top to bottom, then right column
///      top to bottom on a 2-column page; running-head regions get
///      low positions and are already filtered out anyway.
///   3. For each region, collect observations whose bbox center sits
///      inside the region (with a small inflation tolerance to catch
///      observations whose box edges spill slightly past the region).
///   4. Sort observations within a region top-to-bottom, then left-to-
///      right. Join into one paragraph string with dehyphenation.
///   5. Emit a `Block.heading` for sectionHeader/title; otherwise
///      `Block.paragraph`.
///
/// Cross-region/page bridging (soft hyphens, mid-sentence joins) is
/// handled afterward by `PDFToEPUBPipeline.bridgeBoundaries`.
enum RegionAwareReflow {

    /// Region kinds that contribute to the body block stream.
    private static let bodyKinds: Set<LayoutRegion.Kind> = [
        .text, .sectionHeader, .title, .listItem, .caption,
    ]

    /// Inflate a region's bbox slightly so observations whose corners
    /// poke past the region's reported bounds still get attributed.
    /// Surya's bbox sometimes hugs the text tighter than the actual
    /// glyph extents.
    private static let regionInflation: CGFloat = 0.005

    /// Per-observation attribution captured during reflow. Used by the
    /// debug log to explain why specific text ended up in specific
    /// blocks. Map key is `(pageIndex, observationIndex)`.
    static var lastAttributions: [ObservationKey: AttributionInfo] = [:]

    struct AttributionInfo: Sendable {
        let regionReadingOrder: Int
        let regionKind: String
    }

    /// Output of one reflow pass: the body block stream plus the
    /// chapter-level footnote collection that body runs reference via
    /// `InlineRun.noterefId`. Footnotes only get populated when the
    /// layout analyzer found `.footnote` regions.
    struct Result: Sendable, Equatable {
        let blocks: [Block]
        let footnotes: [Footnote]
        let pageAnchors: [PageAnchor]
    }

    /// Anchor id format. `EditorViewModel`'s linked-navigation feature
    /// looks for `[id^="hu-page-"]` in the rendered XHTML, so this
    /// prefix is load-bearing — change in both places if changed.
    static func anchorId(forPageIndex pageIndex: Int) -> String {
        "hu-page-\(pageIndex)"
    }

    /// Per-page footnote audit captured during reflow for the debug
    /// log. Map key is `pageIndex`. Empty arrays are omitted.
    static var lastFootnotesPerPage: [Int: [FootnoteLinker.Parsed]] = [:]

    /// Per-page record of `.text` regions Surya tagged that we
    /// reclassified as `.footnote` based on the marker / position /
    /// gap heuristic. Surfaced in the debug log so we can see what
    /// fired (and didn't fire) and tune thresholds.
    static var lastReclassificationsPerPage: [Int: [Reclassification]] = [:]

    /// Per-page record of `.text` regions reclassified as
    /// `.pageHeader` / `.pageFooter` by the running-furniture
    /// heuristic. Same shape as the footnote audit so the debug
    /// log can format them identically.
    static var lastHFReclassificationsPerPage: [Int: [Reclassification]] = [:]

    /// One region's reclassification trace. `signals` is a small
    /// human-readable list ("starts with marker '1.'", "in bottom 60%",
    /// "gap=0.087 > 2× line=0.038") for the debug log.
    struct Reclassification: Sendable, Equatable {
        let regionIndex: Int
        let originalKind: String
        let newKind: String
        let firstLineExcerpt: String
        let signals: [String]
    }

    static func reflow(pageResults: [PageObservations]) -> Result {
        lastAttributions.removeAll(keepingCapacity: true)
        lastFootnotesPerPage.removeAll(keepingCapacity: true)
        lastReclassificationsPerPage.removeAll(keepingCapacity: true)
        lastHFReclassificationsPerPage.removeAll(keepingCapacity: true)
        var blocks: [Block] = []
        var allFootnotes: [FootnoteLinker.Parsed] = []
        var pageAnchors: [PageAnchor] = []
        for page in pageResults {
            // Page-boundary anchor — invisible in normal rendering,
            // used by the editor to align preview scroll with PDF
            // page (and by EPUB readers as an epub:type=pagebreak
            // for "skip to page N" navigation).
            let anchor = anchorId(forPageIndex: page.pageIndex)
            blocks.append(.anchor(id: anchor, label: "Page \(page.pageIndex + 1)"))
            pageAnchors.append(PageAnchor(pdfPage: page.pageIndex, anchorId: anchor))

            // Fall back to the heuristic path when no regions were
            // produced (no analyzer, or analyzer returned nothing).
            guard let regions = page.layoutRegions, !regions.isEmpty else {
                blocks.append(contentsOf: heuristicFallback(for: page))
                continue
            }
            // Reclassify Surya `.text` regions that look like
            // footnotes — Surya often misses these and tags them as
            // body. Conservative heuristic (3 signals must agree)
            // documented on `reclassifyLikelyFootnotes`.
            let (afterFootnotes, fnDecisions) = reclassifyLikelyFootnotes(
                regions: regions, observations: page.observations
            )
            if !fnDecisions.isEmpty {
                lastReclassificationsPerPage[page.pageIndex] = fnDecisions
            }
            // Now do the same for running heads / footers. Runs
            // *after* the footnote pass so a 1-line footnote in the
            // bottom 10% (already retagged to `.footnote`) won't be
            // re-grabbed as a `.pageFooter` and lose its popup.
            let (effectiveRegions, hfDecisions) = reclassifyLikelyHeadersFooters(
                regions: afterFootnotes, observations: page.observations
            )
            if !hfDecisions.isEmpty {
                lastHFReclassificationsPerPage[page.pageIndex] = hfDecisions
            }
            let pageFootnotes = FootnoteLinker.parseFootnotes(
                pageIndex: page.pageIndex,
                observations: page.observations,
                regions: effectiveRegions
            )
            if !pageFootnotes.isEmpty {
                lastFootnotesPerPage[page.pageIndex] = pageFootnotes
                allFootnotes.append(contentsOf: pageFootnotes)
            }
            blocks.append(contentsOf: reflowPage(
                page: page, regions: effectiveRegions, pageFootnotes: pageFootnotes
            ))
        }
        let bridged = PDFToEPUBPipeline.bridgeBoundaries(blocks)
        return Result(
            blocks: bridged,
            footnotes: FootnoteLinker.footnotesForChapter(allFootnotes),
            pageAnchors: pageAnchors
        )
    }

    private static func heuristicFallback(for page: PageObservations) -> [Block] {
        ParagraphReflow().reflow(page.observations)
    }

    private static func reflowPage(
        page: PageObservations,
        regions: [LayoutRegion],
        pageFootnotes: [FootnoteLinker.Parsed]
    ) -> [Block] {
        // Sort by reading order; -1 (unassigned) sorts to the end so
        // it doesn't disrupt the ordered regions.
        let ordered = regions.sorted { (a, b) in
            switch (a.readingOrder, b.readingOrder) {
            case let (x, y) where x >= 0 && y >= 0: return x < y
            case (let x, _) where x >= 0:           return true
            case (_, let y) where y >= 0:           return false
            default:                                 return false
            }
        }

        var blocks: [Block] = []
        // Inflated region bboxes overlap at paragraph boundaries, so
        // an observation sitting on a seam can satisfy `contains` for
        // two adjacent regions and end up duplicated in the output.
        // Walk regions in reading order and let the first claimant win.
        var claimed = Set<Int>()
        for region in ordered {
            guard bodyKinds.contains(region.kind) else { continue }
            let inflated = region.box.insetBy(dx: -regionInflation, dy: -regionInflation)
            var assigned: [TextObservation] = []
            for (idx, obs) in page.observations.enumerated() {
                if claimed.contains(idx) { continue }
                let cx = obs.box.midX
                let cy = obs.box.midY
                guard inflated.contains(CGPoint(x: cx, y: cy)) else { continue }
                assigned.append(obs)
                claimed.insert(idx)
                Self.lastAttributions[
                    ObservationKey(pageIndex: page.pageIndex, observationIndex: idx)
                ] = AttributionInfo(
                    regionReadingOrder: region.readingOrder,
                    regionKind: region.kind.rawValue
                )
            }
            guard !assigned.isEmpty else { continue }

            // Sort top-to-bottom then left-to-right within the region.
            let sorted = assigned.sorted { a, b in
                if abs(a.box.midY - b.box.midY) > 0.005 { return a.box.midY > b.box.midY }
                return a.box.minX < b.box.minX
            }
            // Join with soft-hyphen-aware concatenation.
            let text = joinWithDehyphenation(sorted.map(\.text))
            guard !text.isEmpty else { continue }

            blocks.append(blockForRegion(
                kind: region.kind,
                text: text,
                pageFootnotes: pageFootnotes
            ))
        }
        return blocks
    }

    private static func blockForRegion(
        kind: LayoutRegion.Kind,
        text: String,
        pageFootnotes: [FootnoteLinker.Parsed]
    ) -> Block {
        switch kind {
        // Headings shouldn't carry footnote references — keep them as
        // a single plain run to avoid linker false positives in title
        // text like a chapter number.
        case .title:         return .heading(level: 1, runs: [InlineRun(text)])
        case .sectionHeader: return .heading(level: 2, runs: [InlineRun(text)])
        // listItem keeps its inline marker ("1.", "2.", "•") because
        // Surya doesn't strip it; the EPUB renders this as a paragraph
        // beginning with the marker — fine for now, real <ol>/<ul>
        // markup is a later refinement.
        case .listItem:
            return .paragraph(runs: FootnoteLinker.splice(
                text: text, footnotes: pageFootnotes
            ))
        case .caption:
            return .paragraph(runs: FootnoteLinker.splice(
                text: text, footnotes: pageFootnotes
            ))
        case .text, .pageHeader, .pageFooter, .footnote,
             .picture, .table, .formula, .other:
            return .paragraph(runs: FootnoteLinker.splice(
                text: text, footnotes: pageFootnotes
            ))
        }
    }

    /// Apply soft-hyphen handling line-by-line within a region, then
    /// join. Identical heuristic to `Dehyphenation.join` so the
    /// output is consistent with the heuristic path.
    private static func joinWithDehyphenation(_ lines: [String]) -> String {
        guard let first = lines.first else { return "" }
        var acc = first.trimmingCharacters(in: .whitespaces)
        for next in lines.dropFirst() {
            acc = Dehyphenation.join(acc, next)
        }
        return acc
    }

    // MARK: - footnote reclassification heuristic

    /// Region's center must be no higher than this (in normalized
    /// page coordinates with y=0 at bottom, y=1 at top) to be eligible
    /// for footnote reclassification. Footnotes don't appear in the
    /// upper half of a page.
    private static let footnoteCenterMaxY: CGFloat = 0.55
    /// Vertical gap (in units of median observation height) above a
    /// region required for footnote reclassification. Numbered lists
    /// embedded in body text typically sit close to the preceding
    /// paragraph; visually-separated footnotes have a larger gap.
    private static let footnoteGapMultiplier: CGFloat = 2.0
    /// X-center distance (normalized) below which two regions are
    /// considered "in the same column." Loose enough to handle slight
    /// per-line skew in Surya's bbox output.
    private static let sameColumnXTolerance: CGFloat = 0.10

    /// Walk the region list and reclassify any `.text` region as
    /// `.footnote` when **all three** signals agree:
    ///
    ///   1. The region's first observation (top-most line) starts
    ///      with a footnote marker — `^\d{1,3}[.)]\s` for numeric or
    ///      `*†‡§¶•` for symbolic.
    ///   2. The region's vertical center sits in the lower half of
    ///      the page (`midY <= 0.55`).
    ///   3. There is a substantial vertical gap (`>= 2× median line
    ///      height`) between this region and the nearest text region
    ///      above it in the same column.
    ///
    /// Conservative on purpose: a numbered list embedded in body text
    /// (Foucault's "It merits attention for several reasons. 1. …
    /// 2. …") fails signal #3 because consecutive list items abut
    /// the body without a wide gap. Standalone footnotes —
    /// visually separated by a blank line or rule — pass.
    ///
    /// Returns the new region list (same indices, kinds possibly
    /// changed) plus a per-decision audit trail for the debug log.
    static func reclassifyLikelyFootnotes(
        regions: [LayoutRegion],
        observations: [TextObservation]
    ) -> (regions: [LayoutRegion], decisions: [Reclassification]) {
        var output = regions
        var decisions: [Reclassification] = []

        for (idx, region) in regions.enumerated() {
            guard region.kind == .text else { continue }

            // Signal 1: marker pattern at start of first (top) line.
            let inflated = region.box.insetBy(
                dx: -regionInflation, dy: -regionInflation
            )
            let inRegion = observations.filter { obs in
                inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
            }
            guard !inRegion.isEmpty else { continue }
            let firstObs = inRegion.max(by: { $0.box.midY < $1.box.midY })
            let firstText = (firstObs?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let marker = leadingFootnoteMarker(firstText) else { continue }

            // Signal 2: position in lower half of page.
            guard region.box.midY <= footnoteCenterMaxY else { continue }

            // Signal 3: substantial gap above in same column.
            let medianH = medianObservationHeight(in: inRegion)
            guard medianH > 0 else { continue }
            let abovePrev = nearestTextRegionAbove(
                index: idx, in: regions
            )
            // If nothing above in this column, treat as passing — a
            // footnote at the very top of a column is rare but valid.
            let gap: CGFloat
            if let prev = abovePrev {
                gap = prev.region.box.minY - region.box.maxY
                guard gap >= footnoteGapMultiplier * medianH else { continue }
            } else {
                gap = .infinity
            }

            // All three signals agree — reclassify.
            output[idx] = LayoutRegion(
                kind: .footnote,
                box: region.box,
                readingOrder: region.readingOrder,
                confidence: region.confidence
            )
            let excerpt = String(firstText.prefix(60))
            let gapDesc = gap == .infinity
                ? "no preceding region in column"
                : String(format: "gap=%.3f > %.1f×line=%.3f", Double(gap), Double(footnoteGapMultiplier), Double(medianH))
            decisions.append(Reclassification(
                regionIndex: idx,
                originalKind: region.kind.rawValue,
                newKind: "footnote",
                firstLineExcerpt: excerpt,
                signals: [
                    "marker='\(marker)'",
                    String(format: "midY=%.3f ≤ %.2f", Double(region.box.midY), Double(footnoteCenterMaxY)),
                    gapDesc,
                ]
            ))
        }

        return (output, decisions)
    }

    /// Numeric (`1.`, `12)`, `3` followed by space) or symbolic
    /// (`*†‡§¶•`) marker at the very start of `text`. Returns the
    /// matched marker substring on hit, nil otherwise.
    private static func leadingFootnoteMarker(_ text: String) -> String? {
        guard let first = text.first else { return nil }
        if "*†‡§¶•".contains(first) { return String(first) }
        // Numeric: 1-3 digits followed by `.`, `)`, or whitespace.
        if let r = text.range(
            of: #"^\d{1,3}[.)\s]"#, options: .regularExpression
        ), r.lowerBound == text.startIndex {
            return String(text[r])
        }
        return nil
    }

    private static func medianObservationHeight(
        in observations: [TextObservation]
    ) -> CGFloat {
        let heights = observations.map(\.box.height).sorted()
        guard !heights.isEmpty else { return 0 }
        return heights[heights.count / 2]
    }

    /// Find the text region with the smallest vertical distance ABOVE
    /// `regions[index]` whose X-extent overlaps (same column).
    /// Returns the region and its index, or nil if none.
    private static func nearestTextRegionAbove(
        index: Int, in regions: [LayoutRegion]
    ) -> (region: LayoutRegion, index: Int)? {
        let target = regions[index]
        var best: (region: LayoutRegion, index: Int)? = nil
        var bestMinY: CGFloat = .infinity
        for (i, other) in regions.enumerated() {
            guard i != index, other.kind == .text else { continue }
            guard isInSameColumn(other, target) else { continue }
            // Strictly above means other's bottom > our top.
            guard other.box.minY > target.box.maxY else { continue }
            // Closest = smallest minY (region whose bottom edge is
            // nearest to our top edge).
            if other.box.minY < bestMinY {
                bestMinY = other.box.minY
                best = (other, i)
            }
        }
        return best
    }

    private static func isInSameColumn(
        _ a: LayoutRegion, _ b: LayoutRegion
    ) -> Bool {
        abs(a.box.midX - b.box.midX) < sameColumnXTolerance
    }

    // MARK: - header / footer reclassification heuristic

    /// A `.text` region's center must be at least this high
    /// (normalized, y=0 bottom) to be eligible for `.pageHeader`
    /// reclassification. Top 10% of the page.
    private static let pageHeaderMinY: CGFloat = 0.90
    /// A `.text` region's center must be no higher than this to be
    /// eligible for `.pageFooter` reclassification. Bottom 10%.
    private static let pageFooterMaxY: CGFloat = 0.10
    /// Region's bbox height must be no greater than this to count
    /// as page furniture. 5% of page eliminates body paragraphs
    /// (typically 10%+) and section headers (typically 4-6% with
    /// looser layout) while still admitting one-to-two-line headers
    /// and standalone page-number regions.
    private static let pageFurnitureMaxHeight: CGFloat = 0.05
    /// Total combined text length above which we don't treat a
    /// region as page furniture, no matter where it sits. Real
    /// running heads + page numbers are short ("Chapter 3 — Foo
    /// 47"); body content that strays into the extreme zones is
    /// typically much longer.
    private static let pageFurnitureMaxChars: Int = 100

    /// Walk the region list and reclassify any `.text` region as
    /// `.pageHeader` / `.pageFooter` when **all three** signals agree:
    ///
    ///   1. The region's vertical center is in the top 10%
    ///      (`midY >= 0.90`) → `.pageHeader`, or in the bottom 10%
    ///      (`midY <= 0.10`) → `.pageFooter`.
    ///   2. The region itself is short — `box.height <= 0.05`. This
    ///      is the load-bearing signal that protects body paragraphs
    ///      that happen to extend into the extreme zones from being
    ///      mis-dropped.
    ///   3. Total text length across the region's observations is
    ///      no more than 100 characters.
    ///
    /// Conservative on purpose: a body paragraph that grazes the top
    /// margin still spans more than 5% of the page in height and so
    /// fails signal #2. A section header that sits at the page top
    /// is also typically a couple of lines tall and fails #2 — and
    /// even if it slipped through, Surya usually labels it
    /// `.sectionHeader` anyway, which we never reclassify.
    ///
    /// Returns the new region list (same indices, kinds possibly
    /// changed) plus a per-decision audit trail for the debug log.
    static func reclassifyLikelyHeadersFooters(
        regions: [LayoutRegion],
        observations: [TextObservation]
    ) -> (regions: [LayoutRegion], decisions: [Reclassification]) {
        var output = regions
        var decisions: [Reclassification] = []

        for (idx, region) in regions.enumerated() {
            guard region.kind == .text else { continue }

            // Signal 1: position. Header zone or footer zone, else skip.
            let targetKind: LayoutRegion.Kind
            let positionDesc: String
            if region.box.midY >= pageHeaderMinY {
                targetKind = .pageHeader
                positionDesc = String(format: "midY=%.3f ≥ %.2f (top zone)",
                                      Double(region.box.midY), Double(pageHeaderMinY))
            } else if region.box.midY <= pageFooterMaxY {
                targetKind = .pageFooter
                positionDesc = String(format: "midY=%.3f ≤ %.2f (bottom zone)",
                                      Double(region.box.midY), Double(pageFooterMaxY))
            } else {
                continue
            }

            // Signal 2: region height ≤ furniture threshold.
            guard region.box.height <= pageFurnitureMaxHeight else { continue }

            // Signal 3: total text length under the brevity cap. We
            // also need the first line for the audit excerpt.
            let inflated = region.box.insetBy(
                dx: -regionInflation, dy: -regionInflation
            )
            let inRegion = observations.filter { obs in
                inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
            }
            guard !inRegion.isEmpty else { continue }
            let totalChars = inRegion.reduce(0) { $0 + $1.text.count }
            guard totalChars <= pageFurnitureMaxChars else { continue }

            let firstObs = inRegion.max(by: { $0.box.midY < $1.box.midY })
            let excerpt = String((firstObs?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(60))

            // All three signals agree — reclassify.
            output[idx] = LayoutRegion(
                kind: targetKind,
                box: region.box,
                readingOrder: region.readingOrder,
                confidence: region.confidence
            )
            decisions.append(Reclassification(
                regionIndex: idx,
                originalKind: region.kind.rawValue,
                newKind: targetKind.rawValue,
                firstLineExcerpt: excerpt,
                signals: [
                    positionDesc,
                    String(format: "height=%.3f ≤ %.2f", Double(region.box.height), Double(pageFurnitureMaxHeight)),
                    "chars=\(totalChars) ≤ \(pageFurnitureMaxChars)",
                ]
            ))
        }

        return (output, decisions)
    }
}
