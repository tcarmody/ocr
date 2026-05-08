import Foundation

/// Render an `EPUBDiff` as a unified-diff-style plain-text report —
/// readable in any text editor, copy-pasteable into a PR or issue,
/// and the input the diff window's text view displays.
public enum EPUBDiffReporter {

    /// Format `diff` as a unified-diff report. Output structure:
    ///   * Header — file paths + summary counts
    ///   * Per-chapter blocks — `@@ Chapter N: Title @@` then `+` /
    ///     `-` / ` ` lines (matching git's convention)
    ///   * Unchanged paragraphs are elided with `…` markers when
    ///     surrounded by changes; large unchanged stretches print
    ///     as a single `… (N paragraphs unchanged) …` line so the
    ///     report doesn't bloat with copies of the source text.
    public static func report(_ diff: EPUBDiff) -> String {
        var out: [String] = []
        out.append("--- \(diff.leftURL.lastPathComponent)")
        out.append("+++ \(diff.rightURL.lastPathComponent)")
        out.append("")
        out.append(summary(diff))
        out.append("")

        for chapter in diff.chapterDiffs where chapter.hasChanges {
            out.append("@@ Chapter \(chapter.index + 1): \(chapter.rightTitle) @@")
            if chapter.isLeftMissing {
                out.append("[chapter added — present only in \(diff.rightURL.lastPathComponent)]")
            } else if chapter.isRightMissing {
                out.append("[chapter removed — present only in \(diff.leftURL.lastPathComponent)]")
            }
            out.append(contentsOf: renderChanges(chapter.changes))
            out.append("")
        }

        if diff.totalChanges == 0 {
            out.append("No paragraph-level changes.")
        }

        return out.joined(separator: "\n")
    }

    /// One-line summary describing the scope of the changes. Useful
    /// for the toolbar of the diff window or the alert preceding a
    /// "save report" action.
    public static func summary(_ diff: EPUBDiff) -> String {
        if diff.totalChanges == 0 {
            return "No paragraph-level changes between the two EPUBs."
        }
        return "\(diff.totalChanges) paragraph\(diff.totalChanges == 1 ? "" : "s") changed across \(diff.chaptersWithChanges) chapter\(diff.chaptersWithChanges == 1 ? "" : "s")."
    }

    /// Walk a chapter's change list and emit `+`/`-`/` ` lines.
    /// Collapses long runs of unchanged paragraphs into a single
    /// `… (N unchanged) …` line so the report stays readable.
    private static func renderChanges(_ changes: [ParagraphChange]) -> [String] {
        var out: [String] = []
        var unchangedRun: [String] = []

        func flushUnchanged() {
            guard !unchangedRun.isEmpty else { return }
            // Threshold: 2 unchanged paragraphs flanking a change get
            // emitted verbatim for context; larger runs collapse.
            if unchangedRun.count <= 2 {
                for p in unchangedRun {
                    out.append("  \(p)")
                }
            } else {
                out.append("  … (\(unchangedRun.count) paragraphs unchanged) …")
            }
            unchangedRun = []
        }

        for change in changes {
            switch change {
            case .unchanged(let text):
                unchangedRun.append(text)
            case .removed(let text):
                flushUnchanged()
                out.append("- \(text)")
            case .added(let text):
                flushUnchanged()
                out.append("+ \(text)")
            }
        }
        flushUnchanged()
        return out
    }
}
