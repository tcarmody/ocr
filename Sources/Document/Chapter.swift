import Foundation

public struct Chapter: Sendable, Equatable {
    /// Display title for navigation. Optional for chapters that don't get one
    /// in the source (e.g. unstructured Phase-1 walking-skeleton output uses
    /// the source filename as the title).
    public var title: String?
    public var blocks: [Block]
    /// Footnotes referenced by `InlineRun.noterefId` inside `blocks`.
    /// Emitted as `<aside epub:type="footnote">` after the body — readers
    /// pop these up in response to noteref taps.
    public var footnotes: [Footnote]

    public init(title: String? = nil, blocks: [Block] = [], footnotes: [Footnote] = []) {
        self.title = title
        self.blocks = blocks
        self.footnotes = footnotes
    }
}
