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

        var body = ""
        for block in chapter.blocks {
            switch block {
            case .heading(let level, let runs):
                let n = max(1, min(level, 6))
                body += "<h\(n)>\(renderRuns(runs, parentLanguage: defaultLanguage))</h\(n)>\n"
            case .paragraph(let runs):
                body += "<p>\(renderRuns(runs, parentLanguage: defaultLanguage))</p>\n"
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
