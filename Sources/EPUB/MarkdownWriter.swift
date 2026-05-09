import Foundation
import Document

/// Tier 9 / V-Outputs. Renders a `Book` as a Markdown document.
/// Slightly richer than `PlainTextWriter` — preserves heading
/// levels, inline emphasis (best-effort: we don't track em/strong
/// at the inline-run level today, so emphasis is omitted in v1),
/// figure references via image links, table grids, and
/// `[^N]` footnote syntax.
///
/// Image links use `images/<assetId>.<ext>` paths matching the
/// EPUB's manifest layout. Readers that follow the link see the
/// figure when the .md sits next to a populated `images/`
/// directory; for a sibling-of-EPUB use case the link points
/// inside the .epub archive (won't resolve in standard MD
/// renderers, but the alt text + caption stay readable).
public enum MarkdownWriter {

    /// Render a book to Markdown.
    public static func render(_ book: Book) -> String {
        var out = ""
        out.append("# ")
        out.append(escapeForLine(book.title))
        out.append("\n\n")
        if let author = book.author, !author.isEmpty {
            out.append("*by ")
            out.append(escapeForLine(author))
            out.append("*\n\n")
        }
        if let year = book.year, !year.isEmpty {
            out.append("*\(escapeForLine(year))")
            if let publisher = book.publisher, !publisher.isEmpty {
                out.append(" · \(escapeForLine(publisher))")
            }
            out.append("*\n\n")
        }
        for chapter in book.chapters {
            renderChapter(chapter, into: &out)
        }
        while out.hasSuffix("\n\n\n") { out.removeLast() }
        return out
    }

    private static func renderChapter(_ chapter: Chapter, into out: inout String) {
        if let title = chapter.title, !title.isEmpty {
            out.append("## ")
            out.append(escapeForLine(title))
            out.append("\n\n")
        }
        for block in chapter.blocks {
            switch block {
            case .heading(let level, let runs):
                // Chapter title rendered as H2 above; in-chapter
                // headings start at H3 (level=2 → ###, level=3 → ####).
                // Clamp to ###### to stay valid Markdown.
                let n = max(3, min(level + 1, 6))
                let text = runs.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(String(repeating: "#", count: n))
                out.append(" ")
                out.append(escapeForLine(text))
                out.append("\n\n")
            case .paragraph(let runs):
                let text = renderRuns(runs)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(text)
                out.append("\n\n")
            case .figure(let assetId, let alt, let caption):
                let captionText = caption.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let displayAlt = captionText.isEmpty ? alt : captionText
                out.append("![\(escapeForBrackets(displayAlt))](images/\(assetId).png)\n")
                if !captionText.isEmpty {
                    out.append("*\(escapeForLine(captionText))*\n")
                }
                out.append("\n")
            case .table(let rows, let caption):
                let captionText = caption.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !captionText.isEmpty {
                    out.append("**\(escapeForLine(captionText))**\n\n")
                }
                renderTable(rows: rows, into: &out)
                out.append("\n")
            case .anchor:
                continue
            }
        }
        if !chapter.footnotes.isEmpty {
            for fn in chapter.footnotes {
                let text = fn.runs.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out.append("[^\(fn.marker)]: \(escapeForLine(text))\n")
            }
            out.append("\n")
        }
    }

    /// Render a table as a Markdown table. First row → header
    /// only when at least one cell carries `isHeader`. Otherwise
    /// the table renders without a header row, which most MD
    /// dialects accept (GitHub doesn't, but a single-row data
    /// table is a degenerate edge case anyway).
    private static func renderTable(rows: [[TableCell]], into out: inout String) {
        guard !rows.isEmpty else { return }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }

        let firstRowIsHeader = rows[0].contains { $0.isHeader }

        // Header row (or a synthesized blank one if all cells
        // are data — keeps GitHub-flavored Markdown happy).
        if firstRowIsHeader {
            renderRow(rows[0], columnCount: columns, into: &out)
        } else {
            renderRow(
                Array(repeating: TableCell(runs: []), count: columns),
                columnCount: columns, into: &out
            )
        }
        // Separator row.
        out.append("|")
        for _ in 0..<columns {
            out.append(" --- |")
        }
        out.append("\n")

        let bodyStart = firstRowIsHeader ? 1 : 0
        for row in rows[bodyStart...] {
            renderRow(row, columnCount: columns, into: &out)
        }
    }

    private static func renderRow(
        _ row: [TableCell], columnCount: Int, into out: inout String
    ) {
        out.append("|")
        for c in 0..<columnCount {
            out.append(" ")
            if c < row.count {
                let txt = row[c].runs.map(\.text).joined()
                    .replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\n", with: "<br>")
                out.append(txt)
            }
            out.append(" |")
        }
        out.append("\n")
    }

    /// Render inline runs to Markdown text. Emphasis maps to the
    /// canonical Markdown markers: `*…*` for italic, `**…**` for
    /// bold, `***…***` for both. Language spans don't have a clean
    /// Markdown equivalent; we drop them and rely on the EPUB for
    /// that.
    private static func renderRuns(_ runs: [InlineRun]) -> String {
        var out = ""
        for run in runs {
            if let id = run.noterefId, let n = noterefMarker(from: id) {
                out.append("[^\(n)]")
                continue
            }
            out.append(applyEmphasis(run.text, italic: run.isItalic, bold: run.isBold))
        }
        return out
    }

    private static func applyEmphasis(
        _ text: String, italic: Bool, bold: Bool
    ) -> String {
        // Skip wrapping for whitespace-only runs — `**  **` is
        // visible noise in plain Markdown viewers and Markdown's
        // emphasis is supposed to hug the text.
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty, italic || bold else { return text }
        let marker: String
        switch (bold, italic) {
        case (true, true):   marker = "***"
        case (true, false):  marker = "**"
        case (false, true):  marker = "*"
        case (false, false): return text
        }
        return marker + text + marker
    }

    /// `fn-pP-N` → `N`. Best-effort; falls back to nil.
    private static func noterefMarker(from id: String) -> String? {
        // The XHTML writer uses `fn-...` ids. Strip the `fn-`
        // prefix; Markdown's `[^N]` accepts arbitrary tokens.
        if id.hasPrefix("fn-") {
            return String(id.dropFirst("fn-".count))
        }
        return id
    }

    /// Escape characters that break Markdown line semantics —
    /// just newlines for now (titles + paragraphs occasionally
    /// carry embedded newlines from OCR).
    private static func escapeForLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }

    /// Escape `]` inside image alt text so the link tokenization
    /// doesn't mismatch.
    private static func escapeForBrackets(_ s: String) -> String {
        s.replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
