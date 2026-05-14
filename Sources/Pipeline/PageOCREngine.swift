import Foundation
import CoreGraphics
import Document

/// The seam for an end-to-end "given a page image, return structured
/// blocks + footnotes" engine. Both `ClaudePageOCREngine` and
/// `GeminiPageOCREngine` conform; the pipeline holds `any PageOCREngine`
/// so the per-page serial dispatch is unified across providers.
///
/// The XHTML output schema is shared — both providers prompt the model
/// to return the same fragment shape, and `ClaudePageXHTMLParser` parses
/// either one into `ClaudePageResult`. The batch-API and prompt-cache
/// paths remain Claude-specific (Anthropic-only features); callers that
/// need those check for `ClaudePageOCREngine` concretely.
public protocol PageOCREngine: Sendable {
    /// Provider identifier for diagnostics + cost reporting. Stable
    /// across versions of one provider; differs across providers.
    var providerId: String { get }

    /// Recognize one page. `pageIndex` namespaces footnote IDs
    /// (`fn-pN-K`) so two footnotes both labelled "1" on different
    /// pages don't collide downstream.
    func recognize(
        pageImage: CGImage,
        pageIndex: Int,
        languages: [BCP47]
    ) async throws -> ClaudePageResult
}
