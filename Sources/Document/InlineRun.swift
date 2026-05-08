import Foundation

/// A contiguous run of text with optional inline metadata (language,
/// emphasis, footnote reference). Layout-aware OCR (Claude page-OCR
/// today; Tesseract per-word italic/bold in the future) sets
/// `isItalic` / `isBold` when it detects emphasis; the local Vision
/// pathway leaves them false.
public struct InlineRun: Sendable, Equatable, Codable {
    public var text: String
    /// Overrides the parent block / book language for this run.
    public var language: BCP47?
    /// When set, the run renders as `<a epub:type="noteref" href="#id">`
    /// pointing at the matching `Footnote.id` on the same chapter. The
    /// run's `text` is the displayed marker (typically the same string
    /// as the footnote's `marker`).
    public var noterefId: String?
    /// Italic emphasis. Rendered as `<em>` in XHTML, `*…*` in
    /// Markdown, plain text in `.txt`.
    public var isItalic: Bool
    /// Bold emphasis. Rendered as `<strong>` in XHTML, `**…**` in
    /// Markdown, plain text in `.txt`.
    public var isBold: Bool

    public init(
        _ text: String,
        language: BCP47? = nil,
        noterefId: String? = nil,
        isItalic: Bool = false,
        isBold: Bool = false
    ) {
        self.text = text
        self.language = language
        self.noterefId = noterefId
        self.isItalic = isItalic
        self.isBold = isBold
    }
}
