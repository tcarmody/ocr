import Foundation
import PDFKit

/// One bookmark entry from a PDF's outline (also called the
/// document outline or bookmarks tree). Flattened from the
/// publisher's nested tree by `PDFOutlineExtractor` — Parts +
/// Chapters become siblings in document order, deeper nesting
/// (sub-sections, individual figure captions, etc.) is dropped.
///
/// Sendable + Codable so the pipeline can pass an outline through
/// the splitter dispatch without dragging PDFKit types beyond the
/// extractor's boundary.
public struct OutlineEntry: Sendable, Equatable, Codable {
    public let title: String
    /// Zero-based PDF page index the bookmark points at.
    public let pdfPage: Int

    public init(title: String, pdfPage: Int) {
        self.title = title
        self.pdfPage = pdfPage
    }
}

/// Walks the PDF's outline (publisher-set bookmarks) and produces
/// a flat `[OutlineEntry]` list in document order. Used by the
/// chapter splitter as the highest-confidence boundary source —
/// when a PDF carries an outline, the bookmark page numbers are
/// authoritative (no offset learning, no title-matching against
/// possibly-mangled OCR'd headings).
///
/// Filtering:
///   * **Depth cap** (`maxDepth = 2`). Outlines often have many
///     levels (Part → Chapter → Section → Sub-section). We only
///     want chapter-coarse breaks; deeper levels would shatter
///     each chapter into dozens of micro-chapters.
///   * **Empty / blank titles dropped**. Some PDFs have outline
///     entries that are placeholders for grouping with no
///     visible label.
///   * **Entries without a resolvable page** dropped. Rare but
///     possible when a bookmark targets a `\NamedDest` that
///     PDFKit can't resolve.
public enum PDFOutlineExtractor {

    /// Default depth cap. Outline levels deeper than this are
    /// skipped during the walk. 2 covers the Part/Chapter case
    /// without admitting sub-section noise.
    public static let maxDepth: Int = 2

    /// Walk `document.outlineRoot` and return a flat list of
    /// `OutlineEntry`s in document order. Returns an empty array
    /// when the PDF carries no outline (very common for scanned
    /// PDFs without OCR bookmark metadata) — callers fall through
    /// to the parsed-TOC / heuristic paths in that case.
    public static func extract(from document: PDFDocument) -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var out: [OutlineEntry] = []
        walk(node: root, depth: 0, document: document, into: &out)
        return out
    }

    private static func walk(
        node: PDFOutline,
        depth: Int,
        document: PDFDocument,
        into out: inout [OutlineEntry]
    ) {
        // The outlineRoot itself is unlabeled; its children are
        // the visible bookmarks. Recurse into children regardless
        // of whether we emit an entry for the current node.
        if depth > 0 {
            if let entry = entry(from: node, document: document) {
                out.append(entry)
            }
        }
        // Children at depth+1; cap to `maxDepth` so chapter-level
        // entries land but section-level entries (depth ≥ 3) don't.
        guard depth < maxDepth else { return }
        for i in 0..<node.numberOfChildren {
            guard let child = node.child(at: i) else { continue }
            walk(node: child, depth: depth + 1,
                 document: document, into: &out)
        }
    }

    private static func entry(
        from node: PDFOutline, document: PDFDocument
    ) -> OutlineEntry? {
        let rawLabel = node.label ?? ""
        let title = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        guard let page = node.destination?.page else { return nil }
        let idx = document.index(for: page)
        guard idx >= 0 else { return nil }
        return OutlineEntry(title: title, pdfPage: idx)
    }
}
