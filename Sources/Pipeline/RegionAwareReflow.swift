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

    struct AttributionInfo: Sendable, Equatable {
        let regionReadingOrder: Int
        let regionKind: String
    }

    /// Per-pass diagnostic accumulator. Was previously a set of static
    /// vars on `RegionAwareReflow` (`lastAttributions`,
    /// `lastFootnotesPerPage`, etc.), which Swift 6 strict mode
    /// rejects as nonisolated global mutable state. Returning the
    /// diagnostics by value lets the debug-log writer in
    /// `PDFToEPUBPipeline.writeDebugLog` consume them through normal
    /// parameter passing without any shared state.
    ///
    /// Empty when reflow ran without any pages contributing to the
    /// corresponding category (e.g. a book with no `.footnote`
    /// regions has `footnotesPerPage = [:]`).
    struct Diagnostics: Sendable, Equatable {
        var attributions: [ObservationKey: AttributionInfo] = [:]
        var footnotesPerPage: [Int: [FootnoteLinker.Parsed]] = [:]
        var reclassificationsPerPage: [Int: [Reclassification]] = [:]
        var hfReclassificationsPerPage: [Int: [Reclassification]] = [:]
        var headingPromotionsPerPage: [Int: [HeadingPromotion]] = [:]
        var regionSplitsPerPage: [Int: [RegionSplit]] = [:]
        var crossPageDecisionsPerPage: [Int: [CrossPageDecision]] = [:]
    }

    /// Output of one reflow pass: the body block stream plus the
    /// chapter-level footnote collection that body runs reference via
    /// `InlineRun.noterefId`. Footnotes only get populated when the
    /// layout analyzer found `.footnote` regions. `figureAssets`
    /// carries any image bytes referenced by `Block.figure` blocks.
    /// `diagnostics` carries debug-log telemetry; callers that don't
    /// emit a debug log can ignore it.
    struct Result: Sendable, Equatable {
        let blocks: [Block]
        let footnotes: [Footnote]
        let pageAnchors: [PageAnchor]
        let figureAssets: [FigureAsset]
        var diagnostics: Diagnostics = Diagnostics()
    }

    /// Anchor id format. `EditorViewModel`'s linked-navigation feature
    /// looks for `[id^="hu-page-"]` in the rendered XHTML, so this
    /// prefix is load-bearing — change in both places if changed.
    static func anchorId(forPageIndex pageIndex: Int) -> String {
        "hu-page-\(pageIndex)"
    }

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

    /// Audit trace for one typographic promotion. Computed during
    /// `promoteTypographicHeadings` but no longer surfaced in the
    /// debug log (kept as a type so the helper's return value still
    /// has structure; callers that don't read it pay nothing).
    struct TypographicPromotion: Sendable, Equatable {
        let regionIndex: Int
        let promotedTo: String   // ".sectionHeader" or ".title"
        let firstLineExcerpt: String
        let medianLineHeight: Double
        let pageMedianLineHeight: Double
        let isCentered: Bool
        let isAllCaps: Bool
        let charCount: Int
    }

    /// Audit trace for one cross-page recurrence decision.
    struct CrossPageDecision: Sendable, Equatable {
        let regionIndex: Int
        let originalKind: String
        let newKind: String
        let firstLineExcerpt: String
        let normalizedText: String
        let recurrenceCount: Int  // distinct pages this normalized text appeared on
    }

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

    static func reflow(
        pageResults: [PageObservations],
        figureExtractions: [Int: [FigureExtractor.ExtractedFigure]] = [:],
        tableExtractions: [CaptionAssociator.PageRegionKey: [[TableCell]]] = [:],
        mathExtractions: [CaptionAssociator.PageRegionKey: String] = [:],
        captionAssociations: CaptionAssociator.Associations = CaptionAssociator.Associations(
            captionByFigure: [:], orientation: .below
        )
    ) -> Result {
        // Per-pass diagnostics. Was previously seven `static var lastXxx`
        // dictionaries on this type, which Swift 6 strict mode flags
        // as nonisolated global mutable state. Bundling them into a
        // local value passed by `inout` to helpers keeps the data
        // local to one reflow call and removes the shared state
        // entirely.
        var diagnostics = Diagnostics()

        // Cover is sourced from a rendered raster of PDF page 0,
        // injected by `PDFToEPUBPipeline.convert` after this reflow
        // pass returns. No body figure carries `isCover` here — the
        // page-0 raster is unconditional and stamps the cover-image
        // property on its own dedicated FigureAsset downstream.

        // Reverse the caption→figure index for fast lookup during
        // reflow: when we hit a caption region, we want to know
        // whether some figure already claimed it.
        var captionsClaimed = Set<CaptionAssociator.PageRegionKey>()
        for cap in captionAssociations.captionByFigure.values {
            captionsClaimed.insert(cap)
        }

        // Assign book-wide unique asset ids in document order. The id
        // is the manifest item id and the filename stem.
        var assetIdByFigureKey: [CaptionAssociator.PageRegionKey: String] = [:]
        var figureAssets: [FigureAsset] = []
        var nextAssetIndex = 0
        for page in pageResults.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            guard let figures = figureExtractions[page.pageIndex] else { continue }
            for fig in figures {
                let assetId = String(format: "fig-%05d", nextAssetIndex)
                nextAssetIndex += 1
                let key = CaptionAssociator.PageRegionKey(
                    pageIndex: page.pageIndex, regionIndex: fig.regionIndex
                )
                assetIdByFigureKey[key] = assetId
                figureAssets.append(FigureAsset(
                    id: assetId,
                    data: fig.data,
                    mediaType: fig.mediaType,
                    intrinsicSize: fig.intrinsicSize,
                    isCover: false
                ))
            }
        }

        // Document-level pass: classify edge-of-page short `.text`
        // regions using cross-page recurrence. Top zone:
        // recurring → `.pageHeader` (running head, drop from body);
        // unique → `.sectionHeader` (chapter title Surya missed).
        // Bottom zone (symmetric, recurring-only): recurring →
        // `.pageFooter`; unique stays untouched (a unique short
        // bottom-of-page string is more likely a footnote stub or
        // decorative line than a heading).
        let topOverrides = classifyEdgeRegionsByRecurrence(
            pageResults: pageResults, zone: .top
        )
        let bottomOverrides = classifyEdgeRegionsByRecurrence(
            pageResults: pageResults, zone: .bottom
        )
        let crossPageOverrides = mergeCrossPageOverrides(
            topOverrides, bottomOverrides
        )
        for (pageIdx, decisions) in crossPageOverrides.decisionsByPage {
            diagnostics.crossPageDecisionsPerPage[pageIdx] = decisions
        }

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
            guard let originalRegions = page.layoutRegions, !originalRegions.isEmpty else {
                blocks.append(contentsOf: heuristicFallback(for: page))
                continue
            }
            // Apply the document-level cross-page overrides first so
            // downstream passes (split + footnote/HF reclassifiers +
            // heading reading-order) see the corrected kinds.
            var regions = originalRegions
            if let overrides = crossPageOverrides.overridesByPage[page.pageIndex] {
                for (regionIdx, newKind) in overrides {
                    let r = regions[regionIdx]
                    regions[regionIdx] = LayoutRegion(
                        kind: newKind,
                        box: r.box,
                        readingOrder: r.readingOrder,
                        confidence: r.confidence
                    )
                }
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
                diagnostics.regionSplitsPerPage[page.pageIndex] = splitDecisions
            }
            // Reclassify Surya `.text` regions that look like
            // footnotes — Surya often misses these and tags them as
            // body. Conservative heuristic (3 signals must agree)
            // documented on `reclassifyLikelyFootnotes`.
            let (afterFootnotes, fnDecisions) = reclassifyLikelyFootnotes(
                regions: afterSplit, observations: page.observations
            )
            if !fnDecisions.isEmpty {
                diagnostics.reclassificationsPerPage[page.pageIndex] = fnDecisions
            }
            // Now do the same for running heads / footers. Runs
            // *after* the footnote pass so a 1-line footnote in the
            // bottom 10% (already retagged to `.footnote`) won't be
            // re-grabbed as a `.pageFooter` and lose its popup.
            let (afterHF, hfDecisions) = reclassifyLikelyHeadersFooters(
                regions: afterFootnotes, observations: page.observations
            )
            if !hfDecisions.isEmpty {
                diagnostics.hfReclassificationsPerPage[page.pageIndex] = hfDecisions
            }
            // Promote `.text` regions whose geometry + content look
            // like chapter titles or section headers (larger font +
            // short + centered or all-caps). Catches one-off
            // chapter openers Surya misclassified as body. Runs
            // before reading-order repair so newly-promoted headings
            // participate in the same reading-order fix.
            let (afterTypographic, typographicDecisions) =
                promoteTypographicHeadings(
                    regions: afterHF, observations: page.observations
                )
            // Typographic decisions are computed for their structural
            // effects (the regions are reclassified in `afterTypographic`)
            // but no longer surfaced separately in the debug log.
            _ = typographicDecisions
            // Repair Surya's reading order for `.title`/`.sectionHeader`
            // regions that sit visually above all body content but got
            // sorted to the back. Runs last so it operates on the
            // final region kinds.
            let (effectiveRegions, headingPromotions) = correctHeadingReadingOrder(
                regions: afterTypographic, observations: page.observations
            )
            if !headingPromotions.isEmpty {
                diagnostics.headingPromotionsPerPage[page.pageIndex] = headingPromotions
            }
            let pageFootnotes = FootnoteLinker.parseFootnotes(
                pageIndex: page.pageIndex,
                observations: page.observations,
                regions: effectiveRegions
            )
            if !pageFootnotes.isEmpty {
                diagnostics.footnotesPerPage[page.pageIndex] = pageFootnotes
                allFootnotes.append(contentsOf: pageFootnotes)
            }
            blocks.append(contentsOf: reflowPage(
                page: page,
                originalRegions: originalRegions,
                regions: effectiveRegions,
                pageFootnotes: pageFootnotes,
                assetIdByFigureKey: assetIdByFigureKey,
                captionByFigure: captionAssociations.captionByFigure,
                captionsClaimed: captionsClaimed,
                tableExtractions: tableExtractions,
                mathExtractions: mathExtractions,
                diagnostics: &diagnostics
            ))
        }
        let bridged = PDFToEPUBPipeline.bridgeBoundaries(blocks)
        return Result(
            blocks: bridged,
            footnotes: FootnoteLinker.footnotesForChapter(allFootnotes),
            pageAnchors: pageAnchors,
            figureAssets: figureAssets,
            diagnostics: diagnostics
        )
    }

    // `detectCoverFigure` (page-0 dominant-picture heuristic) was
    // removed when the cover source moved to a rendered raster of
    // PDF page 0, injected by `PDFToEPUBPipeline.convert` after
    // reflow. The new path is unconditional and works for text-
    // only first pages; the heuristic was conservative and rarely
    // fired in practice. Git history preserves the impl if a
    // hybrid path ever wants to come back.

    private static func heuristicFallback(for page: PageObservations) -> [Block] {
        ParagraphReflow().reflow(page.observations)
    }

    /// Find the index of `region` within `originalRegions`. Picture /
    /// caption / formula regions are passed through unmodified by
    /// every pre-pass, so an exact `kind == kind && box == box` match
    /// uniquely identifies the original region. Returns nil if no
    /// match (shouldn't happen in practice).
    private static func matchOriginalRegionIndex(
        region: LayoutRegion, in originalRegions: [LayoutRegion]
    ) -> Int? {
        originalRegions.firstIndex {
            $0.kind == region.kind && $0.box == region.box
        }
    }

    /// Build the inline runs for a figure's caption by extracting text
    /// from the matched caption region's observations. Returns an
    /// empty array when no caption is associated.
    private static func captionRuns(
        for figureKey: CaptionAssociator.PageRegionKey,
        captionByFigure: [CaptionAssociator.PageRegionKey: CaptionAssociator.PageRegionKey],
        originalRegions: [LayoutRegion],
        observations: [TextObservation],
        pageFootnotes: [FootnoteLinker.Parsed]
    ) -> [InlineRun] {
        guard let captionKey = captionByFigure[figureKey] else { return [] }
        guard captionKey.regionIndex >= 0,
              captionKey.regionIndex < originalRegions.count else { return [] }
        let captionRegion = originalRegions[captionKey.regionIndex]
        let inflated = captionRegion.box.insetBy(
            dx: -regionInflation, dy: -regionInflation
        )
        let inRegion = observations.filter { obs in
            inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
        }
        guard !inRegion.isEmpty else { return [] }
        let sorted = inRegion.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > 0.005 { return a.box.midY > b.box.midY }
            return a.box.minX < b.box.minX
        }
        let text = joinWithDehyphenation(sorted.map(\.text))
        guard !text.isEmpty else { return [] }
        // Captions can carry footnote markers (rare, but possible);
        // run them through the same splicer so a noteref in a caption
        // links correctly.
        return FootnoteLinker.splice(text: text, footnotes: pageFootnotes)
    }

    /// Pick alt text for a figure. Use the caption text when available
    /// — accessibility readers will read it; otherwise a generic
    /// "figure" / "formula" label.
    private static func altText(
        forKind kind: LayoutRegion.Kind, captionRuns: [InlineRun]
    ) -> String {
        let captionText = captionRuns.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !captionText.isEmpty { return captionText }
        return kind == .formula ? "formula" : "figure"
    }

    private static func reflowPage(
        page: PageObservations,
        originalRegions: [LayoutRegion],
        regions: [LayoutRegion],
        pageFootnotes: [FootnoteLinker.Parsed],
        assetIdByFigureKey: [CaptionAssociator.PageRegionKey: String],
        captionByFigure: [CaptionAssociator.PageRegionKey: CaptionAssociator.PageRegionKey],
        captionsClaimed: Set<CaptionAssociator.PageRegionKey>,
        tableExtractions: [CaptionAssociator.PageRegionKey: [[TableCell]]],
        mathExtractions: [CaptionAssociator.PageRegionKey: String],
        diagnostics: inout Diagnostics
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
            // Pictures and formulas: emit `Block.figure` if we have an
            // extracted asset for them. Pre-passes don't modify these
            // regions, so finding the asset key by box+kind match
            // against `originalRegions` is unique.
            //
            // P-Math-Cascade. When the cascade math extractor produced
            // a MathML transcription for a `.formula` region, emit a
            // paragraph with the raw MathML *in place of* the figure
            // raster. EPUB 3 readers render MathML natively, and
            // dropping the rastered image cleans up the chapter
            // visually (no double-emission of equation-as-image
            // alongside equation-as-math). The figure asset is still
            // built upstream (we don't bother filtering it out of
            // `figureAssets` since unreferenced assets aren't emitted
            // to disk anyway — chapter splitting drops unreferenced
            // assets in the manifest step).
            if region.kind == .picture || region.kind == .formula {
                if let originalIdx = matchOriginalRegionIndex(
                    region: region, in: originalRegions
                ) {
                    let key = CaptionAssociator.PageRegionKey(
                        pageIndex: page.pageIndex, regionIndex: originalIdx
                    )
                    if region.kind == .formula,
                       let mathML = mathExtractions[key],
                       !mathML.isEmpty {
                        // Plain-text fallback for sibling .txt / .md
                        // outputs (which don't render MathML): the
                        // associated caption if any, else "[formula]".
                        let captionRuns = captionRuns(
                            for: key,
                            captionByFigure: captionByFigure,
                            originalRegions: originalRegions,
                            observations: page.observations,
                            pageFootnotes: pageFootnotes
                        )
                        let fallback = captionRuns.map(\.text).joined()
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                            ? "[formula]"
                            : captionRuns.map(\.text).joined()
                        blocks.append(.paragraph(runs: [
                            InlineRun(fallback, rawXHTML: mathML)
                        ]))
                        continue
                    }
                    if let assetId = assetIdByFigureKey[key] {
                        let captionRuns = captionRuns(
                            for: key,
                            captionByFigure: captionByFigure,
                            originalRegions: originalRegions,
                            observations: page.observations,
                            pageFootnotes: pageFootnotes
                        )
                        let alt = altText(forKind: region.kind, captionRuns: captionRuns)
                        blocks.append(.figure(
                            assetId: assetId, alt: alt, caption: captionRuns
                        ))
                    }
                }
                continue
            }

            // Tables: prefer the Surya table model's structured output
            // when the pipeline pre-pass produced one for this region;
            // otherwise fall back to the Y/X clustering heuristic.
            // Either way, mark observations inside the region as
            // `claimed` so body regions can't double-emit them.
            //
            // If both paths reject (Surya wasn't available + heuristic
            // grid too sparse), the region falls through to the
            // paragraph emission path below — better than dropping
            // the text entirely.
            if region.kind == .table {
                let inflated = region.box.insetBy(dx: -regionInflation, dy: -regionInflation)
                var inRegion: [TextObservation] = []
                var inRegionIdx: [Int] = []
                for (idx, obs) in page.observations.enumerated() {
                    if claimed.contains(idx) { continue }
                    let cx = obs.box.midX
                    let cy = obs.box.midY
                    if inflated.contains(CGPoint(x: cx, y: cy)) {
                        inRegion.append(obs)
                        inRegionIdx.append(idx)
                    }
                }

                let originalIdx = matchOriginalRegionIndex(
                    region: region, in: originalRegions
                )
                let regionKey = originalIdx.map {
                    CaptionAssociator.PageRegionKey(
                        pageIndex: page.pageIndex, regionIndex: $0
                    )
                }

                // Path A: Surya table-rec preferred when available.
                let suryaRows: [[TableCell]]? = regionKey.flatMap {
                    tableExtractions[$0]
                }
                let chosenRows = suryaRows
                    ?? TableHeuristic.extract(observations: inRegion)

                if let rows = chosenRows {
                    for idx in inRegionIdx { claimed.insert(idx) }
                    let captionRuns: [InlineRun]
                    if let key = regionKey {
                        captionRuns = self.captionRuns(
                            for: key,
                            captionByFigure: captionByFigure,
                            originalRegions: originalRegions,
                            observations: page.observations,
                            pageFootnotes: pageFootnotes
                        )
                    } else {
                        captionRuns = []
                    }
                    blocks.append(.table(rows: rows, caption: captionRuns))
                    continue
                }
                // Both paths rejected — fall through to the paragraph
                // path below so the user still sees the text.
            }

            // Captions matched to a figure are emitted as part of that
            // figure block — skip them here so they don't double-emit
            // as paragraphs. Unmatched captions fall through to the
            // standard paragraph path.
            if region.kind == .caption,
               let originalIdx = matchOriginalRegionIndex(
                   region: region, in: originalRegions
               ) {
                let key = CaptionAssociator.PageRegionKey(
                    pageIndex: page.pageIndex, regionIndex: originalIdx
                )
                if captionsClaimed.contains(key) { continue }
            }

            // `.table` regions whose heuristic rejected fall through
            // here so the user still sees the contents as paragraph
            // text rather than losing it.
            guard bodyKinds.contains(region.kind) || region.kind == .table else { continue }
            let inflated = region.box.insetBy(dx: -regionInflation, dy: -regionInflation)
            var assigned: [TextObservation] = []
            for (idx, obs) in page.observations.enumerated() {
                if claimed.contains(idx) { continue }
                let cx = obs.box.midX
                let cy = obs.box.midY
                guard inflated.contains(CGPoint(x: cx, y: cy)) else { continue }
                assigned.append(obs)
                claimed.insert(idx)
                diagnostics.attributions[
                    ObservationKey(pageIndex: page.pageIndex, observationIndex: idx)
                ] = AttributionInfo(
                    regionReadingOrder: region.readingOrder,
                    regionKind: region.kind.rawValue
                )
            }
            guard !assigned.isEmpty else { continue }

            // Surya occasionally bundles both columns of a 2-column
            // page into a single body region. When that happens the
            // straight Y/X sort below produces row-by-row reading
            // ("left col line 1, right col line 1, left col line 2, …")
            // — i.e. the columns get scrambled. Run `ColumnSplitter` on
            // wide `.text` regions so a clear gutter inside the region
            // splits the observations into per-column groups before
            // they're stitched into text. The width gate keeps this
            // off legitimate single-column regions whose Surya bbox is
            // narrower than ~60% of the page width.
            let assignedGroups: [[TextObservation]]
            if region.kind == .text, region.box.width > 0.6 {
                assignedGroups = ColumnSplitter().split(assigned)
            } else {
                assignedGroups = [assigned]
            }
            for group in assignedGroups {
                // Sort top-to-bottom then left-to-right within the group.
                let sorted = group.sorted { a, b in
                    if abs(a.box.midY - b.box.midY) > 0.005 { return a.box.midY > b.box.midY }
                    return a.box.minX < b.box.minX
                }

                // P-Verse-Layout: before reflowing into a prose
                // paragraph, run the high-precision verse
                // classifier on the group. When it fires, emit
                // Block.verse with the line-by-line geometry
                // preserved. Only `.text` regions are eligible —
                // headings, captions, list items, page headers /
                // footers / footnotes have their own emission
                // semantics that shouldn't get caught up here.
                if region.kind == .text,
                   let verdict = VerseDetector.detect(
                       observations: sorted,
                       regionBox: region.box
                   ) {
                    blocks.append(.verse(lines: verdict.lines))
                    continue
                }

                // Join with soft-hyphen-aware concatenation.
                let text = joinWithDehyphenation(sorted.map(\.text))
                guard !text.isEmpty else { continue }

                blocks.append(blockForRegion(
                    kind: region.kind,
                    text: text,
                    observations: sorted,
                    pageFootnotes: pageFootnotes
                ))
            }
        }
        return blocks
    }

    private static func blockForRegion(
        kind: LayoutRegion.Kind,
        text: String,
        observations: [TextObservation],
        pageFootnotes: [FootnoteLinker.Parsed]
    ) -> Block {
        // Strict consensus on emphasis: every observation in the
        // region must agree before the run inherits the flag.
        // Avoids false-positive bolding/italicizing of an entire
        // paragraph when one Tesseract word came back styled
        // (Tesseract's font-trait detection is per-word, so a
        // single mis-detection would otherwise propagate up).
        let italic = !observations.isEmpty && observations.allSatisfy(\.isItalic)
        let bold = !observations.isEmpty && observations.allSatisfy(\.isBold)
        switch kind {
        // Headings shouldn't carry footnote references — keep them as
        // a single plain run to avoid linker false positives in title
        // text like a chapter number.
        case .title:
            return .heading(level: 1, runs: [
                InlineRun(text, isItalic: italic, isBold: bold)
            ])
        case .sectionHeader:
            return .heading(level: 2, runs: [
                InlineRun(text, isItalic: italic, isBold: bold)
            ])
        // listItem keeps its inline marker ("1.", "2.", "•") because
        // Surya doesn't strip it; the EPUB renders this as a paragraph
        // beginning with the marker — fine for now, real <ol>/<ul>
        // markup is a later refinement.
        case .listItem:
            return .paragraph(runs: FootnoteLinker.splice(
                text: text,
                footnotes: pageFootnotes,
                isItalic: italic, isBold: bold
            ))
        case .caption:
            return .paragraph(runs: FootnoteLinker.splice(
                text: text,
                footnotes: pageFootnotes,
                isItalic: italic, isBold: bold
            ))
        case .text, .pageHeader, .pageFooter, .footnote,
             .picture, .table, .formula, .other:
            return .paragraph(runs: FootnoteLinker.splice(
                text: text,
                footnotes: pageFootnotes,
                isItalic: italic, isBold: bold
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

    // MARK: - typographic heading promotion

    /// A region's median line height must exceed the page median by
    /// this multiplier to count as a "larger font" cue.
    private static let typographicLargerFontMultiplier: CGFloat = 1.4
    /// Region's horizontal center can be off the page center by at
    /// most this fraction (each side) and still count as centered.
    private static let typographicCenterTolerance: CGFloat = 0.06
    /// Centered region's width must be less than this fraction of
    /// the body width to count as centered (pure centering of a
    /// full-width line is meaningless — it's just regular justified
    /// text).
    private static let typographicCenteredMaxWidth: CGFloat = 0.75
    /// Maximum text length for a region to be promoted. Real chapter
    /// titles are short.
    private static let typographicMaxChars: Int = 80
    /// At least this many alphabetic characters before all-caps
    /// detection fires — single letters / acronyms shouldn't count.
    private static let typographicAllCapsMinAlpha: Int = 3

    /// Walk the region list and promote `.text` regions to
    /// `.sectionHeader` (or `.title`) when their geometry + content
    /// look like a heading, even though Surya tagged them as body.
    /// Same intent as the cross-page recurrence pass but driven by
    /// per-page typographic cues rather than cross-page repetition;
    /// catches one-off chapter openers + section breaks.
    ///
    /// Promotion fires when **all** of:
    ///   1. Region's median line height > page median × 1.4
    ///   2. Total text ≤ 80 characters
    ///   3. Either centered (width < 75% of body, midX within 6% of
    ///      page center) OR all-uppercase (no lowercase letters,
    ///      ≥ 3 alphabetic chars).
    ///
    /// **Italics are explicitly NOT a signal here** — per
    /// PLANS-discussion they produce too many false positives as
    /// chapter cues. Italics propagate as inline emphasis instead.
    ///
    /// Promotion target: `.title` when median line height >
    /// page median × 1.8 (very tall — typically chapter opener);
    /// otherwise `.sectionHeader`.
    static func promoteTypographicHeadings(
        regions: [LayoutRegion],
        observations: [TextObservation]
    ) -> (regions: [LayoutRegion], decisions: [TypographicPromotion]) {
        // Page-level baseline: median line height across all
        // observations. A typical body line is the mode here; chapter
        // titles will sit well above the median.
        let allHeights = observations.map(\.box.height).filter { $0 > 0 }
        guard !allHeights.isEmpty else { return (regions, []) }
        let pageMedian = median(allHeights)

        // Body-width baseline for the centering check: max region
        // width across `.text` regions. Chapter titles centered on a
        // narrower-than-body line should look short relative to this.
        let bodyWidth = regions
            .filter { $0.kind == .text }
            .map(\.box.width)
            .max() ?? 1

        var output = regions
        var decisions: [TypographicPromotion] = []

        for (idx, region) in regions.enumerated() {
            guard region.kind == .text else { continue }

            // Pull the region's observations.
            let inflated = region.box.insetBy(
                dx: -regionInflation, dy: -regionInflation
            )
            let inRegion = observations.filter { obs in
                inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
            }
            guard !inRegion.isEmpty else { continue }

            // Length gate.
            let text = inRegion
                .sorted { $0.box.midY > $1.box.midY }
                .map(\.text)
                .joined(separator: " ")
            let charCount = text.count
            guard charCount > 0, charCount <= typographicMaxChars else {
                continue
            }

            // Font-size signal.
            let regionHeights = inRegion.map(\.box.height).filter { $0 > 0 }
            guard !regionHeights.isEmpty else { continue }
            let regionMedian = median(regionHeights)
            guard regionMedian > pageMedian * typographicLargerFontMultiplier else {
                continue
            }

            // Centering signal: region midX near 0.5, region width
            // less than the body-width fraction.
            let isCentered =
                abs(region.box.midX - 0.5) <= typographicCenterTolerance
                && region.box.width < bodyWidth * typographicCenteredMaxWidth

            // All-caps signal: no lowercase letters in alphabetic
            // characters, with a minimum letter count.
            let isAllCaps = Self.isLikelyAllCaps(text)

            guard isCentered || isAllCaps else { continue }

            // Promote. Tall regions become titles; smaller heading-
            // sized regions become section headers.
            let promotedKind: LayoutRegion.Kind = regionMedian
                > pageMedian * 1.8 ? .title : .sectionHeader
            output[idx] = LayoutRegion(
                kind: promotedKind,
                box: region.box,
                readingOrder: region.readingOrder,
                confidence: region.confidence
            )
            decisions.append(TypographicPromotion(
                regionIndex: idx,
                promotedTo: promotedKind == .title ? ".title" : ".sectionHeader",
                firstLineExcerpt: String(text.prefix(60)),
                medianLineHeight: Double(regionMedian),
                pageMedianLineHeight: Double(pageMedian),
                isCentered: isCentered,
                isAllCaps: isAllCaps,
                charCount: charCount
            ))
        }

        return (output, decisions)
    }

    /// True if `text` has at least `typographicAllCapsMinAlpha`
    /// alphabetic characters AND none of them are lowercase. Allows
    /// numbers, punctuation, whitespace freely — chapter titles like
    /// "CHAPTER 3" or "PART II" should pass.
    private static func isLikelyAllCaps(_ text: String) -> Bool {
        var alphaCount = 0
        for ch in text {
            if ch.isLetter {
                alphaCount += 1
                if ch.isLowercase { return false }
            }
        }
        return alphaCount >= typographicAllCapsMinAlpha
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
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

    // MARK: - cross-page recurrence classification

    /// Edge zone the cross-page recurrence pass operates on. Top-zone
    /// runs first (existing behavior — recurring → `.pageHeader`,
    /// unique → `.sectionHeader`); bottom-zone is symmetric on the
    /// recurring side (recurring → `.pageFooter`) but does NOT promote
    /// unique bottom-zone text to a heading — short unique strings at
    /// the bottom of a page are typically page-furniture stubs, not
    /// section breaks.
    enum CrossPageZone: Sendable, Equatable {
        case top
        case bottom
    }

    /// A `.text` region's vertical center must be at least this high
    /// to be considered a top-zone candidate. Top 15% — slightly
    /// looser than the H/F gate's 10% so we catch section headers
    /// that sit a touch lower on the page (with a small visual gap
    /// above).
    private static let crossPageTopZoneMinY: CGFloat = 0.85
    /// Symmetric bottom-zone gate: `midY <= 0.15`. Catches recurring
    /// running footers like "Stoicheia I.iii" or chapter-bottom
    /// labels Surya labeled as `.text`.
    private static let crossPageBottomZoneMaxY: CGFloat = 0.15
    /// Region must be at most this tall to be a candidate. Real
    /// running heads / footers + chapter section titles fit in a
    /// couple of lines; body paragraphs that graze either edge zone
    /// exceed this.
    private static let crossPageMaxRegionHeight: CGFloat = 0.06
    /// Combined text length cap. Section headers and running
    /// heads / footers are short; body content is long.
    private static let crossPageMaxChars: Int = 100
    /// Cluster size (distinct pages with matching normalized text)
    /// at which we consider a candidate a running head/footer and
    /// demote it. Anything below threshold in the top zone is treated
    /// as section-header content; below threshold in the bottom zone
    /// is left alone.
    private static let crossPageRunningHeadMinPages: Int = 3
    /// Document must have at least this many pages with regions for
    /// the cross-page pass to do anything. Below this we don't have
    /// enough signal to distinguish recurring from unique.
    private static let crossPageMinDocumentPages: Int = 3

    /// Output of `classifyEdgeRegionsByRecurrence` — keyed by page,
    /// `overridesByPage[pageIdx]` maps regionIndex → newKind.
    /// `decisionsByPage` carries the audit trail for the debug log.
    struct CrossPageOverrides {
        var overridesByPage: [Int: [Int: LayoutRegion.Kind]]
        var decisionsByPage: [Int: [CrossPageDecision]]
    }

    /// Combine two `CrossPageOverrides` (one per zone). Top + bottom
    /// operate on disjoint y-bands so region-index collisions
    /// shouldn't happen in practice; on a collision the second
    /// argument wins for the override and both decisions are
    /// preserved in the audit trail.
    static func mergeCrossPageOverrides(
        _ a: CrossPageOverrides, _ b: CrossPageOverrides
    ) -> CrossPageOverrides {
        var overridesByPage = a.overridesByPage
        for (pageIdx, perPage) in b.overridesByPage {
            for (regionIdx, kind) in perPage {
                overridesByPage[pageIdx, default: [:]][regionIdx] = kind
            }
        }
        var decisionsByPage = a.decisionsByPage
        for (pageIdx, decisions) in b.decisionsByPage {
            decisionsByPage[pageIdx, default: []].append(contentsOf: decisions)
        }
        return CrossPageOverrides(
            overridesByPage: overridesByPage,
            decisionsByPage: decisionsByPage
        )
    }

    /// Convenience: top-zone-only invocation, kept so callers that
    /// only want the heading/running-head split don't have to specify
    /// a zone. Equivalent to `classifyEdgeRegionsByRecurrence(
    /// pageResults:zone: .top)`.
    static func classifyTopRegionsByRecurrence(
        pageResults: [PageObservations]
    ) -> CrossPageOverrides {
        classifyEdgeRegionsByRecurrence(pageResults: pageResults, zone: .top)
    }

    /// Document-level scan: identify `.text` regions that look like
    /// running-heads / running-footers / section-headers (in the
    /// requested edge zone, short, brief text), and decide which is
    /// which using cross-page recurrence.
    ///
    /// Why this exists: Surya often labels both running heads/footers
    /// and section headers as `.text`. Local heuristics can't tell
    /// them apart — both look similar on a single page. The
    /// discriminator is recurrence: running heads/footers repeat (in
    /// the same y-band) on many pages of a section; chapter titles
    /// appear on exactly one.
    ///
    /// Algorithm:
    ///   1. Collect all candidate regions in the requested edge zone
    ///      across all pages.
    ///   2. Normalize each candidate's text via the same digit-
    ///      collapsing rule HeaderFooterClassifier uses (so
    ///      "Chapter 3 Foo 47" and "Chapter 3 Foo 48" cluster).
    ///   3. Cluster candidates by normalized text.
    ///   4. For each cluster:
    ///        - Top zone, ≥ 3 pages → `.pageHeader`. < 3 pages →
    ///          `.sectionHeader` (promote unique top text to heading).
    ///        - Bottom zone, ≥ 3 pages → `.pageFooter`. < 3 pages →
    ///          no override (we don't promote unique bottom-zone text
    ///          to a heading; it's usually a footnote stub or
    ///          decorative line).
    ///
    /// Conservative defaults: short documents (< 3 pages) skip the
    /// pass entirely — too little data to discriminate. Cluster
    /// threshold tuneable if running-head/footer false positives
    /// surface.
    static func classifyEdgeRegionsByRecurrence(
        pageResults: [PageObservations],
        zone: CrossPageZone
    ) -> CrossPageOverrides {
        let pagesWithRegions = pageResults.filter { ($0.layoutRegions?.isEmpty == false) }
        guard pagesWithRegions.count >= crossPageMinDocumentPages else {
            return CrossPageOverrides(overridesByPage: [:], decisionsByPage: [:])
        }

        // Per-candidate record so we can apply overrides + log decisions.
        struct Candidate {
            let pageIndex: Int
            let regionIndex: Int
            let originalKind: LayoutRegion.Kind
            let normalizedText: String
            let firstLineExcerpt: String
        }

        // Bucket by normalized text → list of candidates.
        var byNormalized: [String: [Candidate]] = [:]
        for page in pagesWithRegions {
            guard let regions = page.layoutRegions else { continue }
            for (idx, region) in regions.enumerated() {
                guard region.kind == .text else { continue }
                switch zone {
                case .top:
                    guard region.box.midY >= crossPageTopZoneMinY else { continue }
                case .bottom:
                    guard region.box.midY <= crossPageBottomZoneMaxY else { continue }
                }
                guard region.box.height <= crossPageMaxRegionHeight else { continue }

                let inflated = region.box.insetBy(
                    dx: -regionInflation, dy: -regionInflation
                )
                let inRegion = page.observations.filter { obs in
                    inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
                }
                guard !inRegion.isEmpty else { continue }
                let totalChars = inRegion.reduce(0) { $0 + $1.text.count }
                guard totalChars <= crossPageMaxChars else { continue }

                let combined = inRegion
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = HeaderFooterClassifier.normalize(combined)
                // Skip noise: empty / single-character normalized
                // strings would over-cluster.
                guard normalized.count >= 3 else { continue }

                let topObs = inRegion.max(by: { $0.box.midY < $1.box.midY })
                let excerpt = String((topObs?.text ?? combined).prefix(60))
                byNormalized[normalized, default: []].append(Candidate(
                    pageIndex: page.pageIndex,
                    regionIndex: idx,
                    originalKind: region.kind,
                    normalizedText: normalized,
                    firstLineExcerpt: excerpt
                ))
            }
        }

        var overridesByPage: [Int: [Int: LayoutRegion.Kind]] = [:]
        var decisionsByPage: [Int: [CrossPageDecision]] = [:]

        for (normalized, candidates) in byNormalized {
            // Distinct pages this normalized text appears on.
            let distinctPageCount = Set(candidates.map(\.pageIndex)).count
            let isRecurring = distinctPageCount >= crossPageRunningHeadMinPages

            // Per-zone routing for the recurring vs unique branches.
            // Bottom zone leaves unique candidates untouched —
            // promoting a unique bottom-of-page short string to a
            // heading would be wrong (footnote stubs, decorative
            // lines, page-bottom labels are all common false
            // positives).
            let newKind: LayoutRegion.Kind?
            switch zone {
            case .top:
                newKind = isRecurring ? .pageHeader : .sectionHeader
            case .bottom:
                newKind = isRecurring ? .pageFooter : nil
            }
            guard let newKind else { continue }

            for c in candidates {
                overridesByPage[c.pageIndex, default: [:]][c.regionIndex] = newKind
                decisionsByPage[c.pageIndex, default: []].append(CrossPageDecision(
                    regionIndex: c.regionIndex,
                    originalKind: c.originalKind.rawValue,
                    newKind: newKind.rawValue,
                    firstLineExcerpt: c.firstLineExcerpt,
                    normalizedText: normalized,
                    recurrenceCount: distinctPageCount
                ))
            }
        }

        return CrossPageOverrides(
            overridesByPage: overridesByPage,
            decisionsByPage: decisionsByPage
        )
    }
}

