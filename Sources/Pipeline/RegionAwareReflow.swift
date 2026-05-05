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

    /// Per-page record of heading regions whose Surya-assigned
    /// reading order placed them after body content despite being
    /// visually above all of it — promoted to the front of the page
    /// by `correctHeadingReadingOrder`. Surfaced in the debug log
    /// so we can see when the heuristic fires.
    static var lastHeadingPromotionsPerPage: [Int: [HeadingPromotion]] = [:]

    /// One heading region's promotion trace.
    struct HeadingPromotion: Sendable, Equatable {
        let regionIndex: Int
        let kind: String
        let firstLineExcerpt: String
        let oldReadingOrder: Int
        let newReadingOrder: Int
        let topBodyMidY: Double
        let headingMidY: Double
    }

    /// Per-page record of `.text` regions Surya merged body+footnote
    /// into one chunk; we split them into a `.text` upper + `.footnote`
    /// lower based on a large internal gap + leading footnote marker.
    static var lastRegionSplitsPerPage: [Int: [RegionSplit]] = [:]

    /// Audit trace for one region split.
    struct RegionSplit: Sendable, Equatable {
        let originalRegionIndex: Int
        let upperKind: String
        let lowerKind: String
        let footnoteExcerpt: String
        let gap: Double
        let medianLineHeight: Double
    }

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
        lastHeadingPromotionsPerPage.removeAll(keepingCapacity: true)
        lastRegionSplitsPerPage.removeAll(keepingCapacity: true)
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
            // First: split any `.text` region where Surya merged
            // body + footnote(s) into one chunk. Those merged regions
            // can't be reclassified later because the upper half
            // (body) doesn't match any footnote signal — splitting
            // produces a separate lower `.footnote` region that the
            // downstream linker can pick up.
            let (afterSplit, splitDecisions) = splitTextRegionsAtFootnoteGap(
                regions: regions, observations: page.observations
            )
            if !splitDecisions.isEmpty {
                lastRegionSplitsPerPage[page.pageIndex] = splitDecisions
            }
            // Reclassify Surya `.text` regions that look like
            // footnotes — Surya often misses these and tags them as
            // body. Conservative heuristic (3 signals must agree)
            // documented on `reclassifyLikelyFootnotes`.
            let (afterFootnotes, fnDecisions) = reclassifyLikelyFootnotes(
                regions: afterSplit, observations: page.observations
            )
            if !fnDecisions.isEmpty {
                lastReclassificationsPerPage[page.pageIndex] = fnDecisions
            }
            // Now do the same for running heads / footers. Runs
            // *after* the footnote pass so a 1-line footnote in the
            // bottom 10% (already retagged to `.footnote`) won't be
            // re-grabbed as a `.pageFooter` and lose its popup.
            let (afterHF, hfDecisions) = reclassifyLikelyHeadersFooters(
                regions: afterFootnotes, observations: page.observations
            )
            if !hfDecisions.isEmpty {
                lastHFReclassificationsPerPage[page.pageIndex] = hfDecisions
            }
            // Repair Surya's reading order for `.title`/`.sectionHeader`
            // regions that sit visually above all body content but got
            // sorted to the back. Runs last so it operates on the
            // final region kinds.
            let (effectiveRegions, headingPromotions) = correctHeadingReadingOrder(
                regions: afterHF, observations: page.observations
            )
            if !headingPromotions.isEmpty {
                lastHeadingPromotionsPerPage[page.pageIndex] = headingPromotions
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

            // Pull observations once — needed both for the brevity
            // gate and the page-number-only fallback below.
            let inflated = region.box.insetBy(
                dx: -regionInflation, dy: -regionInflation
            )
            let inRegion = observations.filter { obs in
                inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
            }
            guard !inRegion.isEmpty else { continue }
            let totalChars = inRegion.reduce(0) { $0 + $1.text.count }
            let combinedText = inRegion
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Page-number bypass: if the region contains nothing but
            // a page number (digits, roman numerals, or short
            // decorations like "— 47 —"), reclassify regardless of
            // height. This catches Surya bundling a horizontal rule
            // with the page number into one taller region.
            let isPureNumeric = HeaderFooterClassifier.isPageNumberLike(combinedText)
            if !isPureNumeric {
                // Signal 2 (standard path): region height ≤ furniture threshold.
                guard region.box.height <= pageFurnitureMaxHeight else { continue }
                // Signal 3 (standard path): brevity cap.
                guard totalChars <= pageFurnitureMaxChars else { continue }
            }

            let firstObs = inRegion.max(by: { $0.box.midY < $1.box.midY })
            let excerpt = String((firstObs?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(60))

            // Signals all agree — reclassify.
            output[idx] = LayoutRegion(
                kind: targetKind,
                box: region.box,
                readingOrder: region.readingOrder,
                confidence: region.confidence
            )
            let signals: [String] = isPureNumeric
                ? [positionDesc, "page-number bypass: text=\"\(combinedText)\""]
                : [
                    positionDesc,
                    String(format: "height=%.3f ≤ %.2f", Double(region.box.height), Double(pageFurnitureMaxHeight)),
                    "chars=\(totalChars) ≤ \(pageFurnitureMaxChars)",
                ]
            decisions.append(Reclassification(
                regionIndex: idx,
                originalKind: region.kind.rawValue,
                newKind: targetKind.rawValue,
                firstLineExcerpt: excerpt,
                signals: signals
            ))
        }

        return (output, decisions)
    }

    // MARK: - region split at footnote gap

    /// Vertical gap (in units of median line height) within a `.text`
    /// region that triggers split consideration. A real paragraph has
    /// ~1× line gap; a body→footnote separator (with horizontal rule
    /// + visual padding) typically yields 2.5× or more.
    private static let regionSplitGapMultiplier: CGFloat = 2.5

    /// When Surya merges body content + footnote(s) into a single
    /// `.text` region (it occasionally misses the horizontal rule
    /// separator), the existing reclassifiers can't fix it because
    /// they operate per-region and the body part of the merged region
    /// doesn't match any footnote signal.
    ///
    /// Detect the merge by walking observations within each `.text`
    /// region top-to-bottom and looking for a vertical gap >
    /// `2.5 × median line height` whose bottom side starts with a
    /// footnote marker (`^\d{1,3}[.)\s]` or a symbolic marker). When
    /// found, split the region in two:
    ///
    ///   * upper: original kind (`.text`), bbox tight around the upper
    ///     observations, original reading order kept.
    ///   * lower: new `.footnote` region, bbox tight around the lower
    ///     observations, reading order = original (downstream
    ///     `bodyKinds` filter drops it from the body stream anyway).
    ///
    /// Conservative on purpose: requires both the gap signal AND the
    /// marker signal, the same dual gate as `reclassifyLikelyFootnotes`.
    /// A standalone footnote region (Surya did split correctly) is
    /// untouched — it has only one chunk, no internal gap to detect.
    static func splitTextRegionsAtFootnoteGap(
        regions: [LayoutRegion],
        observations: [TextObservation]
    ) -> (regions: [LayoutRegion], decisions: [RegionSplit]) {
        var output: [LayoutRegion] = []
        output.reserveCapacity(regions.count)
        var decisions: [RegionSplit] = []

        for (idx, region) in regions.enumerated() {
            guard region.kind == .text else {
                output.append(region)
                continue
            }
            let inflated = region.box.insetBy(
                dx: -regionInflation, dy: -regionInflation
            )
            // Observations within the region, sorted top-to-bottom
            // (highest midY first).
            let inRegion = observations
                .filter { obs in
                    inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
                }
                .sorted { $0.box.midY > $1.box.midY }
            guard inRegion.count >= 2 else {
                output.append(region)
                continue
            }
            let medianH = medianObservationHeight(in: inRegion)
            guard medianH > 0 else {
                output.append(region)
                continue
            }
            // Find largest gap between consecutive observations.
            var bestGap: CGFloat = 0
            var bestSplitAfter = -1  // index in inRegion where gap follows
            for i in 0..<(inRegion.count - 1) {
                let upper = inRegion[i]
                let lower = inRegion[i + 1]
                let gap = upper.box.minY - lower.box.maxY
                if gap > bestGap {
                    bestGap = gap
                    bestSplitAfter = i
                }
            }
            guard bestSplitAfter >= 0,
                  bestGap >= regionSplitGapMultiplier * medianH else {
                output.append(region)
                continue
            }
            // Footnote marker check on the first observation BELOW
            // the gap.
            let firstBelow = inRegion[bestSplitAfter + 1]
            let belowText = firstBelow.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard leadingFootnoteMarker(belowText) != nil else {
                output.append(region)
                continue
            }

            // Split. Compute tight bboxes from observations.
            let upperObs = Array(inRegion.prefix(bestSplitAfter + 1))
            let lowerObs = Array(inRegion.suffix(from: bestSplitAfter + 1))
            let upperBox = boundingBox(of: upperObs)
            let lowerBox = boundingBox(of: lowerObs)

            output.append(LayoutRegion(
                kind: .text, box: upperBox,
                readingOrder: region.readingOrder,
                confidence: region.confidence
            ))
            output.append(LayoutRegion(
                kind: .footnote, box: lowerBox,
                readingOrder: region.readingOrder,
                confidence: region.confidence
            ))
            decisions.append(RegionSplit(
                originalRegionIndex: idx,
                upperKind: "text",
                lowerKind: "footnote",
                footnoteExcerpt: String(belowText.prefix(60)),
                gap: Double(bestGap),
                medianLineHeight: Double(medianH)
            ))
        }
        return (output, decisions)
    }

    /// Tight bounding box around a group of observations. Returns
    /// `.zero` for an empty group.
    private static func boundingBox(of observations: [TextObservation]) -> CGRect {
        guard let first = observations.first else { return .zero }
        var minX = first.box.minX
        var minY = first.box.minY
        var maxX = first.box.maxX
        var maxY = first.box.maxY
        for o in observations.dropFirst() {
            minX = min(minX, o.box.minX)
            minY = min(minY, o.box.minY)
            maxX = max(maxX, o.box.maxX)
            maxY = max(maxY, o.box.maxY)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - heading reading-order correction

    /// Body-bearing kinds used to anchor "where the body content
    /// starts" on a page. Excludes captions because captions can
    /// legitimately sit above a heading (e.g. table caption that
    /// precedes a section break).
    private static let headingPromotionBodyAnchors: Set<LayoutRegion.Kind> = [
        .text, .listItem,
    ]

    /// Surya occasionally assigns a `.title`/`.sectionHeader` region
    /// at the top of the page a reading-order index that sorts AFTER
    /// the body content beneath it. The reflow output then renders
    /// the heading at the bottom of the page block, which is wrong
    /// for nearly every book layout.
    ///
    /// This pass rebuilds reading-order indices for headings that:
    ///
    ///   1. Are `.title` or `.sectionHeader`.
    ///   2. Sit visually above ALL body-anchor regions on the page
    ///      (`heading.midY > max(body.midY)`).
    ///
    /// Both conditions together guard mid-page section breaks (where
    /// the heading legitimately follows body content): such a heading
    /// will have body regions ABOVE it on the page and so fail the
    /// "above everything" gate.
    ///
    /// Promoted headings get reading-order indices placed before the
    /// minimum existing assigned order; multiple promoted headings
    /// keep their relative top-down order.
    static func correctHeadingReadingOrder(
        regions: [LayoutRegion],
        observations: [TextObservation]
    ) -> (regions: [LayoutRegion], promotions: [HeadingPromotion]) {
        // Need at least one body anchor to compare against; without
        // one (a page that's entirely headings + figures, say) the
        // existing reading order is the best we have.
        let bodyMidYs = regions
            .filter { headingPromotionBodyAnchors.contains($0.kind) }
            .map(\.box.midY)
        guard let topBodyMidY = bodyMidYs.max() else { return (regions, []) }

        // Headings that need promoting: above all body, and currently
        // ordered AT OR AFTER the topmost body region. (If Surya
        // already put the heading first, leave it alone.)
        let bodyMinOrder = regions
            .filter { headingPromotionBodyAnchors.contains($0.kind) }
            .compactMap { $0.readingOrder >= 0 ? $0.readingOrder : nil }
            .min() ?? Int.max
        var candidates: [(idx: Int, region: LayoutRegion)] = []
        for (idx, region) in regions.enumerated() {
            guard region.kind == .title || region.kind == .sectionHeader else { continue }
            guard region.box.midY > topBodyMidY else { continue }
            // Already ordered before body? Nothing to do.
            if region.readingOrder >= 0, region.readingOrder < bodyMinOrder {
                continue
            }
            candidates.append((idx, region))
        }
        guard !candidates.isEmpty else { return (regions, []) }

        // Sort top-down (highest midY first) so multiple stacked
        // headings keep their visual order.
        candidates.sort { $0.region.box.midY > $1.region.box.midY }

        // The existing sort in `reflowPage` treats negative reading
        // orders as "unassigned, sort last", so we must use positive
        // integers smaller than the current minimum positive order.
        // Shift every existing positive order up by `count` to free
        // up [0..count-1] for the promoted headings.
        let count = candidates.count
        var output = regions
        for (i, r) in regions.enumerated() {
            if r.readingOrder >= 0 {
                output[i] = LayoutRegion(
                    kind: r.kind, box: r.box,
                    readingOrder: r.readingOrder + count,
                    confidence: r.confidence
                )
            }
        }
        var promotions: [HeadingPromotion] = []
        for (offset, entry) in candidates.enumerated() {
            let newOrder = offset  // 0, 1, 2, … in top-down order
            let r = entry.region
            output[entry.idx] = LayoutRegion(
                kind: r.kind, box: r.box,
                readingOrder: newOrder,
                confidence: r.confidence
            )
            // First-line excerpt for the audit log. Mirrors the
            // pattern used by the other reclassifiers.
            let inflated = r.box.insetBy(dx: -regionInflation, dy: -regionInflation)
            let inRegion = observations.filter { obs in
                inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
            }
            let firstObs = inRegion.max(by: { $0.box.midY < $1.box.midY })
            let excerpt = String((firstObs?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(60))
            promotions.append(HeadingPromotion(
                regionIndex: entry.idx,
                kind: r.kind.rawValue,
                firstLineExcerpt: excerpt,
                oldReadingOrder: r.readingOrder,
                newReadingOrder: newOrder,
                topBodyMidY: Double(topBodyMidY),
                headingMidY: Double(r.box.midY)
            ))
        }
        return (output, promotions)
    }
}
