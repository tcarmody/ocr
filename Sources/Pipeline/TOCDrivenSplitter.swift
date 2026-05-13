import Foundation
import Document
import EPUB  // ParsedTOC

/// Primary chapter splitter when a confident TOC is available.
/// Replaces the heuristic-driven `ChapterSplitter` for books where
/// the printed table of contents was successfully parsed by
/// `ClaudeTOCParser` — typically professionally-published books
/// with a real TOC page.
///
/// Why this exists: `ChapterSplitter` picks one heading level to
/// break on (the lowest with ≥ 2 eligible breaks). For books with
/// a Part/Chapter hierarchy (Lacan's *Écrits*: 3 sections × ~15
/// essays each), the level detector latches onto the 3 H1
/// section-divider headings and emits 3 chapters — even though
/// the TOC lists 44 essays. The TOC has the right answer; this
/// splitter consumes it directly.
///
/// Falls back to nil when the TOC can't be confidently aligned to
/// the page anchors (degenerate offset, sparse anchor coverage,
/// scanned-image PDFs without a parseable TOC). The pipeline
/// drops through to `ChapterSplitter` in that case so the
/// non-TOC code path keeps working.
///
/// Algorithm:
///   1. Build a `pdfPage → blockIndex` map from `pageAnchors` ×
///      `Block.anchor` matches.
///   2. Learn the display-page → PDF-page offset by trying a
///      handful of candidates and picking the one that maximizes
///      TOC-entry → page-anchor matches. (Same offset-learning
///      strategy as `TOCTitleApplier`.)
///   3. For each TOC entry with an arabic display page, map to a
///      PDF page via the learned offset, then to a block index.
///   4. Confidence check: ≥ half the arabic entries must resolve
///      to a block index. Below that the TOC is probably mis-
///      aligned (different edition, OCR'd TOC with garbled
///      numbers) and the heuristic path is safer.
///   5. Sort + dedupe boundary indices; segment blocks at each
///      break. Pre-first-boundary content becomes "Front Matter"
///      when it carries substantive content, mirroring
///      `ChapterSplitter`'s convention.
public enum TOCDrivenSplitter {

    /// Diagnostic summary for the debug log. Mirrors the shape of
    /// `ChapterSplitter.Diagnostics` so the pipeline's log
    /// renderer can branch cleanly: "TOC-driven, X entries
    /// resolved" vs. "Heuristic, level L, N breaks".
    public struct Diagnostics: Sendable, Equatable {
        /// Total TOC entries scanned.
        public var entriesSeen: Int
        /// Arabic display-page entries (the offset-learning input).
        /// Roman-numeral entries skip offset learning but can still
        /// land via the page-anchor fallback when the matching
        /// `PageAnchor` exists.
        public var arabicEntries: Int
        /// Inferred display→PDF offset (`pdf_index = display + offset - 1`).
        /// Nil when offset learning failed; caller falls back.
        public var inferredOffset: Int?
        /// Entries that resolved to a block index — these become
        /// chapter boundaries.
        public var resolvedEntries: Int
        /// Entries we couldn't resolve to a block index after the
        /// offset was learned. Surfaced as a delta so the log shows
        /// the long tail without dumping every entry.
        public var unresolvedEntries: Int

        public init(
            entriesSeen: Int = 0,
            arabicEntries: Int = 0,
            inferredOffset: Int? = nil,
            resolvedEntries: Int = 0,
            unresolvedEntries: Int = 0
        ) {
            self.entriesSeen = entriesSeen
            self.arabicEntries = arabicEntries
            self.inferredOffset = inferredOffset
            self.resolvedEntries = resolvedEntries
            self.unresolvedEntries = unresolvedEntries
        }
    }

    public struct Result: Sendable, Equatable {
        public var chapters: [Chapter]
        public var diagnostics: Diagnostics
        public init(chapters: [Chapter], diagnostics: Diagnostics) {
            self.chapters = chapters
            self.diagnostics = diagnostics
        }
    }

