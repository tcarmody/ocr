import Foundation
import Document

/// Tier 9 / V-Outputs. Renders a `Book` as a plain UTF-8 text
/// document — readable in any editor, useful for piping into
/// search / archival / RAG pipelines, and small enough that
/// it's cheap to ship alongside every EPUB.
///
/// Text-only: structural elements (headings, paragraphs,
/// captions, footnote bodies) all render as flat lines.
/// Anchors / figure images / table grids are summarized with
/// short bracketed placeholders so the output stays readable
/// without trying to be lossless. The EPUB itself is the
/// canonical structured output.
public enum PlainTextWriter {

    /// Render a book to plain text. UTF-8 encoded by the
    /// caller's writer; this returns a `String`.
    public static func render(_ book: Book) -> String {
        var out = ""
        out.append(book.title)
        out.append("\n")
        if let author = book.author, !author.isEmpty {
            out.append("by ")
            out.append(author)
            out.append("\n")
        }
        out.append("\n")
        for (idx, chapter) in book.chapters.enumerated() {
            if idx > 0 { out.append("\n\n") }
            renderChapter(chapter, into: &out)
        }
        // Trim a final trailing newline run so consecutive runs
        // through this writer round-trip cleanly.
        while out.hasSuffix("\n\n") { out.removeLast() }
        return out
    }

    private static func renderChapter(_ chapter: Chapter, into out: inout String) {
        if let title = chapter.title, !title.isEmpty {
            out.append(title)
            out.append("\n")
            out.append(String(repeating: "=", count: min(title.count, 60)))
            out.append("\n\n")
        }
        for block in chapter.blocks {
            switch block {
            case .heading(_, let runs):
                let text = runs.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(text)
                out.append("\n\n")
            case .paragraph(let runs):
                let text = runs.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(text)
                out.append("\n\n")
            case .figure(_, let alt, let caption):
                let captionText = caption.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if captionText.isEmpty {
                    out.append("[Figure: \(alt)]\n\n")
                } else {
                    out.append("[Figure: \(captionText)]\n\n")
                }
            case .table(let rows, let caption):
                let captionText = caption.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if captionText.isEmpty {
                    out.append("[Table — \(rows.count) rows]\n\n")
                } else {
                    out.append("[Table: \(captionText) — \(rows.count) rows]\n\n")
                }
            case .anchor:
                continue
            case .verse(let lines):
                for line in lines {
                    let text = line.runs.map(\.text).joined()
                    if text.isEmpty {
                        out.append("\n")
                        continue
                    }
                    // Preserve indent in plain-text by leading
                    // spaces — two per indent bucket.
                    out.append(String(repeating: " ", count: line.indent * 2))
                    out.append(text)
                    out.append("\n")
                }
                out.append("\n")
            }
        }
        if !chapter.footnotes.isEmpty {
            out.append("Notes\n")
            out.append(String(repeating: "-", count: 5))
            out.append("\n")
            for fn in chapter.footnotes {
                let text = fn.runs.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out.append("\(fn.marker). \(text)\n")
            }
            out.append("\n")
        }
    }
}
