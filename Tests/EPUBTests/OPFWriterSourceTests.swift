import XCTest
import Foundation
import Document
@testable import EPUB

/// Coverage for `<dc:source>` emission. `OPFWriter` should emit
/// the source URL exactly once when `book.sourceURL` is set,
/// XML-escaped, and should omit it entirely when nil — matching
/// the same posture as the other optional Dublin Core fields.
final class OPFWriterSourceTests: XCTestCase {

    private func makeBook(sourceURL: URL?) -> Book {
        return Book(
            title: "Test Book",
            author: "Author",
            language: .en,
            identifier: "urn:uuid:11111111-1111-1111-1111-111111111111",
            chapters: [],
            sourceURL: sourceURL
        )
    }

    private func makeOPF(book: Book) -> String {
        let cssItem = OPFWriter.Item(
            id: "css", href: "css/book.css",
            mediaType: "text/css", properties: nil
        )
        let navItem = OPFWriter.Item(
            id: "nav", href: "nav.xhtml",
            mediaType: "application/xhtml+xml", properties: "nav"
        )
        return OPFWriter(
            book: book,
            chapterItems: [],
            navItem: navItem,
            cssItem: cssItem,
            imageItems: [],
            modificationDate: Date(timeIntervalSince1970: 0)
        ).render()
    }

    func test_emits_dc_source_when_set() {
        let book = makeBook(
            sourceURL: URL(fileURLWithPath: "/Users/me/Documents/foo.pdf")
        )
        let opf = makeOPF(book: book)
        XCTAssertTrue(
            opf.contains("<dc:source>file:///Users/me/Documents/foo.pdf</dc:source>"),
            "OPF should contain the source URL as a dc:source element\nGot:\n\(opf)"
        )
    }

    func test_omits_dc_source_when_nil() {
        let book = makeBook(sourceURL: nil)
        let opf = makeOPF(book: book)
        XCTAssertFalse(opf.contains("<dc:source>"),
            "OPF should not contain a dc:source element when sourceURL is nil")
    }

    func test_escapes_special_xml_chars_in_source_url() {
        // Spaces aren't legal in a URL but ampersand-bearing query
        // strings are — and they MUST be escaped or the OPF won't
        // parse. URL.absoluteString % - encodes spaces already; the
        // ampersand-escaping is the OPFWriter's responsibility.
        let url = URL(string: "https://example.org/book?id=1&edition=2")!
        let book = makeBook(sourceURL: url)
        let opf = makeOPF(book: book)
        XCTAssertTrue(
            opf.contains("<dc:source>https://example.org/book?id=1&amp;edition=2</dc:source>"),
            "Ampersand must be escaped to &amp; inside dc:source\nGot:\n\(opf)"
        )
    }
}
