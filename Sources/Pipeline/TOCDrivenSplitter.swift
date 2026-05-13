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

    /// Which strategy resolved the boundaries. Title-matching is
    /// preferred because it's keyed on the actual heading text the
    /// OCR produced — robust to ambiguous page offsets that the
    /// anchor-based path can fall victim to. Page-offset is the
    /// fallback for books where heading detection didn't pick up
    /// the chapter titles or the TOC entries are too generic to
    /// match cleanly.
    public enum MatchStrategy: String, Sendable, Equatable, Codable {
        case titleMatch
        case pageOffset
    }

    /// Diagnostic summary for the debug log. Mirrors the shape of
    /// `ChapterSplitter.Diagnostics` so the pipeline's log
    /// renderer can branch cleanly: "TOC-driven, X entries
    /// resolved" vs. "Heuristic, level L, N breaks".
    public struct Diagnostics: Sendable, Equatable {
        /// Which path picked the boundaries. Recorded so a user
        /// debugging a misaligned conversion can see at a glance
        /// whether title-matching fired or the more error-prone
        /// page-offset fallback took over.
        public var matchStrategy: MatchStrategy
        /// Total TOC entries scanned.
        public var entriesSeen: Int
        /// Arabic display-page entries (the offset-learning input).
        /// Roman-numeral entries skip offset learning but can still
        /// land via the page-anchor fallback when the matching
        /// `PageAnchor` exists.
        public var arabicEntries: Int
        /// Inferred display→PDF offset (`pdf_index = display + offset - 1`).
        /// Set only on the `pageOffset` strategy. Nil for title-
        /// matching because the strategy doesn't need an offset.
        public var inferredOffset: Int?
        /// Entries that resolved to a block index — these become
        /// chapter boundaries.
        public var resolvedEntries: Int
        /// Entries we couldn't resolve to a block index after the
        /// offset was learned. Surfaced as a delta so the log shows
        /// the long tail without dumping every entry.
        public var unresolvedEntries: Int

        public init(
            matchStrategy: MatchStrategy = .pageOffset,
            entriesSeen: Int = 0,
            arabicEntries: Int = 0,
            inferredOffset: Int? = nil,
            resolvedEntries: Int = 0,
            unresolvedEntries: Int = 0
        ) {
            self.matchStrategy = matchStrategy
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

    /// Run the TOC-driven split. Two strategies in order:
    ///
    ///   1. **Title-matching (primary)**: for each TOC entry, scan
    ///      the block stream for a heading whose normalized text
    ///      contains ≥ 80% of the entry's words. Robust because it
    ///      keys on the actual OCR'd heading text. Used when at
    ///      least `minResolvedFraction` of arabic entries match.
    ///
    ///   2. **Page-offset (fallback)**: existing offset-learning
    ///      against `pageAnchors`. Used when title-matching can't
    ///      resolve enough entries — e.g. the TOC has very short
    ///      entries that match too generously, or the OCR mangled
    ///      headings beyond recognition.
    ///
    /// Returns nil when both strategies fail (caller falls through
    /// to `ChapterSplitter`).
    public static func split(
        blocks: [Block],
        footnotes: [Footnote],
        pageAnchors: [PageAnchor],
        figureAssets: [FigureAsset],
        toc: ParsedTOC,
        bookFallbackTitle: String
    ) -> Result? {
        let arabicEntries: [(displayPage: Int, title: String)] = toc.entries.compactMap {
            guard let n = $0.displayPageInt, n > 0 else { return nil }
            return (n, $0.title)
        }
        guard !arabicEntries.isEmpty else { return nil }
        let minRequired = max(2, Int(
            ceil(Double(arabicEntries.count) * minResolvedFraction)
        ))

        // Strategy 1: title matching.
        if let titleResult = splitByTitleMatching(
            blocks: blocks,
            footnotes: footnotes,
            pageAnchors: pageAnchors,
            figureAssets: figureAssets,
            toc: toc,
            arabicEntryCount: arabicEntries.count,
            minRequired: minRequired
        ) {
            return titleResult
        }

        // Strategy 2: page-offset fallback.
        return splitByPageOffset(
            blocks: blocks,
            footnotes: footnotes,
            pageAnchors: pageAnchors,
            figureAssets: figureAssets,
            toc: toc,
            arabicEntries: arabicEntries,
            minRequired: minRequired
        )
    }

    // MARK: - Strategy: title matching

    /// Match each TOC entry against the block stream by heading
    /// text. Word-bag containment (≥ 80% of the TOC entry's words
    /// must appear in the heading), TOC-order discipline (each
    /// subsequent entry searches from the previous match's index
    /// + 1), and `ChapterSplitter.canBreakChapter` filtering so
    /// running heads / drop caps / body-fragment misclassifications
    /// don't seduce a TOC entry into the wrong block.
    ///
    /// Returns nil when fewer than `minRequired` TOC entries match —
    /// caller falls through to the page-offset strategy.
    private static func splitByTitleMatching(
        blocks: [Block],
        footnotes: [Footnote],
        pageAnchors: [PageAnchor],
        figureAssets: [FigureAsset],
        toc: ParsedTOC,
        arabicEntryCount: Int,
        minRequired: Int
    ) -> Result? {
        let headingFreq = ChapterSplitter.headingTextFrequency(in: blocks)

        var matches: [(blockIdx: Int, title: String)] = []
        var cursor = 0
        for entry in toc.entries {
            let titleWords = normalizeForMatching(entry.title)
            // Refuse to match on TOC entries that normalize to
            // nothing (single-letter or all-punctuation) — too
            // noisy. They get folded into the previous chapter.
            guard !titleWords.isEmpty else { continue }
            // Defend against ultra-short generic entries ("I",
            // "II", "Note") that would match anywhere. Require at
            // least one ≥ 4-character word OR ≥ 3 words total —
            // either signal means the entry is specific enough.
            let hasLongWord = titleWords.contains { $0.count >= 4 }
            guard hasLongWord || titleWords.count >= 3 else { continue }

            var foundAt: Int?
            for idx in cursor..<blocks.count {
                guard case .heading(_, let runs) = blocks[idx] else { continue }
                guard ChapterSplitter.canBreakChapter(
                    blocks[idx], headingFrequency: headingFreq
                ) else { continue }
                let headingText = runs.map(\.text).joined()
                if titleMatches(
                    headingText: headingText, tocTitleWords: titleWords
                ) {
                    foundAt = idx
                    break
                }
            }
            if let foundAt {
                matches.append((foundAt, entry.title))
                cursor = foundAt + 1
            }
        }

        guard matches.count >= minRequired else { return nil }

        let chapters = assembleChapters(
            blocks: blocks,
            boundaries: matches,
            footnotes: footnotes,
            pageAnchors: pageAnchors,
            figureAssets: figureAssets
        )
        guard !chapters.isEmpty else { return nil }

        let diag = Diagnostics(
            matchStrategy: .titleMatch,
            entriesSeen: toc.entries.count,
            arabicEntries: arabicEntryCount,
            inferredOffset: nil,
            resolvedEntries: matches.count,
            unresolvedEntries: arabicEntryCount - matches.count
        )
        return Result(chapters: chapters, diagnostics: diag)
    }

    /// Normalize a string into a bag of words for matching: strip
    /// diacritics, lowercase, split on any non-letter, drop tokens
    /// shorter than 2 chars. Drops digits so OCR'd page-number
    /// artifacts in headings (e.g. "Functions I25 of Psychoanalysis")
    /// don't pollute the bag.
    static func normalizeForMatching(_ s: String) -> Set<String> {
        let folded = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        let lower = folded.lowercased()
        var words: [String] = []
        var current = ""
        for char in lower {
            if char.isLetter {
                current.append(char)
            } else {
                if current.count >= 2 { words.append(current) }
                current = ""
            }
        }
        if current.count >= 2 { words.append(current) }
        return Set(words)
    }

    /// Decide whether `headingText` likely refers to the same
    /// chapter as the TOC entry whose normalized words are
    /// `tocTitleWords`. Containment: ≥ `titleMatchCoverage` of the
    /// TOC's words must appear in the heading. Cheap, robust to
    /// extra OCR garbage in either direction.
    static func titleMatches(
        headingText: String, tocTitleWords: Set<String>
    ) -> Bool {
        guard !tocTitleWords.isEmpty else { return false }
        let headingWords = normalizeForMatching(headingText)
        let overlap = tocTitleWords.intersection(headingWords).count
        let coverage = Double(overlap) / Double(tocTitleWords.count)
        return coverage >= titleMatchCoverage
    }

    /// Fraction of a TOC entry's words that must appear in the
    /// heading for a match. 0.8 catches typical OCR variance (a
    /// stray page number, a missing accent) without admitting
    /// loosely-related headings.
    public static let titleMatchCoverage: Double = 0.8

    // MARK: - Strategy: page-offset fallback

    /// Page-offset learning + block-index resolution. The original
    /// strategy — works when page anchors map cleanly to display
    /// pages, but is vulnerable to ambiguous offsets when anchors
    /// are dense (every PDF page has one, every plausible offset
    /// ties at max matches). Title-matching wins where possible;
    /// this is the safety net.
    private static func splitByPageOffset(
        blocks: [Block],
        footnotes: [Footnote],
        pageAnchors: [PageAnchor],
        figureAssets: [FigureAsset],
        toc: ParsedTOC,
        arabicEntries: [(displayPage: Int, title: String)],
        minRequired: Int
    ) -> Result? {
        let pdfPageToBlockIndex = indexAnchorsByPDFPage(
            blocks: blocks, pageAnchors: pageAnchors
        )
        guard !pdfPageToBlockIndex.isEmpty else { return nil }
        let sortedAnchorPDFs = pdfPageToBlockIndex.keys.sorted()

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
        guard bestMatches >= minRequired else { return nil }

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

        var seen = Set<Int>()
        let orderedBoundaries = boundaries.filter { tuple in
            seen.insert(tuple.blockIdx).inserted
        }
        guard !orderedBoundaries.isEmpty else { return nil }
        let sortedBoundaries = orderedBoundaries.sorted { $0.blockIdx < $1.blockIdx }

        let chapters = assembleChapters(
            blocks: blocks,
            boundaries: sortedBoundaries,
            footnotes: footnotes,
            pageAnchors: pageAnchors,
            figureAssets: figureAssets
        )
        guard !chapters.isEmpty else { return nil }

        let diag = Diagnostics(
            matchStrategy: .pageOffset,
            entriesSeen: toc.entries.count,
            arabicEntries: arabicEntries.count,
            inferredOffset: bestOffset,
            resolvedEntries: boundaries.count,
            unresolvedEntries: arabicEntries.count - boundaries.count
        )
        return Result(chapters: chapters, diagnostics: diag)
    }

    // MARK: - Chapter assembly (shared by both strategies)

    /// Segment `blocks` at each boundary's block index. Pre-first-
    /// boundary content becomes "Front Matter" when it carries any
    /// substantive (non-anchor) content. Shared between title-
    /// matching and page-offset strategies so they produce
    /// identically-shaped output.
    private static func assembleChapters(
        blocks: [Block],
        boundaries: [(blockIdx: Int, title: String)],
        footnotes: [Footnote],
        pageAnchors: [PageAnchor],
        figureAssets: [FigureAsset]
    ) -> [Chapter] {
        guard !boundaries.isEmpty else { return [] }
        var chapters: [Chapter] = []
        let firstBoundaryIdx = boundaries[0].blockIdx
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
        for (i, b) in boundaries.enumerated() {
            let endIdx = (i + 1 < boundaries.count)
                ? boundaries[i + 1].blockIdx : blocks.count
            let segment = Array(blocks[b.blockIdx..<endIdx])
            chapters.append(buildChapter(
                title: b.title,
                segment: segment,
                allFootnotes: footnotes,
                allPageAnchors: pageAnchors,
                allFigureAssets: figureAssets
            ))
        }
        return chapters
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
