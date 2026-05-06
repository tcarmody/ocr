import Foundation
import Document

/// Renders the EPUB 3 navigation document (`nav.xhtml`). This is the
/// table of contents readers use; it must contain a `<nav epub:type="toc">`
/// element with an ordered list of links.
struct NavWriter {
    struct Entry: Sendable {
        var title: String
        var href: String
        /// EPUB 3 Structural Semantics Vocabulary token. When set,
        /// emitted as `epub:type="..."` on the entry's `<a>` so
        /// readers can surface semantic navigation hints (skip
        /// front matter, jump to bibliography).
        var epubType: String?

        init(title: String, href: String, epubType: String? = nil) {
            self.title = title
            self.href = href
            self.epubType = epubType
        }
    }

    let language: BCP47
    let title: String
    let entries: [Entry]

    func render() -> String {
        let lang = XMLEscape.attribute(language.rawValue)
        let docTitle = XMLEscape.text(title)
        let listItems = entries.map { e -> String in
            let typeAttr: String
            if let t = e.epubType, !t.isEmpty {
                typeAttr = " epub:type=\"\(XMLEscape.attribute(t))\""
            } else {
                typeAttr = ""
            }
            return "<li><a\(typeAttr) href=\"\(XMLEscape.attribute(e.href))\">\(XMLEscape.text(e.title))</a></li>"
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(lang)" lang="\(lang)">
        <head>
        <meta charset="utf-8"/>
        <title>\(docTitle)</title>
        </head>
        <body>
        <nav epub:type="toc" id="toc">
        <h1>\(docTitle)</h1>
        <ol>
        \(listItems)
        </ol>
        </nav>
        </body>
        </html>
        """
    }
}
