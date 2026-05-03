import Foundation
import Document

/// Renders the EPUB 3 package document (`content.opf`).
///
/// The OPF lists every file in the EPUB (manifest), declares reading
/// order (spine), and carries Dublin Core metadata. Anything not in the
/// manifest will be invisible to readers; anything not in the spine
/// won't appear in the linear reading flow.
struct OPFWriter {
    struct Item: Sendable {
        var id: String
        var href: String         // relative to OPF location (we put OPF in OEBPS/)
        var mediaType: String
        var properties: String?  // e.g. "nav" for the nav doc
    }

    let book: Book
    let chapterItems: [Item]
    let navItem: Item
    let cssItem: Item
    let modificationDate: Date

    func render() -> String {
        let modString = Self.iso8601(modificationDate)
        let title = XMLEscape.text(book.title)
        let identifier = XMLEscape.text(book.identifier)
        let language = XMLEscape.attribute(book.language.rawValue)
        let creator = book.author.map(XMLEscape.text)

        let metadata = """
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">\(identifier)</dc:identifier>
        <dc:title>\(title)</dc:title>
        <dc:language>\(language)</dc:language>
        \(creator.map { "<dc:creator>\($0)</dc:creator>" } ?? "")
        <meta property="dcterms:modified">\(modString)</meta>
        </metadata>
        """

        let allItems = [navItem, cssItem] + chapterItems
        let manifest = "<manifest>\n" + allItems.map { item in
            let propsAttr = item.properties.map { " properties=\"\(XMLEscape.attribute($0))\"" } ?? ""
            return "<item id=\"\(XMLEscape.attribute(item.id))\" href=\"\(XMLEscape.attribute(item.href))\" media-type=\"\(XMLEscape.attribute(item.mediaType))\"\(propsAttr)/>"
        }.joined(separator: "\n") + "\n</manifest>"

        // Spine order is chapter files only. The nav doc is in the manifest
        // (with properties="nav") but is not part of the linear reading
        // flow unless we add it to the spine — we don't.
        let spine = "<spine>\n" + chapterItems.map { item in
            "<itemref idref=\"\(XMLEscape.attribute(item.id))\"/>"
        }.joined(separator: "\n") + "\n</spine>"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(language)">
        \(metadata)
        \(manifest)
        \(spine)
        </package>
        """
    }

    private static func iso8601(_ date: Date) -> String {
        // EPUB requires CCYY-MM-DDThh:mm:ssZ — no fractional seconds, UTC.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }
}
