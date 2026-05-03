import Foundation

/// A block-level unit of content. Mirrors the small set of HTML block
/// elements we actually emit. Extend as later phases add figures, lists,
/// footnotes, blockquotes, etc.
public enum Block: Sendable, Equatable {
    /// `<h1>` … `<h6>`. Level is clamped 1...6 by the writer.
    case heading(level: Int, runs: [InlineRun])

    /// `<p>`.
    case paragraph(runs: [InlineRun])
}
