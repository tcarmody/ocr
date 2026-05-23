import Foundation
import CoreGraphics
import Document

/// The seam for an end-to-end "given a page image, return structured
/// blocks + footnotes" engine. Both `ClaudePageOCREngine` and
/// `GeminiPageOCREngine` conform; the pipeline holds `any PageOCREngine`
/// so the per-page serial dispatch is unified across providers.
///
/// The XHTML output schema is shared — both providers prompt the model
/// to return the same fragment shape, and `PageXHTMLParser` parses
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

    /// Classify a thrown error into a `ProviderStatus`. Lets the
    /// pipeline distinguish refusals from API errors from
    /// budget-exhaustion when aggregating refusal-rate stats —
    /// the runner sees `any Error` from `recognize` and asks the
    /// active engine to bucket it. Default impl returns
    /// `.apiError` for anything unrecognized.
    func classify(error: any Error) -> ProviderStatus
}

public extension PageOCREngine {
    func classify(error: any Error) -> ProviderStatus {
        if error is CancellationError { return .canceled }
        return .apiError
    }
}

/// What the page-OCR provider did with one page. Drives refusal-rate
/// reporting in `ConversionStats` and the page-OCR debug-log header.
/// Orthogonal to the "did Vision back-fill empty results" question —
/// `PendingPageOCR` tracks both: the provider's status (this enum) and
/// `usedLocalFallback` for the post-failure backfill.
public enum ProviderStatus: String, Sendable, Equatable, Codable {
    /// Provider returned parseable blocks. Vision fallback didn't fire.
    case succeeded
    /// Provider explicitly refused (Anthropic `stop_reason: refusal`,
    /// Gemini `finishReason: SAFETY` / `RECITATION`). The single
    /// stat most users want — recurring refusals on book content
    /// usually mean a content-policy mismatch worth investigating
    /// (copyrighted passages, sensitive content) rather than a bug.
    case refused
    /// Provider returned without refusal but with no parseable text.
    /// Different from refusal — usually a model hiccup rather than a
    /// policy decision; commonly recovers on retry.
    case empty
    /// HTTP / network / decode error. Includes Anthropic 5xx, Gemini
    /// non-2xx, decode failures, transport errors. Retryable.
    case apiError
    /// Provider returned a 429 / rate-limit error and the retry
    /// budget ran out before the call succeeded. Distinct from
    /// `apiError` because it points to **us bursting too fast**
    /// (or the tier being too small) rather than the provider
    /// being broken — the fix is rate-limit configuration, not
    /// retrying harder. `ClaudeRateLimiter.shared` is the
    /// upstream prevention; this enum value is the signal when
    /// the limiter didn't fully prevent it.
    case rateLimited
    /// Per-book Claude call budget exhausted before this page got a
    /// turn. Tracked separately so the user can distinguish "policy
    /// refused" from "we capped you."
    case budgetExhausted
    /// E-Routing trust verdict skipped the call entirely — embedded
    /// PDF text was good enough to use. Page contributes to the EPUB
    /// from embedded extraction; provider was never invoked.
    case skippedTrustRouted
    /// Task was canceled (user clicked Stop, app quit, etc.) before
    /// the call completed.
    case canceled
}
