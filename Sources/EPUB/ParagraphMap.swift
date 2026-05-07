import Foundation
import Document

/// Editor-only sidecar mapping each `<p id="hu-p-X-Y">` paragraph
/// anchor to the PDF page + bbox the paragraph was OCR'd from.
/// Written by `EPUBBuilder` to
/// `META-INF/com.humanist.paragraph-map.json` when any chapter
/// has paragraph entries; read by the editor's
/// `Re-OCR Current Paragraph` command + paragraph-precision
/// PDF-to-source/preview alignment.
///
/// Tier 9 / paragraph-level alignment Pass B. Standard EPUB
/// readers ignore unknown META-INF files, so the sidecar
/// round-trips through other tools cleanly.
///
/// Only populated by the cascade OCR path — the page-OCR (Sonnet)
/// path returns flat XHTML without per-paragraph PDF coordinates,
/// so EPUBs from that path carry no paragraph map. The editor
/// degrades gracefully: paragraph re-OCR + paragraph-precision
/// PDF sync are unavailable on those EPUBs; page-precision sync
/// (via `PageMap`) still works.
public struct ParagraphMap: Sendable, Equatable, Codable {
    public var entries: [Entry]

    public struct Entry: Sendable, Equatable, Codable {
        /// `<p id="...">` value, format `hu-p-{chapterIdx}-{paraIdx}`.
        public var paragraphId: String
        /// Path of the XHTML file inside the EPUB ZIP. Matches
        /// `PageMap.Entry.xhtmlFile` shape so the editor can
        /// resolve against the unpacked working directory.
        public var xhtmlFile: String
        /// Zero-based PDF page index this paragraph was rendered
        /// from. Multiple paragraphs may map to the same page;
        /// the editor uses the first such entry as the anchor for
        /// "topmost paragraph on this PDF page."
        public var pdfPage: Int
        /// Bounding box of the paragraph's source observations on
        /// the PDF page, in normalized coords (0-1, bottom-left
        /// origin). Same convention `TextObservation.box` uses.
        /// Bbox is the union of all observations that contributed
        /// to this paragraph block, so a paragraph that wraps
        /// multiple lines covers all of them.
        public var bbox: BBox

        public init(
            paragraphId: String,
            xhtmlFile: String,
            pdfPage: Int,
            bbox: BBox
        ) {
            self.paragraphId = paragraphId
            self.xhtmlFile = xhtmlFile
            self.pdfPage = pdfPage
            self.bbox = bbox
        }
    }

    public struct BBox: Sendable, Equatable, Codable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public static let pathInsideEPUB = "META-INF/com.humanist.paragraph-map.json"

    public static func read(workingDirectory: URL) -> ParagraphMap? {
        let url = workingDirectory.appendingPathComponent(pathInsideEPUB)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ParagraphMap.self, from: data)
    }
}
