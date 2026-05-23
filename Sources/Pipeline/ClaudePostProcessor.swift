import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import OCR

/// Haiku-backed post-OCR character cleanup. Runs after `RegionCascade`
/// produces final per-page observations. For regions whose joined text
/// scores below a configurable quality floor, we send the OCR text +
/// language hint to Haiku 4.5 with a tight "fix obvious OCR errors,
/// don't paraphrase" prompt and replace the region's observations with
/// the corrected text — gated by `OCRChangeGuardrail`, which is the
/// same guardrail the cascade itself uses to vet Claude OCR output.
///
/// Targeted at the ~5–15% of regions our cascade can't fix on its
/// own: ligature confusions (`rn`→`m`, `cl`→`d`), missing diacritics
/// for the document's language, dropped/extra spaces around
/// punctuation, long-s in pre-1800 reprints. Cost is well under a
/// penny per book at Haiku rates.
///
/// The processor returns `nil` whenever it declines to touch the
/// input (low confidence, hallucination guardrail tripped, budget
/// exhausted, response refused). The caller falls back to the
/// original text on `nil` — original always wins on doubt.
public struct ClaudePostProcessor: Sendable {
    public let client: AnthropicAPIClient
    public let budget: CloudCallBudget
    public var model: CloudModel
    public var maxOutputTokens: Int
    /// Combined-quality floor below which we send the region to Haiku.
    /// Raised from 0.6 → 0.7 alongside the cascade floor bumps —
    /// catches more scanner-noise cases that previously slipped
    /// through. Cost floor: more Haiku calls per book on regions
    /// that score in the 0.6–0.7 band.
    public var triggerThreshold: Double
    /// Don't post-process regions shorter than this. Captions, headers,
    /// page numbers — Haiku tends to make them worse, not better.
    public var minCharsToProcess: Int

    public init(
        client: AnthropicAPIClient,
        budget: CloudCallBudget,
        model: CloudModel = .haiku4_5,
        maxOutputTokens: Int = 2048,
        triggerThreshold: Double = 0.7,
        minCharsToProcess: Int = 30
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
        self.triggerThreshold = triggerThreshold
        self.minCharsToProcess = minCharsToProcess
    }

    /// Two correction modes:
    ///
    /// * **passages** — text-only. Cheap and fast. Catches ligature
    ///   confusions, missing diacritics, dropped spaces, long-s
    ///   misreads — everything where the model can infer the intent
    ///   from the OCR string alone.
    /// * **vision** — multimodal. Send the rendered region image
    ///   alongside the OCR text so the model can verify against the
    ///   actual glyphs. Roughly 5–10× the tokens per call. Reserve
    ///   for the lowest-quality regions where text-only correction
    ///   would be guessing.
    public enum Mode: Sendable, Equatable {
        case passages
        case vision
    }

    public struct Result: Sendable, Equatable {
        /// The text the caller should use. On accept this is the
        /// guardrail-approved correction; on reject it's the trimmed
        /// original (so callers can use the result uniformly without
        /// juggling two paths).
        public let corrected: String
        /// Haiku's raw output before the guardrail vetted it. Equal
        /// to `corrected` on accept; the guardrail-rejected suggestion
        /// on reject. The editor's correction-trail UI uses this so
        /// users can see what Haiku proposed even when we didn't take
        /// it — and accept it manually if they disagree with the
        /// guardrail.
        public let modelOutput: String
        /// True when `OCRChangeGuardrail` accepted the candidate.
        public let accepted: Bool
        public let rejectionReason: OCRChangeGuardrail.RejectionReason?
    }

    /// Decide whether to send the region to Haiku, and if so, run the
    /// correction. Returns `nil` on skip (below threshold, too short,
    /// budget exhausted, network failure, vision mode without image).
    /// Returns a `Result` with `accepted: false` when the call ran
    /// but the guardrail rejected the candidate — caller may want to
    /// log that distinct case for the editor's correction trail;
    /// either way, the `corrected` field carries the right text to
    /// use.
    ///
    /// `mode == .vision` requires `regionImage` to be non-nil. When
    /// the image is missing in vision mode, the call is skipped (so a
    /// caller that fails to crop a region image doesn't silently
    /// degrade to passages mode and burn tokens — the caller has to
    /// own that decision).
    public func correct(
        text: String,
        languages: [BCP47],
        mode: Mode = .passages,
        regionImage: CGImage? = nil
    ) async -> Result? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minCharsToProcess else { return nil }

        // Vision mode without an image: no-op rather than silently
        // falling back to passages. Loud-fail so the caller can fix
        // the upstream cropping.
        if mode == .vision, regionImage == nil { return nil }

