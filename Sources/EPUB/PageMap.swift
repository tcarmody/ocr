import Foundation
import Document

/// Editor-only sidecar mapping each PDF page to the XHTML anchor that
/// marks where the OCR'd content from that page begins. Written by
/// `EPUBBuilder` to `META-INF/com.humanist.pagemap.json` when any
/// chapter has page anchors; read by the editor's linked-navigation
/// feature on open. Standard EPUB readers ignore unknown META-INF
/// files, so the sidecar round-trips through other tools cleanly.
public struct PageMap: Sendable, Equatable, Codable {
    public var entries: [Entry]

    public struct Entry: Sendable, Equatable, Codable {
        /// Zero-based PDF page index.
        public var pdfPage: Int
        /// Path of the XHTML file inside the EPUB ZIP, e.g.
        /// `OEBPS/text/chapter-001.xhtml`. Same form `EPUBPackager`
        /// uses, so the editor can resolve it against the unpacked
        /// working directory directly.
        public var xhtmlFile: String
        /// Element id within `xhtmlFile`. Matches the `<span id="...">`
        /// the XHTML writer emits for `Block.anchor` blocks.
        public var anchorId: String

        public init(pdfPage: Int, xhtmlFile: String, anchorId: String) {
            self.pdfPage = pdfPage
            self.xhtmlFile = xhtmlFile
            self.anchorId = anchorId
        }
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Path of the sidecar inside an unpacked EPUB working directory.
    public static let pathInsideEPUB = "META-INF/com.humanist.pagemap.json"

    /// Read the pagemap from a working directory. Returns nil when
    /// the file is missing (older EPUBs, or EPUBs not produced by
    /// Humanist) — the editor's sync feature stays dormant in that
    /// case.
    public static func read(workingDirectory: URL) -> PageMap? {
        let url = workingDirectory.appendingPathComponent(pathInsideEPUB)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PageMap.self, from: data)
    }
}
