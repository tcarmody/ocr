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

    public init(
        title: String,
        author: String? = nil,
        language: BCP47 = .en,
        identifier: String = "urn:uuid:\(UUID().uuidString.lowercased())",
        chapters: [Chapter] = []
    ) {
        self.title = title
        self.author = author
        self.language = language
        self.identifier = identifier
        self.chapters = chapters
    }
}
