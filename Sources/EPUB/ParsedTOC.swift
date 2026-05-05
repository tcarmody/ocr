import Foundation

/// Editor-only sidecar carrying the printed table of contents as
/// parsed by Haiku at conversion time. Mirrors the shape of
/// `PageMap` and `CorrectionTrail`: written to META-INF when the
/// conversion produced any TOC entries; standard EPUB readers
/// ignore unknown META-INF files so the sidecar round-trips
/// cleanly.
///
/// Entries store the page number **as printed in the TOC** —
/// usually the displayed-page form (`23`, `xviii`). The pipeline
/// also stores `pdfPageHint` when it was able to map the entry to
/// a PDF page index (via offset learning); that's what
/// `nav.xhtml` ultimately points to.
public struct ParsedTOC: Sendable, Equatable, Codable {
    public var entries: [Entry]
    /// Inferred offset between display page numbers and PDF page
    /// indices. `pdf_index = display_page + offset - 1` (because
    /// PDF indices are 0-based). `nil` when offset learning
    /// couldn't find a confident match (degenerate TOC, hostile
    /// pagination). Surfaced for debugging.
    public var inferredOffset: Int?

    public struct Entry: Sendable, Equatable, Codable, Identifiable {
        public var id: UUID
        /// Title as printed in the TOC.
        public var title: String
        /// Page number as printed in the TOC. Stored as the raw
        /// string ("23", "xviii", "1.4") so non-arabic numerals
        /// and section numbers survive — `displayPageInt` parses
        /// the arabic form.
        public var displayPage: String
        /// Optional PDF page index (0-based) the entry was
        /// matched to during offset learning. Nil when the entry
        /// couldn't be mapped (typically front-matter entries
        /// with roman-numeral display pages).
        public var pdfPageHint: Int?

        public init(
            id: UUID = UUID(),
            title: String,
            displayPage: String,
            pdfPageHint: Int? = nil
        ) {
            self.id = id
            self.title = title
            self.displayPage = displayPage
            self.pdfPageHint = pdfPageHint
        }

        /// Arabic-form of `displayPage` if it parses — the offset
        /// learner uses this; roman-numeral entries return nil.
        public var displayPageInt: Int? {
            Int(displayPage.trimmingCharacters(in: .whitespaces))
        }
    }

    public init(entries: [Entry], inferredOffset: Int? = nil) {
        self.entries = entries
        self.inferredOffset = inferredOffset
    }

    public static let pathInsideEPUB = "META-INF/com.humanist.parsed-toc.json"

    public static func read(workingDirectory: URL) -> ParsedTOC? {
        let url = workingDirectory.appendingPathComponent(pathInsideEPUB)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ParsedTOC.self, from: data)
    }
}
