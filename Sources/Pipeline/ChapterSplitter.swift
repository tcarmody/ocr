import Foundation
import Document

/// Phase 1 of structured-document detection: split a flat block stream
/// into chapters at every level-1 heading. Output replaces the
/// single-chapter book the rest of the pipeline produces today, so
/// EPUB readers see a real multi-chapter TOC instead of one giant
/// document.
///
/// Algorithm:
///   1. Scan blocks for `.heading(level: 1, …)` indices.
///   2. If none, return a single chapter (current behavior — good
///      fallback for short pieces with no H1 structure).
///   3. Otherwise, segment blocks at each H1 boundary. Each segment
///      includes the heading itself so chapter XHTML opens with its
///      own `<h1>`.
///   4. Pre-first-H1 content (dedications, copyright pages, anything
///      that lands before the first chapter title) becomes a chapter
///      titled "Front Matter" — but only if it has substantive
///      content (more than just page anchors).
///   5. Per-chapter footnote / page-anchor distribution: walk each
///      segment's blocks for noteref ids and anchor ids, then filter
///      the document-level lists down to the matching subsets.
///
/// Distribution is precise: a footnote referenced from inside chapter
/// 3 ends up in chapter 3's `footnotes` array (and only there), so the
/// EPUB writer can emit popups in the right files.
public enum ChapterSplitter {

    /// Title used for the pre-first-H1 segment when it carries real
    /// content. Easy to swap in callers if a localized name is
    /// preferred — the heuristic lives entirely in this file.
    public static let frontMatterTitle = "Front Matter"

    /// Decision summary for the debug log. Captures the level the
    /// splitter chose, eligible vs. filtered heading counts, and a
    /// per-filter accounting so a failed conversion can be diagnosed
    /// from the log alone without re-running the pipeline.
    public struct Diagnostics: Sendable, Equatable {
        /// Reason a candidate heading failed `canBreakChapter`.
        public enum FilterReason: String, Sendable, Equatable, Codable {
            case tooShort
            case startsLowercase
            case midSentenceTerminator
            case runningHead
        }
        public struct Filtered: Sendable, Equatable {
            public var level: Int
            public var text: String
            public var reason: FilterReason
            public init(level: Int, text: String, reason: FilterReason) {
                self.level = level
                self.text = text
                self.reason = reason
            }
        }
        /// Total heading-block count seen, regardless of level.
        public var headingsSeen: Int
        /// Per-level heading-block count (raw, before eligibility
        /// filtering).
        public var headingCountsByLevel: [Int: Int]
        /// Level the splitter chose for the chapter break. 1 (H1)
        /// when nothing qualified — paired with empty
        /// `eligibleBreakCount`, signals the degenerate fallback.
        public var detectedChapterLevel: Int
        /// Number of *eligible* breaks at the detected level after
        /// filtering. 0 ⇒ degenerate single-chapter fallback fired.
        public var eligibleBreakCount: Int
        /// Headings that survived level detection but failed
        /// `canBreakChapter`. Each filter is recorded individually
        /// so the debug log shows the long tail.
        public var filtered: [Filtered]
        /// True iff the splitter returned a single chapter because
        /// no eligible breaks survived (or no headings existed in
        /// the first place).
        public var degenerateFallbackUsed: Bool
        /// When the ratio override fired, the level that the
        /// first-pass detector originally picked. Nil when no
        /// override fired — `detectedChapterLevel` is the only
        /// level considered. Surfaced in the debug log so a user
        /// debugging "why isn't this splitting at the level I
        /// expected?" can see the override decision.
        public var levelOverriddenFrom: Int?

