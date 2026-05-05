import Foundation
import Document

/// Renders one `Chapter` to an XHTML string suitable for inclusion in an
/// EPUB 3 spine. Every inline run that has its own language tag emits
/// `<span xml:lang="..." lang="...">` so reader fonts and TTS can switch
/// scripts mid-paragraph.
struct XHTMLWriter {
    let cssPath: String  // relative path from chapter file to css, e.g. "../css/book.css"

    func render(_ chapter: Chapter, defaultLanguage: BCP47, fallbackTitle: String) -> String {
        let title = (chapter.title ?? fallbackTitle)
        let langAttr = defaultLanguage.rawValue

        let assetIndex = Dictionary(
            uniqueKeysWithValues: chapter.figureAssets.map { ($0.id, $0) }
        )

        var body = ""
        for block in chapter.blocks {
            switch block {
            case .heading(let level, let runs):
                let n = max(1, min(level, 6))
                body += "<h\(n)>\(renderRuns(runs, parentLanguage: defaultLanguage))</h\(n)>\n"
            case .paragraph(let runs):
                body += "<p>\(renderRuns(runs, parentLanguage: defaultLanguage))</p>\n"
            case .anchor(let id, let label):
                // Empty span — invisible in normal rendering. The
                // editor's IntersectionObserver targets `[id^="hu-page-"]`
                // for back-sync; readers honor epub:type="pagebreak"
                // for "skip to page N" navigation.
                let idAttr = XMLEscape.attribute(id)
                let labelAttr = XMLEscape.attribute(label)
                body += "<span id=\"\(idAttr)\" epub:type=\"pagebreak\" role=\"doc-pagebreak\" aria-label=\"\(labelAttr)\"></span>\n"
            case .figure(let assetId, let alt, let caption):
                // Skip silently when the asset is missing — chapter
                // splitting filters assets to only those referenced,
                // but a stale block can outlive its asset (e.g. tests
                // that build chapters by hand). Better an empty body
                // than a broken `<img>` tag with a dead src.
                guard let asset = assetIndex[assetId] else { continue }
                let href = "../images/\(asset.id).\(asset.fileExtension)"
                let hrefAttr = XMLEscape.attribute(href)
                let altAttr = XMLEscape.attribute(alt)
                var imgAttrs = "src=\"\(hrefAttr)\" alt=\"\(altAttr)\""
                if let size = asset.intrinsicSize {
                    imgAttrs += " width=\"\(Int(size.width))\""
                    imgAttrs += " height=\"\(Int(size.height))\""
                }
                body += "<figure>"
                body += "<img \(imgAttrs)/>"
                if !caption.isEmpty {
                    body += "<figcaption>"
                    body += renderRuns(caption, parentLanguage: defaultLanguage)
                    body += "</figcaption>"
                }
                body += "</figure>\n"
            case .table(let rows, let caption):
                body += renderTable(
                    rows: rows, caption: caption,
                    defaultLanguage: defaultLanguage
                )
            }
        }

        // Footnote popups. Asides are display:none in book.css; readers
        // (Apple Books, Thorium) hoist them into a popover when the
        // matching <a epub:type="noteref"> is tapped.
        if !chapter.footnotes.isEmpty {
            body += "<section epub:type=\"footnotes\" role=\"doc-endnotes\">\n"
            for fn in chapter.footnotes {
                let id = XMLEscape.attribute(fn.id)
                let marker = XMLEscape.text(fn.marker)
                let runs = renderRuns(fn.runs, parentLanguage: defaultLanguage)
                body += "<aside epub:type=\"footnote\" role=\"doc-footnote\" id=\"\(id)\">"
                body += "<p><span class=\"fn-marker\">\(marker)</span> \(runs)</p>"
                body += "</aside>\n"
            }
            body += "</section>\n"
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(langAttr)" lang="\(langAttr)">
        <head>
        <meta charset="utf-8"/>
        <title>\(XMLEscape.text(title))</title>
        <link rel="stylesheet" type="text/css" href="\(XMLEscape.attribute(cssPath))"/>
        </head>
        <body>
        \(body)</body>
        </html>
        """
    }

    /// Render a `Block.table` — `<table role="table">` with optional
    /// `<caption>`, plus `<thead>` for the leading run of all-header
    /// rows and `<tbody>` for the rest. Empty tables (zero rows) emit
    /// nothing rather than a degenerate empty `<table>`.
    private func renderTable(
        rows: [[TableCell]], caption: [InlineRun],
        defaultLanguage: BCP47
    ) -> String {
        guard !rows.isEmpty else { return "" }
        var out = "<table role=\"table\">\n"
        if !caption.isEmpty {
            out += "<caption>"
            out += renderRuns(caption, parentLanguage: defaultLanguage)
            out += "</caption>\n"
        }
        // Leading rows whose every cell is a header live in <thead>;
        // remaining rows go in <tbody>. Heuristic-built tables emit
        // all-data (no thead); a future Surya table-model integration
        // sets header flags correctly.
        let headerRowCount = rows.prefix { row in
            !row.isEmpty && row.allSatisfy { $0.isHeader }
        }.count
        if headerRowCount > 0 {
            out += "<thead>\n"
            for row in rows.prefix(headerRowCount) {
                out += renderRow(row, defaultLanguage: defaultLanguage)
            }
            out += "</thead>\n"
        }
        let bodyRows = Array(rows.dropFirst(headerRowCount))
        if !bodyRows.isEmpty {
            out += "<tbody>\n"
            for row in bodyRows {
                out += renderRow(row, defaultLanguage: defaultLanguage)
            }
            out += "</tbody>\n"
        }
        out += "</table>\n"
        return out
    }

    private func renderRow(_ row: [TableCell], defaultLanguage: BCP47) -> String {
        var out = "<tr>"
        for cell in row {
            let tag = cell.isHeader ? "th" : "td"
            var attrs = ""
            if cell.rowspan > 1 { attrs += " rowspan=\"\(cell.rowspan)\"" }
            if cell.colspan > 1 { attrs += " colspan=\"\(cell.colspan)\"" }
            let inner = renderRuns(cell.runs, parentLanguage: defaultLanguage)
            out += "<\(tag)\(attrs)>\(inner)</\(tag)>"
        }
        out += "</tr>\n"
        return out
    }

    private func renderRuns(_ runs: [InlineRun], parentLanguage: BCP47) -> String {
        runs.map { run in
            let escaped = XMLEscape.text(run.text)
            // Noteref runs render as a superscript link to the matching
            // <aside> at the end of the chapter. Language attrs still
            // apply (rare, but a Greek footnote marker should still be
            // language-tagged consistently).
            if let id = run.noterefId {
                let href = XMLEscape.attribute("#" + id)
                let inner: String
                if let lang = run.language, lang != parentLanguage {
                    let l = XMLEscape.attribute(lang.rawValue)
                    inner = "<span xml:lang=\"\(l)\" lang=\"\(l)\">\(escaped)</span>"
                } else {
                    inner = escaped
                }
                return "<a epub:type=\"noteref\" role=\"doc-noteref\" href=\"\(href)\">\(inner)</a>"
            }
            if let lang = run.language, lang != parentLanguage {
                let l = XMLEscape.attribute(lang.rawValue)
                return "<span xml:lang=\"\(l)\" lang=\"\(l)\">\(escaped)</span>"
            }
            return escaped
        }.joined()
    }
}
