import Foundation

/// Render a book's annotations — highlights, notes (passages), and
/// bookmarks — as a Markdown document for export. Grouped by chapter
/// in reading order; highlights become blockquotes, notes a bold
/// `**Note:**` line, bookmarks a 🔖 marker. Pure and side-effect free
/// so the formatting is unit-testable; the view layer handles the
/// save panel / clipboard plumbing.
enum AnnotationMarkdownExporter {

    /// Build the Markdown export.
    ///
    /// - Parameters:
    ///   - bookTitle: Document title for the top-level heading.
    ///   - author: Optional author for the byline.
    ///   - annotations: Annotations **already sorted** in reading
    ///     order (chapter, then paragraph). Grouping keys off the
    ///     order as given — it does not re-sort.
    ///   - chapterTitles: spineIndex → chapter title. Missing entries
    ///     fall back to `Chapter {n+1}`.
    static func markdown(
        bookTitle: String,
        author: String?,
        annotations: [Annotation],
        chapterTitles: [Int: String]
    ) -> String {
        var out = "# \(trimmed(bookTitle).isEmpty ? "Untitled" : trimmed(bookTitle))\n"
        if let author = author.map(trimmed), !author.isEmpty {
            out += "*by \(author)*\n"
        }

        var lastChapter: Int?
        for annot in annotations {
            let body = entryMarkdown(annot)
            // Skip entries with nothing to show (e.g. a highlight whose
            // text never wrapped and carries no note).
            guard !body.isEmpty else { continue }
            if annot.chapterIdx != lastChapter {
                lastChapter = annot.chapterIdx
                let title = chapterTitles[annot.chapterIdx]
                    ?? "Chapter \(annot.chapterIdx + 1)"
                out += "\n## \(title)\n"
            }
            out += "\n\(body)\n"
        }
        return out
    }

    /// A filesystem-safe default filename (with `.md`) derived from the
    /// book title, e.g. `The Blue Book — Marks.md`.
    static func defaultFilename(bookTitle: String) -> String {
        let base = trimmed(bookTitle)
        let safeBase = base.isEmpty ? "Book" : base
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = safeBase
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return "\(cleaned.isEmpty ? "Book" : cleaned) — Marks.md"
    }

    // MARK: - private

    /// Markdown for a single annotation, or "" when there's nothing
    /// worth emitting.
    private static func entryMarkdown(_ annot: Annotation) -> String {
        switch annot.kind {
        case .bookmark:
            return "🔖 Bookmark"
        case .highlight, .passage:
            var parts: [String] = []
            if let text = annot.selectedText.map(trimmed), !text.isEmpty {
                let quoted = text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }
                    .joined(separator: "\n")
                parts.append(quoted)
            }
            if let note = annot.note.map(trimmed), !note.isEmpty {
                parts.append("**Note:** \(note)")
            }
            return parts.joined(separator: "\n\n")
        }
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
