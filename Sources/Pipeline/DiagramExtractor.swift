import Foundation
import CoreGraphics
import Document
import OCR

/// One diagram extraction's worth of output. Tier 1 ships
/// `altText` only — `description` and `labels` are placeholders
/// for the later Tier 2 / Tier 3 follow-ons documented in
/// `P-Diagram-Description`.
///
/// `altText` is a short, screen-reader-ready string (≤ 120 chars)
/// that replaces the bare `alt="figure"` placeholder for `.picture`
/// regions. Specific enough to convey diagram type + salient
/// content; never a "this figure shows" preamble.
///
/// `description` (Tier 2, nil for now) is a longer paragraph
/// (200-500 chars) intended for the chat / search retrieval index —
/// NOT visible in the EPUB. Tiers stack: Tier 2 ships by extending
/// this struct's prompt + non-nil parsing without re-doing the
/// cascade-loop plumbing.
///
/// `labels` (Tier 3, [] for now) holds text strings recognized
/// inside the diagram (axis labels, callouts, legend entries).
/// Same indexable-not-visible posture as `description`.
public struct DiagramExtractionResult: Sendable, Equatable {
    public let altText: String
    public let description: String?
    public let labels: [String]

    public init(
        altText: String,
        description: String? = nil,
        labels: [String] = []
    ) {
        self.altText = altText
        self.description = description
        self.labels = labels
    }
}

/// Common shape for any backend that turns a `.picture` region
/// into accessibility-grade alt text (Tier 1) plus optional
/// description / labels (Tiers 2/3). Returning `nil` means
/// "skip / fall back to the default `alt='figure'`" — the
/// figure is still embedded; the user just doesn't get the
/// generated text.
///
/// Today only `ClaudeDiagramExtractor` (Sonnet 4.6) conforms;
/// future Gemini Flash and on-device VLM implementations will
/// conform without touching the call site (mirrors
/// `TableExtractor` / `MathExtractor`).
///
/// Input is the pre-cropped figure image — the call site lives
/// in a post-cascade phase that consumes the figure bytes
/// `FigureExtractor` already produced. No re-cropping needed.
///
/// `captionText` is the OCR'd text of the figure's associated
/// `.caption` region, resolved via `CaptionAssociator`'s book-
/// wide orientation vote (above vs. below). When the figure has
/// no associated caption, pass `nil`. The extractor includes the
/// caption in the prompt so the model's output stays consistent
/// with the printed caption — a figure captioned "Figure 3.1:
/// Marriage market dynamics" should produce alt text agreeing
/// on "marriage market", not invent a different topic.
public protocol DiagramExtractor: Sendable {
    func extract(
        figureImage: CGImage,
        captionText: String?,
        languages: [BCP47],
        pageIndex: Int,
        regionIndex: Int
    ) async -> DiagramExtractionResult?
}
