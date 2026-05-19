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

    /// P-Verse-Layout. Free-verse / irregular-poetry region. Emitted
    /// by `VerseDetector` when the region's geometry triggers the
    /// high-precision verse classifier (ragged right margin,
    /// irregular leading indents, short lines). Each `VerseLine`
    /// preserves its left-margin indent bucket so the XHTML output
    /// can recreate the printed layout via CSS.
    ///
    /// Does NOT collapse lines into paragraphs — the whole point is
    /// that line breaks and indentation are semantic. The
    /// `RegionAwareReflow` / `ParagraphReflow` prose-paragraph
    /// joining is bypassed for these regions.
    case verse(lines: [VerseLine])
}