        // Trigger gate: skip already-clean text. Score returns nil
        // for very short inputs (which we've already filtered above)
        // — treat that as "no signal" and skip.
        let scorer = OCRTextQualityScorer()
        guard let score = scorer.score(text: trimmed),
              score.combined < triggerThreshold else {
            return nil
        }

        // Reserve one budget call before doing any work — JSON encoding
        // and network setup aren't free, and PNG encoding in vision
        // mode is even more expensive.
        guard await budget.tryConsume() else { return nil }
        try? Task.checkCancellation()

        let messageContent: MessageContent
        switch mode {
        case .passages:
            messageContent = .plain(
                Self.userPrompt(text: trimmed, languages: languages)
            )
        case .vision:
            // We checked image non-nil above; force-unwrap is safe.
            guard let png = Self.encodePNG(regionImage!) else { return nil }
            let base64 = png.base64EncodedString()
            messageContent = .blocks([
                .image(mediaType: .png, base64Data: base64),
                .text(Self.userPrompt(text: trimmed, languages: languages)),
            ])
        }

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
            // Cache the system prompt — fires once per low-quality
            // region (~5-15% of regions on a scanned book), so a
            // 200-page scanned book might hit the cache 80+ times.
            // 1h TTL covers long conversions and bulk runs.
            system: .cached(Self.systemPrompt, ttl: .oneHour),
            messages: [
                Message(role: .user, content: messageContent),
            ],
            // Pure text correction — no reasoning. Saves tokens + latency.
            thinking: .disabled
        )

        let response: AnthropicMessageResponse
        do {
            response = try await client.send(request)
        } catch {
            return nil
        }

        // Record usage even on refusal — refused responses still cost
        // tokens and the stats panel surfaces that.
        await budget.recordUsage(response.usage, for: model)

        if response.didRefuse { return nil }
        guard let raw = response.primaryText, !raw.isEmpty else { return nil }
        guard let corrected = Self.parseCorrectedText(from: raw) else {
            return nil
        }

        // Guardrail: same policy as the OCR cascade. Reject anything
        // that looks like a rewrite, translation, or hallucination —
        // when in doubt, original text wins.
        let decision = OCRChangeGuardrail.accept(
            prior: trimmed, candidate: corrected
        )
        if decision.accepted {
            return Result(
                corrected: corrected,
                modelOutput: corrected,
                accepted: true,
                rejectionReason: nil
            )
        } else {
            return Result(
                corrected: trimmed,
                modelOutput: corrected,
                accepted: false,
                rejectionReason: decision.rejectionReason
            )
        }
    }

    // MARK: - Prompt

    /// Stable system prompt — kept identical across requests so the
    /// prefix is byte-stable for cacheability. Per-request language
    /// hints + text live in the user turn.
    static let systemPrompt = """
        You are correcting OCR output. Fix obvious character-level OCR \
        errors only: ligature confusions (rn→m, cl→d, vv→w), missing \
        diacritics for the indicated language, dropped or duplicated \
        spaces around punctuation, long-s → s in pre-1800 reprints, \
        homoglyph mistakes (0/O, 1/l/I). Do NOT change wording, do NOT \
        translate, do NOT modernize spelling, do NOT add or remove \
        sentences, do NOT expand abbreviations, do NOT fix grammar that \
        was in the original. Preserve line breaks. If the input is \
        already clean or you cannot tell what was intended, return the \
        text unchanged. Return ONLY the corrected text — no preface, \
        no commentary, no quotation marks, no JSON wrapper.
        """

    /// User-turn prompt; carries the per-request language hint + the
    /// OCR text to correct. System prompt stays byte-stable across
    /// requests so the prefix is cacheable.
    static func userPrompt(text: String, languages: [BCP47]) -> String {
        let codes = languages.map(\.rawValue).joined(separator: ", ")
        return """
            Languages expected: \(codes).

            OCR text to correct:
            \(text)
            """
    }

    // MARK: - PNG encoding (vision mode)

    /// Encode a CGImage as PNG bytes for inline base64 transmission.
    /// Same shape as `ClaudeOCREngine.encodePNG`; duplicated rather
    /// than shared because the engines live in separate types and a
    /// dedicated `ImageEncoder` namespace would just be one helper
    /// today.
    static func encodePNG(_ image: CGImage) -> Data? {
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

    /// Strip code-fence wrappers and surrounding whitespace from the
    /// model's response. The system prompt asks for plain text, but
    /// Haiku occasionally wraps long passages in ``` fences anyway.
    /// Keep this conservative — only strip outer fences, leave internal
    /// content alone.
    static func parseCorrectedText(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Strip outer ```...``` (with optional language tag) if present.
        if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") {
            var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            if !lines.isEmpty { lines.removeFirst() }
            if !lines.isEmpty, lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeLast()
            }
            let inner = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }
        return trimmed
    }
}