    /// Title used for the pre-first-boundary segment (cover,
    /// dedications, copyright page, parsed TOC pages). Matches
    /// `ChapterSplitter.frontMatterTitle` so the two paths produce
    /// the same downstream shape.
    public static let frontMatterTitle = "Front Matter"

    /// Minimum fraction of arabic TOC entries that must resolve
    /// for the TOC-driven path to be considered confident. Below
    /// this we return nil and the caller falls back to the
    /// heuristic splitter. Tuned conservatively: a TOC parsed from
    /// OCR'd front matter often has 1-2 mangled entries; 50% leaves
    /// room for that without accepting wildly-misaligned offsets.
    public static let minResolvedFraction: Double = 0.5

    /// Candidate offsets to try during offset learning. Same set as
    /// `TOCTitleApplier` — covers typical roman-numeral front-
    /// matter lengths (0-25 pages) plus the unusual zero / negative
    /// cases.
    public static let candidateOffsets: [Int] = [0, 1, -1, 5, 10, 12, 15, 18, 20, 22, 25]

    /// Run the TOC-driven split. Returns nil when:
    ///   * No page anchors are available (blocks have no `.anchor`
    ///     markers, e.g. a synthetic test input).
    ///   * No TOC entry has a parseable arabic display page.
    ///   * Offset learning matched fewer than
    ///     `minResolvedFraction` of arabic entries.
    /// Caller falls through to `ChapterSplitter` in those cases.
    public static func split(
        blocks: [Block],
        footnotes: [Footnote],
        pageAnchors: [PageAnchor],
        figureAssets: [FigureAsset],
        toc: ParsedTOC,
        bookFallbackTitle: String
    ) -> Result? {
        var diag = Diagnostics(entriesSeen: toc.entries.count)

        // Index 1: pdfPage → blockIndex of the matching `.anchor`.
        let pdfPageToBlockIndex = indexAnchorsByPDFPage(
            blocks: blocks, pageAnchors: pageAnchors
        )
        guard !pdfPageToBlockIndex.isEmpty else { return nil }

        // Index 2: anchor pdf-pages, sorted. Used for "nearest
        // available page" fallback when the TOC's exact computed
        // page has no anchor (typical when the splitter loses a
        // page break to a layout glitch — fall back to the next-
        // closest break).
        let sortedAnchorPDFs = pdfPageToBlockIndex.keys.sorted()

        // Pull arabic display-page entries for offset learning.
        // Roman-numeral entries are tagged as front-matter; they
        // don't drive boundaries, but they're still counted toward
        // entriesSeen so the diagnostic delta makes sense.
        let arabicEntries: [(displayPage: Int, title: String)] = toc.entries.compactMap {
            guard let n = $0.displayPageInt, n > 0 else { return nil }
            return (n, $0.title)
        }
        diag.arabicEntries = arabicEntries.count
        guard !arabicEntries.isEmpty else { return nil }

        // Step 2: offset learning. For each candidate offset, count
        // how many entries map to an anchor PDF page (exact match
        // or ±1). Pick the offset with the most matches.
        var bestOffset: Int = 0
        var bestMatches = -1
        for offset in candidateOffsets {
            var matches = 0
            for (page, _) in arabicEntries {
                let inferred = page + offset - 1
                if isCloseToAnchor(
                    inferred, anchors: sortedAnchorPDFs, tolerance: 1
                ) { matches += 1 }
            }
            if matches > bestMatches {
                bestMatches = matches
                bestOffset = offset
            }
        }

        // Step 4: confidence gate. Below half the arabic entries
        // resolving the offset is too uncertain to drive splits.
        let minRequired = max(2, Int(
            ceil(Double(arabicEntries.count) * minResolvedFraction)
        ))
        guard bestMatches >= minRequired else { return nil }
        diag.inferredOffset = bestOffset

        // Step 3: resolve each TOC entry to a block index. Use
        // exact match where possible, ±2-page fuzzy lookup
        // otherwise. Entries that still don't resolve are counted
        // toward `unresolvedEntries` but don't abort the split.
        var boundaries: [(blockIdx: Int, title: String)] = []
        for entry in toc.entries {
            guard let n = entry.displayPageInt, n > 0 else { continue }
            let inferred = n + bestOffset - 1
            guard let blockIdx = nearestBlockIndex(
                forPDFPage: inferred,
                pageMap: pdfPageToBlockIndex,
                sortedAnchorPDFs: sortedAnchorPDFs,
                tolerance: 2
            ) else { continue }
            boundaries.append((blockIdx, entry.title))
        }
        diag.resolvedEntries = boundaries.count
        diag.unresolvedEntries = arabicEntries.count - boundaries.count

        // Dedupe block indices (two TOC entries on the same page
        // collapse to one boundary; first title wins). Preserve
        // TOC order for ties at the same anchor.
        var seen = Set<Int>()
        let orderedBoundaries = boundaries.filter { tuple in
            seen.insert(tuple.blockIdx).inserted
        }
        guard !orderedBoundaries.isEmpty else { return nil }

        // Sort by block index ascending. TOC entries are usually
        // already in page order, but a noisy parse could shuffle
        // them — sorting is cheap insurance.
        let sortedBoundaries = orderedBoundaries.sorted { $0.blockIdx < $1.blockIdx }

        // Step 5: segment blocks at each boundary. Pre-first-
        // boundary content → Front Matter (if substantive).
        var chapters: [Chapter] = []
        let firstBoundaryIdx = sortedBoundaries[0].blockIdx
        if firstBoundaryIdx > 0 {
            let frontMatterBlocks = Array(blocks[0..<firstBoundaryIdx])
            if hasSubstantiveContent(frontMatterBlocks) {
                chapters.append(buildChapter(
                    title: frontMatterTitle,
                    segment: frontMatterBlocks,
                    allFootnotes: footnotes,
                    allPageAnchors: pageAnchors,
                    allFigureAssets: figureAssets
                ))
            }
        }
        for (i, b) in sortedBoundaries.enumerated() {
            let endIdx = (i + 1 < sortedBoundaries.count)
                ? sortedBoundaries[i + 1].blockIdx : blocks.count
            let segment = Array(blocks[b.blockIdx..<endIdx])
            chapters.append(buildChapter(
                title: b.title,
                segment: segment,
                allFootnotes: footnotes,
                allPageAnchors: pageAnchors,
                allFigureAssets: figureAssets
            ))
        }

        // Final guard: if we somehow ended up with zero chapters,
        // return nil so the caller falls back. Shouldn't happen
        // given the boundaries-not-empty check above, but
        // belt-and-braces.
        guard !chapters.isEmpty else { return nil }

        return Result(chapters: chapters, diagnostics: diag)
    }

