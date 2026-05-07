import Foundation
import Document

/// R-Hierarchy. Finds sub-section headings inside a chapter so the
/// EPUB nav can surface them as nested entries underneath the
/// chapter, and `XHTMLWriter` can emit a stable `id` attribute on
/// each sub-section heading for the nav links to land on.
///
/// "Sub-section" = any heading block in the chapter whose level is
/// **deeper** than the chapter's own opening heading. A typical
/// academic book might split chapters at H1; sub-sections are then
/// any H2 / H3 / H4 inside. Books that split at H2 (Surya labels
/// the title page H1 + chapter starts H2 — common, see
/// `ChapterSplitter.detectChapterLevel`) carry H3 / H4 as
/// sub-sections.
///
/// The chapter's own opening heading is intentionally excluded from
/// the children list — the chapter row in the nav already carries
/// that title. Front-matter chapters (no opening heading) produce
/// no sub-sections; we don't try to lift their internal headings
/// into the nav.
enum ChapterHierarchy {

    /// One sub-section heading inside a chapter.
    struct Subsection: Sendable, Equatable {
        /// Index of the heading block in the chapter's `blocks`
        /// array. Used both to inject the stable `id` attribute on
        /// render and to anchor the nav link.
        let blockIndex: Int
        /// Heading level (`<hN>`). Preserved so the nav can nest
        /// deeper headings under shallower ones (H3 sits under
        /// the most recent H2, etc.).
        let level: Int
        /// Trimmed plain text of the heading runs.
        let title: String
        /// Stable XML id, suitable for `<h2 id="...">` in the
        /// chapter XHTML and `#...` in the nav href.
        let anchorId: String
    }

    /// Compute the sub-section list for one chapter. Returns an
    /// empty array when the chapter has no opening heading or no
    /// deeper headings inside it.
    ///
    /// `chapterIdx` namespaces the generated ids so two chapters'
    /// heading positions can't collide (`hu-sec-0-3` vs `hu-sec-1-3`).
    static func subsections(
        of chapter: Chapter, chapterIdx: Int
    ) -> [Subsection] {
        // The first heading block (if any) defines the chapter's
        // own level — only headings strictly deeper than that count
        // as sub-sections. A chapter that opens with body content
        // has no "own level" and we skip the pass.
        var ownLevel: Int?
        var firstHeadingBlockIdx: Int?
        for (idx, block) in chapter.blocks.enumerated() {
            if case .heading(let level, _) = block {
                ownLevel = level
                firstHeadingBlockIdx = idx
                break
            }
        }
        guard let ownLevel, let firstHeadingBlockIdx else { return [] }

        var subsections: [Subsection] = []
        for (idx, block) in chapter.blocks.enumerated() {
            // Skip the chapter's own opening heading; that's the
            // chapter row in the nav, not a child.
            guard idx != firstHeadingBlockIdx else { continue }
            guard case .heading(let level, let runs) = block else { continue }
            guard level > ownLevel else { continue }
            let title = runs.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty heading = nothing to navigate to. Skip rather
            // than emit a row labeled "" or with no link target.
            guard !title.isEmpty else { continue }
            subsections.append(Subsection(
                blockIndex: idx,
                level: level,
                title: title,
                anchorId: anchorId(chapterIdx: chapterIdx, blockIdx: idx)
            ))
        }
        return subsections
    }

    /// Per-id format. Stable as long as block ordering is stable
    /// within the chapter (which it is — chapters are built once
    /// per render and not reshuffled). A book-wide rename from
    /// chapter 5 to chapter 6 changes the id; that's fine because
    /// the nav is regenerated alongside the XHTML.
    static func anchorId(chapterIdx: Int, blockIdx: Int) -> String {
        "hu-sec-\(chapterIdx)-\(blockIdx)"
    }

    /// Convert a flat list of sub-sections (in block order, levels
    /// possibly mixed) into a nested `NavWriter.Entry` tree under
    /// the parent `chapterHref`. The parent's id-suffix in the
    /// href is `#{anchorId}` for each sub-section.
    ///
    /// Nesting rule: each entry sits as a child of the most recent
    /// preceding entry whose level is **strictly shallower**.
    /// Levels that don't fit (a deeper heading appearing before any
    /// shallower one) attach to the chapter root — same posture as
    /// flattening the misnested branch into the top level rather
    /// than dropping it.
    static func navChildren(
        from subsections: [Subsection],
        chapterHref: String
    ) -> [NavWriter.Entry] {
        // We build the tree iteratively using a level-indexed stack:
        // `parents[level] = "the entry currently being built at this level"`.
        // When we see a new entry at level L, attach it under the
        // deepest non-nil parent whose level < L (or to the root if
        // none). Then update parents[L] to the new entry; clear
        // parents[> L] so deeper sibling chains restart cleanly.
        var rootChildren: [NavWriter.Entry] = []
        // Track the path from root → current parent so we can mutate
        // children when adding a child. Using indices into the tree
        // would be cleaner, but Swift's value semantics on arrays
        // mean we'd have to fight CoW; the iterative pointer-tree
        // approach is simpler. We rebuild the tree by tracking the
        // ancestor chain.
        struct Frame {
            var entry: NavWriter.Entry
            var level: Int
        }
        var stack: [Frame] = []

        func appendCompletedFrames(downTo level: Int) {
            // Pop frames whose level is ≥ `level` — they're complete
            // and need to be folded into their parent (or root).
            while let last = stack.last, last.level >= level {
                stack.removeLast()
                if var parent = stack.last {
                    parent.entry.children.append(last.entry)
                    stack[stack.count - 1] = parent
                } else {
                    rootChildren.append(last.entry)
                }
            }
        }

        for sub in subsections {
            appendCompletedFrames(downTo: sub.level)
            let entry = NavWriter.Entry(
                title: sub.title,
                href: "\(chapterHref)#\(sub.anchorId)"
            )
            stack.append(Frame(entry: entry, level: sub.level))
        }
        // Drain whatever's left.
        appendCompletedFrames(downTo: Int.min)
        return rootChildren
    }
}
