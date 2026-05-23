import Foundation

/// Pinned Claude model identifier for the Messages API.
///
/// Use only the exact strings declared here — appending a date suffix
/// to an alias (e.g. `claude-sonnet-4-6-20251101`) returns a 404.
/// Added new models by extending `rawValue` cases or constructing
/// `AnthropicModel(rawValue:)` directly with an authoritative string
/// from Anthropic's published model catalog.
///
/// Wrapping `RawRepresentable` instead of a closed enum keeps
/// forward-compatibility: a future Claude release can be passed
/// through without a SDK update, while the static constants below
/// give callers type-safe, mnemonic names for the models we ship
/// against today.
public struct AnthropicModel: Sendable, Codable, Equatable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Sonnet 4.6 — best speed / intelligence balance. Used for
    /// vision-heavy tasks where ground-truth quality matters: hard-
    /// region OCR (polytonic Greek, Hebrew, mixed scripts) and
    /// table-structure extraction.
    public static let sonnet4_6 = AnthropicModel(rawValue: "claude-sonnet-4-6")

    /// Haiku 4.5 — fastest and most cost-effective. Used for the
    /// text-only Tier 2 features: post-OCR character cleanup,
    /// semantic chapter classification, TOC parsing.
    public static let haiku4_5 = AnthropicModel(rawValue: "claude-haiku-4-5")

    /// Haiku 4.5 pinned to a dated snapshot — strictest reproducibility
    /// for evaluation pipelines that want byte-for-byte identical
    /// behavior across deploys. Production code typically uses the
    /// alias above.
    public static let haiku4_5_20251001 = AnthropicModel(rawValue: "claude-haiku-4-5-20251001")

    /// Opus 4.7 — highest-capability tier, used by
    /// `ClaudePageOCREngine` in Manuscript mode for handwritten
    /// material (secretary hand, round hand, 19th-c. cursive,
    /// contemporary informal). Significantly more expensive than
    /// Sonnet for typeset OCR, but the gap in handwriting
    /// recognition justifies the routing.
    public static let opus4_7 = AnthropicModel(rawValue: "claude-opus-4-7")

    /// Gemini 2.5 Flash — Google's fast multimodal model, used as the
    /// budget alternative to Sonnet for page-OCR. Same XHTML output
    /// schema; ~7-10× cheaper per page on typical book content. The
    /// `AnthropicModel` type name is a slight lie here — this struct
    /// is the project's generic "LLM model id with pricing" carrier,
    /// not strictly Anthropic-only. Rename deferred to avoid churn.
    public static let gemini25Flash = AnthropicModel(rawValue: "gemini-2.5-flash")

    /// Gemini 3 Flash preview — Pro-tier reasoning at Flash latency.
    /// Preview status (May 2026); model id carries the `-preview`
    /// suffix and can change shape on short notice. ~25-67% more
    /// expensive than 2.5 Flash; we pin `thinking_level: minimal`
    /// for OCR to keep output tokens bounded.
    public static let gemini3FlashPreview = AnthropicModel(rawValue: "gemini-3-flash-preview")

    /// Gemini 3.5 Flash — stable model from Google I/O 2026, released
    /// May 19. Same multimodal contract as 2.5/3 Flash; thinking pinned
    /// to `minimal` for OCR. 3× the per-token price of 3 Flash Preview;
    /// per-page cost lands around $0.009 (vs $0.006 for 3 Flash Preview
    /// and $0.04 for Sonnet 4.6). Wired as an opt-in alternative for
    /// users running A/B comparisons against Sonnet at lower cost.
    public static let gemini35Flash = AnthropicModel(rawValue: "gemini-3.5-flash")

    /// Google Cloud Vision API DOCUMENT_TEXT_DETECTION — classical OCR
    /// (not an LLM). Tracked here so `ClaudeCallBudget.recordUsage`
    /// can attribute the per-page cost; pricing is fixed per request,
    /// so input/output tokens are repurposed: `inputTokens = 0`,
    /// `outputTokens = 1` per page → multiplied by the per-image rate.
    public static let googleDocumentOCR = AnthropicModel(rawValue: "google-document-ocr")

    /// LandingAI Agentic Document Extraction (`/v1/ade/parse`) — cloud
    /// document-OCR alternative to Cloud Vision. Same encoding trick
    /// as `googleDocumentOCR`: per-request flat rate carried as one
    /// synthetic output token. Verify the per-page rate against the
    /// current LandingAI pricing page before relying on the cost
    /// estimator for billing reconciliation — pricing has moved
    /// since the SDK's first release.
    public static let landingAIDocumentExtraction = AnthropicModel(rawValue: "landingai-ade-parse")

    /// Per-million-token pricing in USD. Used by `ConversionStats` to
    /// produce ≈-cost estimates for the post-conversion summary.
    /// Treat as estimates, not invoices — Anthropic's billing is the
    /// authoritative source.
    public var pricing: Pricing {
        switch rawValue {
        case "claude-sonnet-4-6":
            return Pricing(inputPerMTok: 3.00, outputPerMTok: 15.00)
        case "claude-haiku-4-5", "claude-haiku-4-5-20251001":
            return Pricing(inputPerMTok: 1.00, outputPerMTok: 5.00)
        case "claude-opus-4-7":
            return Pricing(inputPerMTok: 5.00, outputPerMTok: 25.00)
        case "gemini-2.5-flash":
            // Gemini 2.5 Flash list price as of late 2025: $0.30/M
            // input, $2.50/M output (text + image). Cache and batch
            // discounts not modelled — same posture as the Claude
            // rates above.
            return Pricing(inputPerMTok: 0.30, outputPerMTok: 2.50)
        case "gemini-3-flash-preview":
            // Gemini 3 Flash preview as of May 2026: $0.50/M input,
            // $3.00/M output. Preview prices may change at GA;
            // verify before relying on the post-conversion cost
            // estimate for billing reconciliation.
            return Pricing(inputPerMTok: 0.50, outputPerMTok: 3.00)
        case "gemini-3.5-flash":
            // Gemini 3.5 Flash (released May 19, 2026): $1.50/M input,
            // $9.00/M output. 3× Gemini 3 Flash Preview's rates, but
            // still 50% cheaper than Sonnet ($3/$15). Cached input
            // ($0.15/M) not modelled — same posture as Anthropic's
            // cache discount above.
            return Pricing(inputPerMTok: 1.50, outputPerMTok: 9.00)
        case "google-document-ocr":
            // Cloud Vision DOCUMENT_TEXT_DETECTION: $1.50 per 1000
            // images = $0.0015/image. Encoded as $1500/M output
            // tokens with one synthetic token per call, so a usage
            // of (in=0, out=1) bills at $0.0015. Keeps the
            // existing pricing/cost helpers working without
            // adding a per-request rate carrier.
            return Pricing(inputPerMTok: 0.00, outputPerMTok: 1500.00)
        case "landingai-ade-parse":
            // LandingAI ADE published rate: $0.03/page on the
            // pay-as-you-go tier. Encoded as $30000/M output tokens
            // with one synthetic token per call → (in=0, out=1)
            // bills at $0.03. VERIFY against current LandingAI
            // pricing before using these numbers for billing
            // reconciliation — the rate has moved in past releases.
            return Pricing(inputPerMTok: 0.00, outputPerMTok: 30000.00)
        default:
            // Unknown / future model — assume Sonnet rates as a
            // safe upper-middle estimate. Surface in the UI as
            // "estimated", not authoritative.
            return Pricing(inputPerMTok: 3.00, outputPerMTok: 15.00)
        }
    }
}

/// Per-million-token rates for one model. Cache-write is 1.25× input
/// (5-minute TTL) and cache-read is ~0.1× input — both derived rather
/// than stored to avoid drift if the rate table is updated.
public struct Pricing: Sendable, Equatable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double

    public init(inputPerMTok: Double, outputPerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
    }

    public var cacheCreationPerMTok: Double { inputPerMTok * 1.25 }
    public var cacheReadPerMTok: Double { inputPerMTok * 0.1 }

    /// Cost in USD for a `Usage` snapshot at this model's rates.
    public func cost(for usage: Usage) -> Double {
        let inputCost = Double(usage.inputTokens) / 1_000_000 * inputPerMTok
        let outputCost = Double(usage.outputTokens) / 1_000_000 * outputPerMTok
        let writeCost = Double(usage.cacheCreationInputTokens) / 1_000_000 * cacheCreationPerMTok
        let readCost = Double(usage.cacheReadInputTokens) / 1_000_000 * cacheReadPerMTok
        return inputCost + outputCost + writeCost + readCost
    }
}
