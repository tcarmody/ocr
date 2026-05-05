import Foundation

/// One cell of a `Block.table`. Mirrors the small subset of HTML
/// table semantics we need: header vs data, row/column spans, and
/// inline content. The heuristic path leaves `isHeader=false` and
/// spans at 1; a future Surya table-model integration (Path A in the
/// Phase 6 plan) is the place to set those richer values.
public struct TableCell: Sendable, Equatable {
    /// Renders as `<th>` when true, `<td>` when false.
    public var isHeader: Bool
    /// HTML `rowspan` attribute. 1 ⇒ omitted from output (the default).
    public var rowspan: Int
    /// HTML `colspan` attribute. 1 ⇒ omitted from output.
    public var colspan: Int
    /// Inline content. Same `InlineRun` type used by paragraphs and
    /// headings, so per-language spans + future noteref splicing
    /// work for cells without further plumbing.
    public var runs: [InlineRun]

    public init(
        runs: [InlineRun],
        isHeader: Bool = false,
        rowspan: Int = 1,
        colspan: Int = 1
    ) {
        self.runs = runs
        self.isHeader = isHeader
        self.rowspan = rowspan
        self.colspan = colspan
    }
}
