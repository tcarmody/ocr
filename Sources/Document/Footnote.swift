import Foundation

/// A footnote attached to a chapter. Rendered by the EPUB writer as an
/// `<aside epub:type="footnote" id="...">` at the end of the chapter
/// XHTML; readers (Apple Books, Thorium, Kobo) hoist these into popovers
/// when the matching `<a epub:type="noteref" href="#id">` is tapped.
public struct Footnote: Sendable, Equatable, Identifiable {
    /// Stable identifier used as the XHTML `id` and noteref href target.
    /// Format used by the linker: `fn-p{pageIndex}-{marker}` so two
    /// footnotes both labelled "1" on different pages don't collide.
    public var id: String
    /// Displayed marker (e.g. "1", "*", "a"). Echoes the source so the
    /// inline noteref text and the aside's leading marker match.
    public var marker: String
    /// Footnote body, post-marker. Same inline-run model as a paragraph.
    public var runs: [InlineRun]

    public init(id: String, marker: String, runs: [InlineRun]) {
        self.id = id
        self.marker = marker
        self.runs = runs
    }
}
