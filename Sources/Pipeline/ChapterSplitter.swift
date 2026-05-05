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

    /// Split `blocks` into chapters at H1 boundaries.
    ///
    /// `bookFallbackTitle` is used as the chapter title when there
    /// are no H1s at all (the single-chapter degenerate case), so
    /// the rendered book still has a navigable name.
    public static func split(
        blocks: [Block],
        footnotes: [Footnote],
        pageAnchors: [PageAnchor],
        figureAssets: [FigureAsset] = [],
        bookFallbackTitle: String
    ) -> [Chapter] {
        let h1Indices = blocks.indices.filter { isH1(blocks[$0]) }

        // Degenerate case: no H1 found. One chapter, everything in it.
        // Matches the pre-Phase-1 behavior so EPUBs without heading
        // structure (short pieces, single chapters, OCR that didn't
        // detect any heading) still produce valid output.
        guard !h1Indices.isEmpty else {
            return [Chapter(
                title: bookFallbackTitle,
                blocks: blocks,
                footnotes: footnotes,
                pageAnchors: pageAnchors,
                figureAssets: figureAssets
            )]
        }

        var chapters: [Chapter] = []

        // Front matter: anything before the first H1.
        let frontMatterBlocks = Array(blocks[0..<h1Indices[0]])
        if hasSubstantiveContent(frontMatterBlocks) {
            chapters.append(buildChapter(
                title: frontMatterTitle,
                segment: frontMatterBlocks,
                allFootnotes: footnotes,
                allPageAnchors: pageAnchors,
                allFigureAssets: figureAssets
            ))
        }

        // Each H1 starts a chapter; segment runs from that H1
        // (inclusive) up to the next H1 (exclusive), or end-of-blocks.
        for (i, h1Idx) in h1Indices.enumerated() {
            let endIdx = (i + 1 < h1Indices.count) ? h1Indices[i + 1] : blocks.count
            let segment = Array(blocks[h1Idx..<endIdx])
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

    // MARK: - block predicates

    private static func isH1(_ block: Block) -> Bool {
        if case .heading(level: 1, _) = block { return true }
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
