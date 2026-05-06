import Foundation
import CoreGraphics

/// A typed region of a page produced by a layout analyzer.
///
/// Coordinates use Vision's normalized convention (origin bottom-left,
/// both axes in [0,1]) so the rest of the pipeline can mix layout
/// regions with OCR observations without coordinate translation.
public struct LayoutRegion: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        // Body / structure
        case text          // body paragraph
        case sectionHeader // chapter / section title (→ <h2>)
        case title         // book / part title (→ <h1>)
        case listItem      // numbered or bulleted list item
        case caption       // figure or table caption
        // Page furniture
        case pageHeader    // running head + page number across the top
        case pageFooter    // running foot + page number along the bottom
        case footnote      // footnote body at the bottom of the page
        // Visual
        case picture       // figure / illustration / image
        case table         // table region
        case formula       // math/formula (often rendered as image)
        // Catch-all for labels we haven't explicitly mapped yet.
        case other
    }

    public var kind: Kind
    /// Normalized [0,1] bounding box, bottom-left origin.
    public var box: CGRect
    /// Reading-order index assigned by the layout analyzer. -1 if
    /// unassigned; sort ascending for natural flow (multi-column,
    /// running heads first, body, footnotes last).
    public var readingOrder: Int
    /// Confidence in [0,1].
    public var confidence: Double

    public init(kind: Kind, box: CGRect, readingOrder: Int, confidence: Double) {
        self.kind = kind
        self.box = box
        self.readingOrder = readingOrder
        self.confidence = confidence
    }
}
