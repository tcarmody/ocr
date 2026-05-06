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
        bookFallbackTitle: String
    ) -> [Chapter] {
        let headingFreq = headingTextFrequency(in: blocks)
        let chapterLevel = detectChapterLevel(in: blocks)
        // Two-stage filter: only blocks that are (a) headings at the
        // chapter level *and* (b) "look like" real chapter titles open
        // a new chapter. Failing the eligibility check leaves the
        // heading rendered as `<h2>` (or whatever level Surya assigned)
        // in the chapter's body — we only suppress chapter-boundary
        // promotion. See `canBreakChapter` for the gates.
        let breakIndices = blocks.indices.filter {
            isHeading(blocks[$0], level: chapterLevel)
                && canBreakChapter(blocks[$0], headingFrequency: headingFreq)
        }

        // Degenerate case: no qualifying heading found. One chapter,
        // everything in it — matches the pre-Phase-1 behavior so
        // EPUBs without heading structure still produce valid output.
        guard !breakIndices.isEmpty else {
            return [Chapter(
                title: bookFallbackTitle,
                blocks: blocks,
                footnotes: footnotes,
                pageAnchors: pageAnchors,
                figureAssets: figureAssets
            )]
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
                allFigureAssets: figureAssets
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
                allFigureAssets: figureAssets
            ))
        }

        return chapters
    }

    /// Pick the heading level to split chapters at. Prefers the
    /// smallest (most prominent) level with at least
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
    static func detectChapterLevel(in blocks: [Block]) -> Int {
        let freq = headingTextFrequency(in: blocks)
        var counts: [Int: Int] = [:]
        for block in blocks {
            guard case .heading(let level, _) = block else { continue }
            guard canBreakChapter(block, headingFrequency: freq) else { continue }
            counts[level, default: 0] += 1
        }
        for level in 1...6 {
            if (counts[level] ?? 0) >= minHeadingCountForSplit {
                return level
            }
        }
        return 1
    }

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
