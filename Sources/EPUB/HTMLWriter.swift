import Foundation
import Document

/// Tier 9 / V-Outputs. Renders a `Book` as a single self-contained
/// HTML5 document — one `<section>` per chapter, inline CSS,
/// no external assets. Sits alongside the `.txt` and `.md`
/// siblings as a "send this to anyone" fallback that opens in any
/// browser without unzipping the EPUB.
///
/// The XHTML written into the EPUB itself is split per-chapter,
/// references images at `OEBPS/images/...`, and assumes a host
/// reader resolves relative paths. This writer instead concatenates
/// every chapter into one document and intentionally inlines the
/// styling so the output stands on its own when emailed / dropped
/// into Drive / read in Safari.
public enum HTMLWriter {

    /// Render the book to a complete HTML5 document.
    public static func render(_ book: Book) -> String {
        var out = ""
        out.append("<!DOCTYPE html>\n")
        out.append("<html lang=\"\(escAttr(book.language.rawValue))\">\n")
        out.append("<head>\n")
        out.append("  <meta charset=\"utf-8\">\n")
        out.append("  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
        out.append("  <title>\(esc(book.title))</title>\n")
        if let author = book.author, !author.isEmpty {
            out.append("  <meta name=\"author\" content=\"\(escAttr(author))\">\n")
        }
        out.append("  <style>\n")
        out.append(defaultStylesheet)
        out.append("  </style>\n")
        out.append("</head>\n")
        out.append("<body>\n")
        out.append("<header class=\"book-meta\">\n")
        out.append("  <h1 class=\"book-title\">\(esc(book.title))</h1>\n")
        if let author = book.author, !author.isEmpty {
            out.append("  <p class=\"byline\">by \(esc(author))</p>\n")
        }
        if let year = book.year, !year.isEmpty {
            out.append("  <p class=\"pubinfo\">\(esc(year))")
            if let publisher = book.publisher, !publisher.isEmpty {
                out.append(" · \(esc(publisher))")
            }
            out.append("</p>\n")
        }
        out.append("</header>\n")
        for (idx, chapter) in book.chapters.enumerated() {
            renderChapter(chapter, index: idx, into: &out)
        }
        out.append("</body>\n")
        out.append("</html>\n")
        return out
    }

    // MARK: - chapter

    private static func renderChapter(_ chapter: Chapter, index: Int, into out: inout String) {
        out.append("<section class=\"chapter\" id=\"chapter-\(index + 1)\">\n")
        if let title = chapter.title, !title.isEmpty {
            out.append("  <h2 class=\"chapter-title\">\(esc(title))</h2>\n")
        }
        for block in chapter.blocks {
            switch block {
            case .heading(let level, let runs):
                // Mirror MarkdownWriter: chapter title is h2, in-
                // chapter headings start at h3.
                let n = max(3, min(level + 2, 6))
                let body = renderRuns(runs)
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                out.append("  <h\(n)>\(body)</h\(n)>\n")
            case .paragraph(let runs):
                let body = renderRuns(runs)
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                out.append("  <p>\(body)</p>\n")
            case .figure(let assetId, let alt, let caption):
                out.append("  <figure>\n")
                // The sibling HTML can't actually load images out of
                // the EPUB at the relative path we'd use; ship a
                // placeholder so the figure's role stays visible.
                out.append("    <div class=\"figure-placeholder\">[Figure: \(esc(assetId))]</div>\n")
                let captionText = caption.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let displayCaption = captionText.isEmpty ? alt : captionText
                if !displayCaption.isEmpty {
                    out.append("    <figcaption>\(esc(displayCaption))</figcaption>\n")
                }
                out.append("  </figure>\n")
            case .table(let rows, let caption):
                renderTable(rows: rows, caption: caption, into: &out)
            case .anchor:
                continue
            case .verse(let lines):
                out.append("  <div class=\"verse\">\n")
                for line in lines {
                    let cls = line.indent > 0
                        ? "line indent-\(line.indent)"
                        : "line"
                    let body = renderRuns(line.runs)
                    out.append("    <p class=\"\(cls)\">\(body)</p>\n")
                }
                out.append("  </div>\n")
            }
        }
        if !chapter.footnotes.isEmpty {
            out.append("  <section class=\"notes\">\n")
            out.append("    <h3>Notes</h3>\n")
            out.append("    <ol>\n")
            for fn in chapter.footnotes {
                let text = renderRuns(fn.runs)
                out.append("      <li id=\"fn-\(escAttr(fn.id))\">\(text)</li>\n")
            }
            out.append("    </ol>\n")
            out.append("  </section>\n")
        }
        out.append("</section>\n")
    }

    private static func renderTable(rows: [[TableCell]], caption: [InlineRun], into out: inout String) {
        out.append("  <table>\n")
        let captionText = caption.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !captionText.isEmpty {
            out.append("    <caption>\(esc(captionText))</caption>\n")
        }
        guard !rows.isEmpty else {
            out.append("  </table>\n")
            return
        }
        let firstRowIsHeader = rows[0].contains { $0.isHeader }
        if firstRowIsHeader {
            out.append("    <thead>\n")
            renderRow(rows[0], cellTag: "th", into: &out)
            out.append("    </thead>\n")
        }
        let bodyStart = firstRowIsHeader ? 1 : 0
        if bodyStart < rows.count {
            out.append("    <tbody>\n")
            for row in rows[bodyStart...] {
                renderRow(row, cellTag: "td", into: &out)
            }
            out.append("    </tbody>\n")
        }
        out.append("  </table>\n")
    }

    private static func renderRow(_ row: [TableCell], cellTag: String, into out: inout String) {
        out.append("      <tr>")
        for cell in row {
            let body = renderRuns(cell.runs)
            let tag = cell.isHeader ? "th" : cellTag
            out.append("<\(tag)>\(body)</\(tag)>")
        }
        out.append("</tr>\n")
    }

    // MARK: - inline

    private static func renderRuns(_ runs: [InlineRun]) -> String {
        var out = ""
        for run in runs {
            if let id = run.noterefId {
                out.append("<sup><a href=\"#fn-\(escAttr(id))\">[\(esc(run.text))]</a></sup>")
                continue
            }
            let text = esc(run.text)
            switch (run.isBold, run.isItalic) {
            case (true, true):   out.append("<strong><em>\(text)</em></strong>")
            case (true, false):  out.append("<strong>\(text)</strong>")
            case (false, true):  out.append("<em>\(text)</em>")
            case (false, false): out.append(text)
            }
        }
        return out
    }

    // MARK: - escaping

    /// Escape `<`, `>`, `&` for element content. Quotes pass through
    /// — they're only meaningful inside attribute values, where
    /// `escAttr` handles them.
    private static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            default:  out.append(c)
            }
        }
        return out
    }

    /// Escape for a double-quoted attribute value.
    private static func escAttr(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&":  out.append("&amp;")
            case "<":  out.append("&lt;")
            case ">":  out.append("&gt;")
            case "\"": out.append("&quot;")
            default:   out.append(c)
            }
        }
        return out
    }

    // MARK: - styling

    /// Inline stylesheet. Kept short on purpose — the goal is "looks
    /// pleasant in any browser without effort," not a full design
    /// system. Users who want richer styling open the EPUB directly.
    private static let defaultStylesheet: String = """
        :root {
          --text: #1d1d1f;
          --muted: #6e6e73;
          --border: #d2d2d7;
          --bg: #ffffff;
          --max-width: 38rem;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --text: #f5f5f7;
            --muted: #98989d;
            --border: #3a3a3c;
            --bg: #1d1d1f;
          }
        }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue",
                       "Segoe UI", system-ui, sans-serif;
          font-size: 17px;
          line-height: 1.55;
          color: var(--text);
          background: var(--bg);
          margin: 0;
          padding: 2.5rem 1.25rem 6rem;
        }
        body > * { max-width: var(--max-width); margin-left: auto; margin-right: auto; }
        header.book-meta { text-align: center; margin-bottom: 3rem; }
        h1.book-title { font-size: 2rem; margin-bottom: 0.25rem; }
        .byline, .pubinfo { color: var(--muted); margin: 0.25rem 0; }
        section.chapter { margin-bottom: 3rem; }
        h2.chapter-title { font-size: 1.6rem; border-bottom: 1px solid var(--border); padding-bottom: 0.4rem; }
        h3, h4, h5, h6 { margin-top: 1.6em; }
        p { margin: 0 0 1em; text-align: justify; hyphens: auto; }
        em { font-style: italic; }
        strong { font-weight: 600; }
        sup { font-size: 0.75em; }
        figure { margin: 1.5rem 0; text-align: center; }
        .figure-placeholder {
          padding: 1rem; border: 1px dashed var(--border);
          color: var(--muted); font-size: 0.9rem;
        }
        figcaption { color: var(--muted); font-size: 0.9rem; margin-top: 0.4rem; }
        table { border-collapse: collapse; width: 100%; margin: 1.5rem 0; }
        caption { text-align: left; color: var(--muted); padding-bottom: 0.4rem; }
        th, td { border: 1px solid var(--border); padding: 0.4rem 0.6rem; text-align: left; }
        thead th { background: rgba(0,0,0,0.04); }
        section.notes { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid var(--border); }
        section.notes h3 { font-size: 1rem; color: var(--muted); }

        """
}
