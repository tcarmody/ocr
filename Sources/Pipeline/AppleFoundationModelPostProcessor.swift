import Foundation
import CoreGraphics
import FoundationModels
import AI
import Document  // BCP47
import OCR

/// Phase 2.5 of `L-Foundation-Models`. On-device counterpart to
/// `ClaudePostProcessor` — same trigger gate (quality score below
/// threshold), same length floor, same guardrail policy, same
/// returned `Result` shape. Only the model call itself differs:
/// schema-guided generation against AFM instead of an Anthropic
/// API round-trip.
///
/// **Text-only**. AFM is a text model; vision mode requests get
/// declined (return `nil`) rather than silently falling back to
/// passages. Callers that want vision-mode cleanup must route to
/// Cloud Haiku. Per the L-Foundation-Models scope, this is
/// expected: Phase 2.5 covers the cheap-and-fast passages path,
/// Cloud Haiku stays as the higher-accuracy option for the
/// classical / worn / polytonic-Greek regions where vision is
/// often essential.
///
/// Cost: zero (on-device). Latency: ~100-500ms per region
/// depending on input length. AFM's 8K context window is far more
/// than any single region needs.
public struct AppleFoundationModelPostProcessor: PostOCRProcessor {
    public let client: AppleFoundationModelClient
    public var triggerThreshold: Double
    public var minCharsToProcess: Int

    public init(
        client: AppleFoundationModelClient = AppleFoundationModelClient(),
        triggerThreshold: Double = 0.7,
        minCharsToProcess: Int = 30
    ) {
        self.client = client
        self.triggerThreshold = triggerThreshold
        self.minCharsToProcess = minCharsToProcess
    }

    public func correct(
        text: String,
        languages: [BCP47],
        mode: ClaudePostProcessor.Mode,
        regionImage: CGImage?
    ) async -> ClaudePostProcessor.Result? {
        // AFM is text-only. Vision-mode requests are declined
        // rather than silently downgraded — the caller may want
        // to fall back to Cloud Haiku for those regions instead
        // of accepting a passages-only correction on a region
        // that was flagged for vision specifically.
        if mode == .vision { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minCharsToProcess else { return nil }

        // Same trigger gate as the Cloud path. The scorer is the
        // single source of truth for "this region looks rough";
        // both engines share it so an A/B comparison of Cloud vs
        // AFM stays apples-to-apples.
        let scorer = OCRTextQualityScorer()
        guard let score = scorer.score(text: trimmed),
              score.combined < triggerThreshold else {
            return nil
        }
        try? Task.checkCancellation()

        let prompt = Self.userPrompt(text: trimmed, languages: languages)
        let response: CorrectedText
        do {
            response = try await client.respond(
                instructions: Self.instructions,
                prompt: prompt
            )
        } catch {
            return nil
        }

        let candidate = response.corrected
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        // Same guardrail as the Cloud path. Catches paraphrases,
        // translations, length-of-magnitude differences, anything
        // that smells like a rewrite rather than a character fix.
        // Original wins on rejection.
        let decision = OCRChangeGuardrail.accept(
            prior: trimmed, candidate: candidate
        )
        if decision.accepted {
            return ClaudePostProcessor.Result(
                corrected: candidate,
                modelOutput: candidate,
                accepted: true,
                rejectionReason: nil
            )
        } else {
            return ClaudePostProcessor.Result(
                corrected: trimmed,
                modelOutput: candidate,
                accepted: false,
                rejectionReason: decision.rejectionReason
            )
        }
    }

    // MARK: - @Generable schema

    @Generable
    struct CorrectedText {
        @Guide(description: "The OCR text with character-level errors fixed — ligature confusions, missing diacritics, dropped or duplicated spaces around punctuation, long-s → s, homoglyph mistakes. Do NOT change wording, do NOT translate, do NOT modernize spelling, do NOT add or remove sentences. Return the corrected text verbatim, preserving line breaks. If the input is already clean or you can't tell what was intended, return the text unchanged.")
        var corrected: String
    }

    // MARK: - Instructions + prompt

    /// Mirrors the Cloud path's system prompt verbatim except for
    /// the trailing "return ONLY the corrected text — no preface,
    /// no commentary, no JSON wrapper" clause (the @Generable
    /// schema enforces the output shape natively here, so the
    /// "no JSON wrapper" instruction would actively confuse AFM).
    static let instructions = """
        You are correcting OCR output. Fix obvious character-level OCR \
        errors only: ligature confusions (rn→m, cl→d, vv→w), missing \
        diacritics for the indicated language, dropped or duplicated \
        spaces around punctuation, long-s → s in pre-1800 reprints, \
        homoglyph mistakes (0/O, 1/l/I). Do NOT change wording, do NOT \
        translate, do NOT modernize spelling, do NOT add or remove \
        sentences, do NOT expand abbreviations, do NOT fix grammar that \
        was in the original. Preserve line breaks. If the input is \
        already clean or you cannot tell what was intended, return the \
        text unchanged.
        """

    /// User-turn prompt; carries the language hint + OCR text.
    /// Same shape as the Cloud path so cross-impl comparisons
    /// stay apples-to-apples.
    static func userPrompt(text: String, languages: [BCP47]) -> String {
        let codes = languages.map(\.rawValue).joined(separator: ", ")
        return """
            Languages expected: \(codes).

            OCR text to correct:
            \(text)
            """
    }
}
