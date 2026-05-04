import Foundation

/// One page-boundary anchor inside a chapter. Pairs the source PDF
/// page with the XHTML anchor id so the editor can sync the preview
/// pane's scroll position to the PDF viewer's current page (and the
/// other direction). Carried alongside `Chapter.blocks`; the
/// `EPUBBuilder` collapses these into a global `META-INF/com.humanist.pagemap.json`
/// sidecar at build time.
public struct PageAnchor: Sendable, Equatable, Codable {
    /// Zero-based PDF page index this anchor came from.
    public var pdfPage: Int
    /// XHTML element id; matches the `<span id="...">` in the chapter.
    public var anchorId: String

    public init(pdfPage: Int, anchorId: String) {
        self.pdfPage = pdfPage
        self.anchorId = anchorId
    }
}
