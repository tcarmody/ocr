import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import OCR

/// `OCREngine` impl backed by Claude Sonnet 4.6 multimodal.
///
/// Used as the cascade's final tier in `.cloud` processing mode for
/// regions where Vision, Surya, and Tesseract all produced suspect
/// output. Targeted at the cases the local stack handles poorly:
/// polytonic Greek with stripped diacritics, Hebrew / Syriac scans,
/// mixed-script boundaries, ligature-heavy 18th-century reprints.
///
/// Per-call cost is bounded two ways:
///   * `ClaudeCallBudget` — shared per-book counter that this engine
///     decrements on every request. When the budget is exhausted,
///     `recognize(...)` throws so the cascade can fall back to the
///     prior tier.
///   * The cascade itself only invokes this engine on regions that
///     the prior tiers didn't handle — typically a small fraction of
///     the regions on a problematic page.
///
/// Guardrail-gating against the prior tier happens in the cascade
/// (`OCRChangeGuardrail`), not here. This engine returns whatever
/// Claude transcribed; the cascade decides whether to keep it.
public struct ClaudeOCREngine: OCREngine {
    public let client: AnthropicAPIClient
    public let budget: ClaudeCallBudget
    public var model: AnthropicModel
    public var maxOutputTokens: Int

    /// Build an engine wired to a specific API client + per-book budget.
    /// Defaults pin to Sonnet 4.6 with a generous 4096 max output —
    /// most region transcriptions are well under 1K tokens, but
    /// caption-heavy or table-cell regions occasionally need more
    /// headroom and the cost scales with actual output anyway.
    public init(
        client: AnthropicAPIClient,
        budget: ClaudeCallBudget,
        model: AnthropicModel = .sonnet4_6,
        maxOutputTokens: Int = 4096
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    public enum ClaudeOCRError: Error, LocalizedError {
        case budgetExhausted
        case pngEncodeFailed
        case emptyResponse
        case underlying(any Error)

        public var errorDescription: String? {
            switch self {
            case .budgetExhausted:    return "Per-book Claude call budget exhausted."
            case .pngEncodeFailed:    return "Could not encode region image as PNG."
            case .emptyResponse:      return "Claude returned no text for this region."
            case .underlying(let e):  return e.localizedDescription
            }
        }
    }

    public func recognize(image: CGImage, hints: OCRHints) async throws -> OCRResult {
        // Reserve one call from the budget *before* doing any work —
        // PNG encoding + base64 + JSON serialization aren't free, and
        // we don't want to pay them on a request we're going to refuse.
        guard await budget.tryConsume() else {
            throw ClaudeOCRError.budgetExhausted
        }
        try Task.checkCancellation()

        guard let png = Self.encodePNG(image) else {
            throw ClaudeOCRError.pngEncodeFailed
        }
        let base64 = png.base64EncodedString()

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
            system: .plain(Self.systemPrompt),
            messages: [
                Message(role: .user, content: .blocks([
                    .image(mediaType: .png, base64Data: base64),
                    .text(Self.userPromptForLanguages(hints.languages)),
                ])),
            ],
            // No reasoning needed — pure transcription is a direct
            // visual-to-text task, and disabling thinking saves both
            // tokens and latency.
            thinking: .disabled
        )

        let response: AnthropicMessageResponse
        do {
            response = try await client.send(request)
        } catch let apiError as AnthropicAPIError {
            throw ClaudeOCRError.underlying(apiError)
        }

        // Record token usage even on refusal — it still cost tokens.
        // The stats panel surfaces "Claude was called and refused"
        // as part of the per-model usage breakdown.
        await budget.recordUsage(response.usage, for: model)

        // Refused / safety-blocked: surface as empty so the cascade
        // keeps the prior tier instead of replacing it with whatever
        // text the refusal produced.
        if response.didRefuse {
            throw ClaudeOCRError.emptyResponse
        }
        guard let text = response.primaryText, !text.isEmpty else {
            throw ClaudeOCRError.emptyResponse
        }

        // One observation per call — Claude doesn't give us per-line
        // bboxes, so we wrap the entire transcription as a single
        // observation that fills the input image's normalized bbox.
        // The cascade then translates that to full-page coords and
        // attributes the observation to the region.
        let observation = TextObservation(
            text: text,
            confidence: 0.95,
            box: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: .claude
        )
        return OCRResult(
            text: text,
            meanConfidence: 0.95,
            observations: [observation]
        )
    }

    // MARK: - Prompt

    /// Stable system prompt — kept short on purpose. Claude doesn't
    /// need lengthy guidance for verbatim transcription, and a short
    /// prompt below the prefix-cache floor (~2048 tokens for Sonnet)
    /// can't be cached anyway. Language hints go in the user turn so
    /// the system stays identical across requests.
    static let systemPrompt = """
        You are transcribing scanned text from a single region of a book \
        page. Return the text verbatim. Do not paraphrase, modernize \
        spelling, translate, or add commentary. Preserve diacritics, \
        ligatures, and original punctuation. Preserve line breaks within \
        the image. For long-s in pre-1800 reprints, output 's'. If text \
        is unclear, transcribe what you can read; do not insert markers \
        like "[unclear]". Return only the transcribed text — no preface, \
        no quotation marks, no JSON.
        """

    /// User-turn prompt; carries the per-request language hint so the
    /// system prompt stays byte-stable across requests for cacheability.
    static func userPromptForLanguages(_ languages: [BCP47]) -> String {
        let codes = languages.map(\.rawValue).joined(separator: ", ")
        return "Languages expected: \(codes). Transcribe the text in this image."
    }

    // MARK: - Helpers

    private static func encodePNG(_ image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}