    // MARK: - Helpers

    /// Build the `pdfPage → blockIndex` lookup by joining the
    /// `pageAnchors` table with the `.anchor` blocks in `blocks`.
    /// Anchors with no matching block (orphans — possible when
    /// page-break detection mis-fired) are skipped silently;
    /// they're not reachable boundaries.
    static func indexAnchorsByPDFPage(
        blocks: [Block], pageAnchors: [PageAnchor]
    ) -> [Int: Int] {
        // Build the anchorId → pdfPage lookup once.
        let anchorIdToPDF = Dictionary(
            uniqueKeysWithValues: pageAnchors.map { ($0.anchorId, $0.pdfPage) }
        )
        var pdfToBlock: [Int: Int] = [:]
        for (i, block) in blocks.enumerated() {
            if case .anchor(let id, _) = block,
               let pdf = anchorIdToPDF[id],
               pdfToBlock[pdf] == nil {
                pdfToBlock[pdf] = i
            }
        }
        return pdfToBlock
    }

    /// True when `page` is within `tolerance` of any entry in
    /// `anchors` (binary search; assumes `anchors` is sorted).
    private static func isCloseToAnchor(
        _ page: Int, anchors: [Int], tolerance: Int
    ) -> Bool {
        guard !anchors.isEmpty else { return false }
        // Sorted-array nearest lookup via insertion-point search.
        var lo = 0
        var hi = anchors.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if anchors[mid] < page { lo = mid + 1 } else { hi = mid }
        }
        if lo < anchors.count, abs(anchors[lo] - page) <= tolerance { return true }
        if lo > 0, abs(anchors[lo - 1] - page) <= tolerance { return true }
        return false
    }

    /// Find the block index for `pdfPage`. Exact match wins;
    /// otherwise walks outward up to `tolerance` pages in either
    /// direction. Returns nil when no anchor is within range.
    private static func nearestBlockIndex(
        forPDFPage pdfPage: Int,
        pageMap: [Int: Int],
        sortedAnchorPDFs: [Int],
        tolerance: Int
    ) -> Int? {
        if let exact = pageMap[pdfPage] { return exact }
        for delta in 1...tolerance {
            if let above = pageMap[pdfPage + delta] { return above }
            if let below = pageMap[pdfPage - delta] { return below }
        }
        return nil
    }

    /// "Front matter has real content" heuristic — mirrors
    /// `ChapterSplitter.hasSubstantiveContent` so the two splitters
    /// emit consistent shapes. Front matter that's nothing but
    /// anchor blocks (a synthetic PDF with no text on the cover)
    /// gets suppressed.
    private static func hasSubstantiveContent(_ blocks: [Block]) -> Bool {
        for block in blocks {
            switch block {
            case .heading, .paragraph, .figure, .table:
                return true
            case .anchor:
                continue
            }
        }
        return false
    }

    /// Same shape as `ChapterSplitter.buildChapter`: filter
    /// document-level footnotes / page-anchors / figures down to
    /// the subset referenced by the segment.
    private static func buildChapter(
        title: String,
        segment: [Block],
        allFootnotes: [Footnote],
        allPageAnchors: [PageAnchor],
        allFigureAssets: [FigureAsset]
    ) -> Chapter {
        let noterefIds = collectNoterefIds(in: segment)
        let footnotes = allFootnotes.filter { noterefIds.contains($0.id) }
        let anchorIds = collectAnchorIds(in: segment)
        let anchors = allPageAnchors.filter { anchorIds.contains($0.anchorId) }
        let figureIds = collectFigureAssetIds(in: segment)
        let figures = allFigureAssets.filter { figureIds.contains($0.id) }
        return Chapter(
            title: title,
            blocks: segment,
            footnotes: footnotes,
            pageAnchors: anchors,
            figureAssets: figures
        )
    }

    private static func collectNoterefIds(in blocks: [Block]) -> Set<String> {
        var ids = Set<String>()
        for block in blocks {
            switch block {
            case .heading(_, let runs), .paragraph(let runs):
                for r in runs { if let id = r.noterefId { ids.insert(id) } }
            case .figure(_, _, let caption):
                for r in caption { if let id = r.noterefId { ids.insert(id) } }
            case .table(let rows, let caption):
                for r in caption { if let id = r.noterefId { ids.insert(id) } }
                for row in rows {
                    for cell in row {
                        for r in cell.runs {
                            if let id = r.noterefId { ids.insert(id) }
                        }
                    }
                }
            case .anchor:
                continue
            }
        }
        return ids
    }

    private static func collectFigureAssetIds(in blocks: [Block]) -> Set<String> {
        var ids = Set<String>()
        for block in blocks {
            if case .figure(let assetId, _, _) = block { ids.insert(assetId) }
        }
        return ids
    }

    private static func collectAnchorIds(in blocks: [Block]) -> Set<String> {
        var ids = Set<String>()
        for block in blocks {
            if case .anchor(let id, _) = block { ids.insert(id) }
        }
        return ids
    }
}
