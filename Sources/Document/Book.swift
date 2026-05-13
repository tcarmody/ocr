import Foundation

/// Canonical in-memory representation of a book, produced by the OCR/layout
/// pipeline and consumed by the EPUB writer. The IR deliberately knows
/// nothing about EPUB, XHTML, or PDFs — those concerns live one layer up.
public struct Book: Sendable, Equatable {
    public var title: String
    public var author: String?
    /// Default language for content. Per-run overrides via `InlineRun.language`.
    public var language: BCP47
    public var chapters: [Chapter]
    /// Stable identifier (e.g. a UUID URN) used as the EPUB unique identifier.
    public var identifier: String
    /// Publication year (4-digit string). Optional. Tier 9 / Q-Metadata
    /// populates this from a Haiku front-matter pass; user-built books
    /// can omit. Emitted as `<dc:date>` in the OPF when set.
    public var year: String?
    /// Publisher name as printed on the title / copyright page.
    /// Optional. Emitted as `<dc:publisher>` when set.
    public var publisher: String?
    /// ISBN-13 or ISBN-10 as printed on the copyright page. Optional.
    /// Stored as the raw digit string (no hyphens). Emitted as a
    /// secondary `<dc:identifier>` with `urn:isbn:` prefix.
    public var isbn: String?
    /// URL of the resource this book was derived from — typically
    /// the source PDF for OCR conversions, or a website / archive
    /// for hand-built books. Optional. Emitted as `<dc:source>` in
    /// the OPF when set (Dublin Core: "A related resource from
    /// which the described resource is derived"). The pipeline
    /// populates this from `pdfURL` at assembly time; manual
    /// edits flow through `OPFReader` / `EPUBBookSaver`.
    public var sourceURL: URL?

    public init(
        title: String,
        author: String? = nil,
        language: BCP47 = .en,
        identifier: String = "urn:uuid:\(UUID().uuidString.lowercased())",
        chapters: [Chapter] = [],
        year: String? = nil,
        publisher: String? = nil,
        isbn: String? = nil,
        sourceURL: URL? = nil
    ) {
        self.title = title
        self.author = author
        self.language = language
        self.identifier = identifier
        self.chapters = chapters
        self.year = year
        self.publisher = publisher
        self.isbn = isbn
        self.sourceURL = sourceURL
    }
}