        public init(
            headingsSeen: Int = 0,
            headingCountsByLevel: [Int: Int] = [:],
            detectedChapterLevel: Int = 1,
            eligibleBreakCount: Int = 0,
            filtered: [Filtered] = [],
            degenerateFallbackUsed: Bool = false,
            levelOverriddenFrom: Int? = nil
        ) {
            self.headingsSeen = headingsSeen
            self.headingCountsByLevel = headingCountsByLevel
            self.detectedChapterLevel = detectedChapterLevel
            self.eligibleBreakCount = eligibleBreakCount
            self.filtered = filtered
            self.degenerateFallbackUsed = degenerateFallbackUsed
            self.levelOverriddenFrom = levelOverriddenFrom
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

    /// Split `blocks` into chapters at the document's *dominant
    /// heading level*. Splitting strictly at H1 was the original
    /// behavior, but Surya's layout model emits H1 only for the
    /// book's title region (`.title`) — chapter headings come back
    /// as `.sectionHeader` → H2. Books with one title page + 20
    /// chapter starts ended up as one giant chapter under that
    /// rule. The dominant-level detection picks the smallest
    /// (highest-priority) heading level with ≥ 2 occurrences:
    ///
    ///   * Book with 12 H1 chapter starts (rare) → split at H1.
    ///   * Book with 1 H1 (title) + 12 H2 chapters → split at H2.
    ///   * Pamphlet with 0 / 1 headings total → degenerate single
    ///     chapter (current fallback).
    ///
    /// `bookFallbackTitle` is used as the chapter title when no
    /// heading level qualifies, so the rendered book still has a
    /// navigable name.
    public static func split(
        blocks: [Block],
        footnotes: [Footnote],
        pageAnchors: [PageAnchor],
        figureAssets: [FigureAsset] = [],
        figureMetadata: [String: FigureMetadata] = [:],
        bookFallbackTitle: String
    ) -> [Chapter] {
        // Convenience overload preserved for callers / tests that
        // don't care about diagnostics. The real work lives in
        // `splitWithDiagnostics`.
        return splitWithDiagnostics(
            blocks: blocks,
            footnotes: footnotes,
            pageAnchors: pageAnchors,
            figureAssets: figureAssets,
            figureMetadata: figureMetadata,
            bookFallbackTitle: bookFallbackTitle
        ).chapters
    }

    /// Variant that returns both the chapter list and a
    /// `Diagnostics` snapshot — heading counts per level, the
    /// selected chapter level, eligible-break counts, and per-filter
    /// reasons for the headings that didn't make the cut. The
    /// production pipeline calls this so the debug log can record
    /// the decision; the convenience `split` overload above just
    /// forwards.
    public static func splitWithDiagnostics(
        blocks: [Block],
        footnotes: [Footnote],
        pageAnchors: [PageAnchor],
        figureAssets: [FigureAsset] = [],
        figureMetadata: [String: FigureMetadata] = [:],
        bookFallbackTitle: String
    ) -> Result {
        let headingFreq = headingTextFrequency(in: blocks)
        var diagnostics = Diagnostics()
        // Count heading blocks by level (raw, before eligibility).
        for block in blocks {
            guard case .heading(let level, _) = block else { continue }
            diagnostics.headingsSeen += 1
            diagnostics.headingCountsByLevel[level, default: 0] += 1
        }
        let levelDecision = detectChapterLevelWithOverride(in: blocks)
        let chapterLevel = levelDecision.level
        diagnostics.detectedChapterLevel = chapterLevel
        diagnostics.levelOverriddenFrom = levelDecision.overrideFromLevel

        // Two-stage filter: only blocks that are (a) headings at the
        // chapter level *and* (b) "look like" real chapter titles open
        // a new chapter. Failing the eligibility check leaves the
        // heading rendered as `<h2>` (or whatever level Surya assigned)
        // in the chapter's body — we only suppress chapter-boundary
        // promotion. See `canBreakChapter` for the gates.
        var breakIndices: [Int] = []
        for idx in blocks.indices {
            guard case .heading(let level, let runs) = blocks[idx],
                  level == chapterLevel
            else { continue }
            if canBreakChapter(blocks[idx], headingFrequency: headingFreq) {
                breakIndices.append(idx)
            } else if let reason = filterReason(
                level: level, runs: runs, headingFrequency: headingFreq
            ) {
                let text = runs.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                diagnostics.filtered.append(
                    .init(level: level, text: text, reason: reason)
                )
            }
        }
        diagnostics.eligibleBreakCount = breakIndices.count

        // Degenerate case: no qualifying heading found. One chapter,
        // everything in it — matches the pre-Phase-1 behavior so
        // EPUBs without heading structure still produce valid output.
        guard !breakIndices.isEmpty else {
            diagnostics.degenerateFallbackUsed = true
            return Result(chapters: [Chapter(
                title: bookFallbackTitle,
                blocks: blocks,
                footnotes: footnotes,
                pageAnchors: pageAnchors,
                figureAssets: figureAssets,
                figureMetadata: figureMetadata
            )], diagnostics: diagnostics)
        }

        var chapters: [Chapter] = []

        // Front matter: anything before the first chapter-level heading.
        // When the chapter level is 2, "front matter" includes any H1
        // (typically the book's title page) — that lands here naturally.
        let frontMatterBlocks = Array(blocks[0..<breakIndices[0]])
        if hasSubstantiveContent(frontMatterBlocks) {
            chapters.append(buildChapter(
                title: frontMatterTitle,
                segment: frontMatterBlocks,
                allFootnotes: footnotes,
                allPageAnchors: pageAnchors,
                allFigureAssets: figureAssets,
                allFigureMetadata: figureMetadata
            ))
        }

        // Each chapter-level heading starts a chapter; segment runs
        // from that heading (inclusive) up to the next one (exclusive),
        // or end-of-blocks.
        for (i, idx) in breakIndices.enumerated() {
            let endIdx = (i + 1 < breakIndices.count)
                ? breakIndices[i + 1] : blocks.count
            let segment = Array(blocks[idx..<endIdx])
            let title = headingText(segment.first) ?? "Chapter \(chapters.count + 1)"
            chapters.append(buildChapter(
                title: title,
                segment: segment,
                allFootnotes: footnotes,
                allPageAnchors: pageAnchors,
                allFigureAssets: figureAssets,
                allFigureMetadata: figureMetadata
            ))
        }

        return Result(chapters: chapters, diagnostics: diagnostics)
    }

    /// Diagnostic-only inverse of `canBreakChapter`: when a heading
    /// fails to qualify, which gate killed it? Used by the debug log
    /// to surface the long tail of running-head / drop-cap / body-
    /// fragment misfires.
    private static func filterReason(
        level: Int, runs: [InlineRun], headingFrequency: [String: Int]
    ) -> Diagnostics.FilterReason? {
        let text = runs.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count < minChapterHeadingLength { return .tooShort }
        if let first = text.first, first.isLowercase { return .startsLowercase }
        let range = NSRange(text.startIndex..., in: text)
        let matches = midSentenceTerminatorRegex.matches(in: text, range: range)
        if matches.contains(where: { $0.range.location >= midSentenceTerminatorMinOffset }) {
            return .midSentenceTerminator
        }
        if (headingFrequency[text] ?? 0) >= maxChapterHeadingRepetition {
            return .runningHead
        }
        return nil
    }

    /// Pick the heading level to split chapters at. Returns the
    /// level only; see `detectChapterLevelWithOverride` for the
    /// override-aware variant.
    static func detectChapterLevel(in blocks: [Block]) -> Int {
        return detectChapterLevelWithOverride(in: blocks).level
    }

    /// Pick the heading level to split chapters at, with optional
    /// override when a deeper level looks structurally stronger.
    ///
    /// First pass: smallest (most prominent) level with at least
    /// `minHeadingCountForSplit` *eligible* occurrences. Returns 1
    /// (H1) as the fallback when no level qualifies — same as the
    /// pre-detection behavior, so the degenerate single-chapter case
    /// still kicks in via the empty-`breakIndices` branch.
    ///
    /// Heading promotions that fail `canBreakChapter` (drop caps,
    /// body-fragment misclassifications, repeated running heads)
    /// don't count toward the dominant level — otherwise a book
    /// flooded with running-head H2s could trick the detector into
    /// splitting at that level even though every "heading" at that
    /// level is bogus.
    ///
    /// Ratio override: after the first pass picks level L, walk
    /// deeper levels for a candidate that satisfies *all three* of:
    ///   * `>= deeperLevelCountRatio` times more eligible breaks
    ///     than L.
    ///   * `>= minDeeperLevelCountForOverride` eligible breaks
    ///     absolute (so a 1-vs-5 jump doesn't trip the override).
    ///   * Coverage spans the document — first break in the first
    ///     third, last break in the last third (so a level that
    ///     only clusters in the back-matter index doesn't get
    ///     promoted).
    /// This is deliberately not size-based: poetry / short-story
    /// collections can have any chapter length and would fail a
    /// pages-per-chapter heuristic. The signals here are purely
    /// structural — "is the deeper level a fuller, evenly-spread
    /// partition of the document?"
    static func detectChapterLevelWithOverride(
        in blocks: [Block]
    ) -> (level: Int, overrideFromLevel: Int?) {
        let freq = headingTextFrequency(in: blocks)
        var positions: [Int: [Int]] = [:]
        for (i, block) in blocks.enumerated() {
            guard case .heading(let level, _) = block else { continue }
            guard canBreakChapter(block, headingFrequency: freq) else { continue }
            positions[level, default: []].append(i)
        }

        var initial = 1
        for level in 1...6 {
            if (positions[level]?.count ?? 0) >= minHeadingCountForSplit {
                initial = level
                break
            }
        }

        let initialCount = positions[initial]?.count ?? 0
        guard initialCount > 0, blocks.count > 0 else {
            return (initial, nil)
        }

        for deeper in (initial + 1)...6 {
            let deepPositions = positions[deeper] ?? []
            let deepCount = deepPositions.count
            guard deepCount >= minDeeperLevelCountForOverride else { continue }
            guard deepCount >= initialCount * deeperLevelCountRatio else { continue }
            guard coversDocument(positions: deepPositions, docSize: blocks.count) else { continue }
            return (deeper, initial)
        }
        return (initial, nil)
    }

    /// Coverage check for the ratio override: a level whose breaks
    /// land in both the first third *and* the last third of the
    /// document is treated as a "real" partition. Levels whose
    /// breaks cluster (typical when an OCR'd index inflates a level
    /// with hundreds of entries packed at the back) don't pass.
    /// `docSize` is the total block count.
    static func coversDocument(positions: [Int], docSize: Int) -> Bool {
        guard let first = positions.first, let last = positions.last else {
            return false
        }
        guard docSize > 0 else { return false }
        let firstThird = docSize / 3
        let lastThird = (docSize * 2) / 3
        return first <= firstThird && last >= lastThird
    }

    /// Minimum count ratio between a deeper level and the chosen
    /// level for the override to fire. 5× is high enough that a
    /// real Part/Chapter hierarchy (e.g., 3 Parts × 4 chapters
    /// each = 4× ratio) stays at the upper level; meanwhile,
    /// Lacan's Écrits at 13× clears it easily.
    public static let deeperLevelCountRatio = 5
    /// Minimum absolute eligible-break count at the deeper level
    /// for the override to fire. Defense against a 1-vs-5 case
    /// where the ratio is satisfied but neither level is suitable.
    public static let minDeeperLevelCountForOverride = 5

    /// Below this many same-level *eligible* headings, splitting at
    /// that level is too aggressive — a single section heading inside
    /// a long flat document shouldn't carve it up. 2 is the lowest
    /// sensible floor (a book with 2 chapters has 2 chapter-level
    /// headings).
    public static let minHeadingCountForSplit = 2

    /// Minimum length (chars, post-trim) for a heading to qualify as
    /// a chapter boundary. Drop caps come back from layout as
    /// 1-character `.sectionHeader` regions; a bare "T" should never
    /// open a new chapter.
    public static let minChapterHeadingLength = 3

    /// Same heading text repeated this many times (or more) is
    /// treated as a running head, not a chapter boundary. Real
    /// chapter titles in a book are unique; running heads echo across
    /// every page in a section. Threshold of 3 lets a multi-part book
    /// have two chapters titled "Notes" without false-positiving but
    /// catches the common "every page of Part I has 'INTRODUCTION'
    /// at the top" pattern.
    public static let maxChapterHeadingRepetition = 3

    /// Pre-compiled regex matching mid-text sentence breaks: a
    /// sentence-terminating mark followed by whitespace and a letter.
    /// A real chapter title is one statement; multi-sentence prose is
    /// body content that Surya mis-promoted.
    private static let midSentenceTerminatorRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"[.!?]\s+\p{L}"#)
    }()

