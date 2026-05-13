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
    /// Image manifest entries (figures, cover). Already deduplicated
    /// by id at the caller. Empty for books with no figures.
    let imageItems: [Item]
    let modificationDate: Date

    func render() -> String {
        let modString = Self.iso8601(modificationDate)
        let title = XMLEscape.text(book.title)
        let identifier = XMLEscape.text(book.identifier)
        let language = XMLEscape.attribute(book.language.rawValue)
        let creator = book.author.map(XMLEscape.text)
        // Tier 9 / Q-Metadata extras. Each line emits only when
        // the field is non-nil + non-empty so OPF stays clean for
        // user-built books that don't supply this info.
        var extras: [String] = []
        if let year = book.year, !year.isEmpty {
            extras.append("<dc:date>\(XMLEscape.text(year))</dc:date>")
        }
        if let publisher = book.publisher, !publisher.isEmpty {
            extras.append("<dc:publisher>\(XMLEscape.text(publisher))</dc:publisher>")
        }
        if let isbn = book.isbn, !isbn.isEmpty {
            // Secondary identifier — primary stays the UUID URN
            // so the EPUB's unique-id attribute keeps a stable
            // ref. ISBN as a sibling lets readers + library tools
            // recognize the book.
            extras.append(
                "<dc:identifier>urn:isbn:\(XMLEscape.text(isbn))</dc:identifier>"
            )
        }
        if let source = book.sourceURL {
            // Dublin Core `<dc:source>`: "A related resource from
            // which the described resource is derived." For OCR
            // conversions that's the source PDF; for re-imports it
            // could be the original EPUB or a URL. Surfaces in
            // generic EPUB tools (Calibre, Sigil) so the provenance
            // travels with the file even outside Humanist.
            extras.append(
                "<dc:source>\(XMLEscape.text(source.absoluteString))</dc:source>"
            )
        }
        let extrasBlock = extras.isEmpty ? "" : extras.joined(separator: "\n") + "\n"

        let metadata = """
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">\(identifier)</dc:identifier>
        <dc:title>\(title)</dc:title>
        <dc:language>\(language)</dc:language>
        \(creator.map { "<dc:creator>\($0)</dc:creator>" } ?? "")
        \(extrasBlock)<meta property="dcterms:modified">\(modString)</meta>
        </metadata>
        """

        let allItems = [navItem, cssItem] + chapterItems + imageItems
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
