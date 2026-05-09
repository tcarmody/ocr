import ArgumentParser

/// One of the output formats the conversion pipeline can produce.
/// Mirrors the toggle set in the launcher's options strip plus the
/// implicit "EPUB is always available" assumption.
enum OutputFormat: String, CaseIterable, ExpressibleByArgument, Sendable {
    case epub
    case md          // Markdown, preserves headings + footnotes + tables
    case txt         // Plain text — no markup
    case html        // Self-contained HTML5 with inline CSS
    case docx        // Microsoft Word OOXML
    case searchablePdf = "searchable-pdf"

    /// File extension for the output format (no leading dot).
    var fileExtension: String {
        switch self {
        case .epub: return "epub"
        case .md: return "md"
        case .txt: return "txt"
        case .html: return "html"
        case .docx: return "docx"
        case .searchablePdf: return "searchable.pdf"
        }
    }

    /// Whether the format can only be produced from a PDF input
    /// (i.e. requires the OCR pipeline running). `searchable-pdf`
    /// reuses the `TextObservation` arrays the OCR cascade
    /// produces; it can't be made from a TXT/MD/HTML/DOCX/ODT input.
    var requiresPDFInput: Bool {
        switch self {
        case .searchablePdf: return true
        default:             return false
        }
    }
}
