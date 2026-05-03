import Foundation
import Document

/// Renders the EPUB 3 navigation document (`nav.xhtml`). This is the
/// table of contents readers use; it must contain a `<nav epub:type="toc">`
/// element with an ordered list of links.
struct NavWriter {
    struct Entry: Sendable {
        var title: String
        var href: String
    }

    let language: BCP47
    let title: String
    let entries: [Entry]

    func render() -> String {
        let lang = XMLEscape.attribute(language.rawValue)
        let docTitle = XMLEscape.text(title)
        let listItems = entries.map { e in
            "<li><a href=\"\(XMLEscape.attribute(e.href))\">\(XMLEscape.text(e.title))</a></li>"
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