    /// Minimum start position (UTF-16 offset) for a mid-sentence
    /// terminator match to count as a "this is body text" signal.
    /// Below this offset, the match is almost certainly part of a
    /// label or abbreviation that's part of the title:
    ///   * `1. Antitheses` — match at 1
    ///   * `I. Introduction` — match at 1
    ///   * `§ 1. Logic` — match at 3
    ///   * `Mr. Smith` — match at 2
    ///   * `Dr. Strangelove` — match at 2
    /// Body content has its first sentence terminator deeper in the
    /// string after a real word: `He nodded. Then he left.` matches
    /// at offset 9. 6 is comfortably above the longest common label
    /// ("Vol. ", "Chap. ", "I.II. ") and below realistic body sentences.
    public static let midSentenceTerminatorMinOffset = 6

    /// Build a frequency map of every heading's joined text — used
    /// for the running-head dedup gate. Empty / whitespace-only
    /// headings are skipped (they wouldn't open a chapter anyway).
    static func headingTextFrequency(in blocks: [Block]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for block in blocks {
            guard case .heading(_, let runs) = block else { continue }
            let text = runs.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                counts[text, default: 0] += 1
            }
        }
        return counts
    }

    /// Decide whether a heading block looks like a real chapter
    /// boundary. The four gates target the failure modes we've seen:
    ///
    ///   * **Min length** (`minChapterHeadingLength`): kills 1-char
    ///     drop caps and 2-char fragments.
    ///   * **First-char polarity**: a heading that starts with a
    ///     lowercase letter is almost always the tail of a sentence
    ///     Surya mis-promoted (e.g. "ing, with all the …"). Capitals,
    ///     digits, §, opening quotes, parentheses all pass.
    ///   * **No mid-text sentence terminator**: a heading containing
    ///     `". "` followed by a letter is body text spanning multiple
    ///     sentences, never a chapter title.
    ///   * **Running-head dedup**: same text appearing
    ///     ≥ `maxChapterHeadingRepetition` times across all headings
    ///     is the per-page running head, not a chapter break.
    ///
    /// Headings that fail still render as `<h2>` (or whatever level
    /// they have) — we don't strip the typography, just suppress the
    /// chapter-boundary promotion.
    static func canBreakChapter(
        _ block: Block,
        headingFrequency: [String: Int]
    ) -> Bool {
        guard case .heading(_, let runs) = block else { return false }
        let text = runs.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.count >= minChapterHeadingLength else { return false }

        if let first = text.first, first.isLowercase {
            return false
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = midSentenceTerminatorRegex.matches(in: text, range: range)
        let hasBodyTerminator = matches.contains { match in
            match.range.location >= midSentenceTerminatorMinOffset
        }
        if hasBodyTerminator { return false }

        if (headingFrequency[text] ?? 0) >= maxChapterHeadingRepetition {
            return false
        }

        return true
    }

    // MARK: - block predicates

    private static func isHeading(_ block: Block, level target: Int) -> Bool {
        if case .heading(let level, _) = block, level == target { return true }
        return false
    }

    private static func headingText(_ block: Block?) -> String? {
        guard case .heading(_, let runs) = block else { return nil }
        let joined = runs.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// "Substantive" = at least one block that isn't a page anchor.
    /// A pre-H1 segment with only invisible page-break anchors (very
    /// common: cover page renders as a single anchor + nothing) would
    /// otherwise produce an empty front-matter chapter that just
    /// confuses readers' navigation panels. A figure or table on its
    /// own counts as substantive — a frontispiece illustration or a
    /// front-matter table shouldn't get silently dropped.
    private static func hasSubstantiveContent(_ blocks: [Block]) -> Bool {
        for b in blocks {
            switch b {
            case .anchor:
                continue
            case .paragraph(let runs), .heading(_, let runs):
                let joined = runs.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { return true }
            case .figure, .table:
                return true
            case .verse(let lines):
                // Any non-empty verse line counts.
                let any = lines.contains { line in
                    !line.runs.map(\.text).joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                }
                if any { return true }
            }
        }
        return false
    }

    // MARK: - chapter assembly

    private static func buildChapter(
        title: String?,
        segment: [Block],
        allFootnotes: [Footnote],
        allPageAnchors: [PageAnchor],
        allFigureAssets: [FigureAsset],
        allFigureMetadata: [String: FigureMetadata] = [:]
    ) -> Chapter {
        let noterefIds = collectNoterefIds(in: segment)
        let footnotes = allFootnotes.filter { noterefIds.contains($0.id) }
        let anchorIds = collectAnchorIds(in: segment)
        let anchors = allPageAnchors.filter { anchorIds.contains($0.anchorId) }
        let figureIds = collectFigureAssetIds(in: segment)
        let figures = allFigureAssets.filter { figureIds.contains($0.id) }
        // Slice figure metadata to this chapter's referenced
        // assets only (mirrors the figureAssets filter above).
        // Empty when diagram description was off; defaults to
        // `[:]` so non-cascade callers (legacy outline splitter)
        // don't have to pass it explicitly.
        let metadata = allFigureMetadata.filter { figureIds.contains($0.key) }
        return Chapter(
            title: title,
            blocks: segment,
            footnotes: footnotes,
            pageAnchors: anchors,
            figureAssets: figures,
            figureMetadata: metadata
        )
    }

    /// All `noterefId` values referenced by inline runs in `blocks`.
    /// Only these footnotes need to live in this chapter's XHTML;
    /// orphaned footnotes (referenced from a different chapter, or
    /// not referenced at all) belong elsewhere or get dropped.
    private static func collectNoterefIds(in blocks: [Block]) -> Set<String> {
        var ids = Set<String>()
        for block in blocks {
            switch block {
            case .heading(_, let runs), .paragraph(let runs):
                for r in runs {
                    if let id = r.noterefId { ids.insert(id) }
                }
            case .figure(_, _, let caption):
                for r in caption {
                    if let id = r.noterefId { ids.insert(id) }
                }
            case .table(let rows, let caption):
                for r in caption {
                    if let id = r.noterefId { ids.insert(id) }
                }
                for row in rows {
                    for cell in row {
                        for r in cell.runs {
                            if let id = r.noterefId { ids.insert(id) }
                        }
                    }
                }
            case .verse(let lines):
                for line in lines {
                    for r in line.runs {
                        if let id = r.noterefId { ids.insert(id) }
                    }
                }
            case .anchor:
                continue
            }
        }
        return ids
    }

    /// All `figureAssetId` values referenced by figure blocks in
    /// `blocks`. Mirrors `collectNoterefIds` so per-chapter assets
    /// stay scoped to the chapter that actually uses them.
    private static func collectFigureAssetIds(in blocks: [Block]) -> Set<String> {
        var ids = Set<String>()
        for block in blocks {
            if case .figure(let assetId, _, _) = block { ids.insert(assetId) }
        }
        return ids
    }

    /// All `Block.anchor.id` values appearing in `blocks`. Used to
    /// pick the subset of `pageAnchors` belonging to this chapter so
    /// the per-chapter `pageAnchors` array stays in sync with the
    /// chapter's actual page-break elements.
    private static func collectAnchorIds(in blocks: [Block]) -> Set<String> {
        var ids = Set<String>()
        for block in blocks {
            if case .anchor(let id, _) = block { ids.insert(id) }
        }
        return ids
    }
}
