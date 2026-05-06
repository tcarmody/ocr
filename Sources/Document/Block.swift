import Foundation

/// A block-level unit of content. Mirrors the small set of HTML block
/// elements we actually emit. Extend as later phases add figures, lists,
/// footnotes, blockquotes, etc.
public enum Block: Sendable, Equatable, Codable {
    /// `<h1>` … `<h6>`. Level is clamped 1...6 by the writer.
    case heading(level: Int, runs: [InlineRun])

    /// `<p>`.
    case paragraph(runs: [InlineRun])

    /// Invisible page-boundary marker. Rendered as an empty
    /// `<span id="..." epub:type="pagebreak" role="doc-pagebreak"
    /// aria-label="Page N">`. Used by the editor's linked-navigation
    /// feature to align preview scroll with PDF page; honored by EPUB
    /// readers as a print-page break for "skip to page N" navigation.
    case anchor(id: String, label: String)

    /// `<figure>` with an embedded image and optional caption.
    /// `assetId` keys into the owning `Chapter.figureAssets`; the EPUB
    /// writer resolves it to the right `OEBPS/images/...` href when
    /// rendering. `alt` is the `<img alt>` (accessibility); `caption`
    /// is the inline runs that render inside `<figcaption>` (empty
    /// caption ⇒ no figcaption element).
    case figure(assetId: String, alt: String, caption: [InlineRun])

    /// `<table>` with cells laid out as a 2D grid. `rows` is row-major;
    /// each row is a list of cells in left-to-right order. `caption`
    /// renders inside `<caption>` directly under the `<table>` (empty
    /// ⇒ no caption element). The first row's `isHeader` flags drive
    /// `<thead>` placement; remaining rows go in `<tbody>`.
    case table(rows: [[TableCell]], caption: [InlineRun])
}
