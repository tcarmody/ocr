import Foundation

/// A contiguous run of text with optional inline metadata (currently just
/// language). Inline styling (bold/italic) will be added when layout-aware
/// OCR can detect it; the walking skeleton only produces plain runs.
public struct InlineRun: Sendable, Equatable {
    public var text: String
    /// Overrides the parent block / book language for this run.
    public var language: BCP47?
    /// When set, the run renders as `<a epub:type="noteref" href="#id">`
    /// pointing at the matching `Footnote.id` on the same chapter. The
    /// run's `text` is the displayed marker (typically the same string
    /// as the footnote's `marker`).
    public var noterefId: String?

    public init(_ text: String, language: BCP47? = nil, noterefId: String? = nil) {
        self.text = text
        self.language = language
        self.noterefId = noterefId
    }
}
