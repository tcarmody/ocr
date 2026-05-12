import Foundation
import CoreGraphics
import Document  // BCP47
import OCR

/// Common interface for post-OCR character cleanup engines. Both
/// `ClaudePostProcessor` (Cloud, Haiku 4.5) and
/// `AppleFoundationModelPostProcessor` (Phase 2.5 of
/// `L-Foundation-Models`) conform. The cascade calls this through
/// the protocol so adding / removing implementations is a one-line
/// factory change.
///
/// Returning `nil` means "skip this region" (below threshold, too
/// short, budget exhausted, refused, mode-unsupported, network
/// failure). The caller falls back to the original text on `nil` —
/// original always wins on doubt. A non-nil `Result` with
/// `accepted: false` means the model ran but the guardrail rejected
/// the candidate; caller uses `Result.corrected` (which is the
/// trimmed original on reject) and may log `Result.modelOutput` for
/// the editor's correction trail.
///
/// `Mode.vision` requires a non-nil `regionImage`. Engines that
/// can't honor vision mode (AFM is text-only) return `nil` for
/// any `.vision` request rather than silently falling back to
/// passages — the caller decides whether to retry in a different
/// mode.
public protocol PostOCRProcessor: Sendable {
    func correct(
        text: String,
        languages: [BCP47],
        mode: ClaudePostProcessor.Mode,
        regionImage: CGImage?
    ) async -> ClaudePostProcessor.Result?
}

extension ClaudePostProcessor: PostOCRProcessor {}
