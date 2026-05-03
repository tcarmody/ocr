import Foundation

/// A contiguous run of text with optional inline metadata (currently just
/// language). Inline styling (bold/italic) will be added when layout-aware
/// OCR can detect it; the walking skeleton only produces plain runs.
public struct InlineRun: Sendable, Equatable {
    public var text: String
    /// Overrides the parent block / book language for this run.
    public var language: BCP47?

    public init(_ text: String, language: BCP47? = nil) {
        self.text = text
        self.language = language
    }
}
