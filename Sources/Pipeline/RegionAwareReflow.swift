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

    static func reflow(pageResults: [PageObservations]) -> Result {
        lastAttributions.removeAll(keepingCapacity: true)
        lastFootnotesPerPage.removeAll(keepingCapacity: true)
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
            let pageFootnotes = FootnoteLinker.parseFootnotes(
                pageIndex: page.pageIndex,
                observations: page.observations,
                regions: regions
            )
            if !pageFootnotes.isEmpty {
                lastFootnotesPerPage[page.pageIndex] = pageFootnotes
                allFootnotes.append(contentsOf: pageFootnotes)
            }
            blocks.append(contentsOf: reflowPage(
                page: page, regions: regions, pageFootnotes: pageFootnotes
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
}
