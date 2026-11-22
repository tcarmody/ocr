import Foundation

/// Pinned cloud-LLM model identifier — provider-agnostic. Holds
/// entries for Anthropic Messages API models (Sonnet / Haiku /
/// Opus), Google Generative Language API models (Gemini Flash
/// variants), and synthetic "single-call rate" carriers for
/// Google Cloud Vision and LandingAI ADE so the per-book
/// `CloudCallBudget` can attribute cost across every provider.
/// Previously named `AnthropicModel` from the era when only
/// Sonnet had pricing tracked.
///
/// Use only the exact strings declared here — appending a date suffix
/// to an alias (e.g. `claude-sonnet-4-6-20251101`) returns a 404 on
/// the Anthropic side, and Google's catalog has similar pinning.
/// Add new models by extending the static constants below or
/// constructing `CloudModel(rawValue:)` directly with an authoritative
/// string from the relevant provider's catalog.
///
/// Wrapping `RawRepresentable` instead of a closed enum keeps
/// forward-compatibility: a future release on either side can be
/// passed through without a SDK update, while the static constants
/// below give callers type-safe, mnemonic names for the models we
/// ship against today.
public struct CloudModel: Sendable, Codable, Equatable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Sonnet 5.5 — best speed / intelligence balance. Used for
    /// vision-heavy tasks where ground-truth quality matters: hard-
    /// region OCR (polytonic Greek, Hebrew, mixed scripts), typeset
    /// and early-print page OCR, table / math / diagram extraction,
    /// chapter structure, plus the Cloud (Sonnet) chat and briefing
    /// backends.
    ///
    /// Differences from Sonnet 4.6 that callers must respect:
    /// `thinking: disabled` returns a 400 — `ThinkingConfig.resolved`
    /// sends `between_tools` instead; forced `tool_choice`, sampling
    /// params and assistant prefill return a 400; the tokenizer
    /// yields ~30% more tokens for the same text.
    ///
    /// Requests default to effort `low` (`defaultEffort`) and page
    /// images go up at the high-res maximum (`maxImageLongEdge`,
    /// `maxImagePixels`).
    public static let sonnet5_5 = CloudModel(rawValue: "claude-sonnet-5-5")

    /// Sonnet 4.6 — previous Sonnet. Kept so persisted usage keyed
    /// on the old id still prices correctly; new calls use `sonnet5_5`.
    public static let sonnet4_6 = CloudModel(rawValue: "claude-sonnet-4-6")

    /// How a request turns extended thinking off on this model.
    /// `.betweenTools` for Sonnet 5.5 (it 400s on `disabled`; every
    /// other model 400s on `between_tools`); `.omitted` for Opus 5.5,
    /// where thinking is always on and only effort controls it;
    /// `.disabled` everywhere else.
    public enum ThinkingOff: Sendable, Equatable {
        case disabled, betweenTools, omitted
    }

    public var thinkingOff: ThinkingOff {
        switch rawValue {
        case "claude-sonnet-5-5": return .betweenTools
        case "claude-opus-5-5":   return .omitted
        default:                  return .disabled
        }
    }

    /// True when requests opt into server-side refusal fallback
    /// (`fallbacks: "default"`). Opus 5.5's safety classifiers can
    /// decline benign requests; the fallback re-runs a decline on
    /// Anthropic's recommended model instead of failing the page.
    /// Off for Haiku 5.5 (no server-side fallback) and Sonnet 5.5
    /// (its `between_tools` thinking-off isn't accepted by its
    /// fallback model).
    public var supportsServerSideFallback: Bool {
        rawValue == "claude-opus-5-5"
    }

    /// True when the model may think even with thinking "off", so
    /// `max_tokens` needs room for thinking as well as the reply.
    public var alwaysThinks: Bool { thinkingOff == .omitted }

    /// Effort sent when a request doesn't set one. Sonnet 5.5 runs
    /// at `low`: its levels are recalibrated from Sonnet 4.6, and
    /// `low` is Anthropic's starting point for chat, extraction and
    /// classification — the shape of every Sonnet route here.
    /// Opus 5.5 also runs at `low`: thinking can't be turned off
    /// there, so effort is the only lever on its thinking spend (its
    /// API default is `medium`; raise it if handwriting quality drops). Nil
    /// leaves the API default (Haiku 4.5 rejects `effort` outright).
    public var defaultEffort: OutputConfig.Effort? {
        switch rawValue {
        case "claude-sonnet-5-5", "claude-opus-5-5": return .low
        default: return nil
        }
    }

    /// True for models with high-resolution vision: images up to
    /// 2576 px on the long edge **and** 3.75 MP in total. Older
    /// routes keep 1568 px, where Sonnet 4.6 / Haiku 4.5 downscale
    /// anyway.
    public var hasHighResVision: Bool {
        rawValue == "claude-sonnet-5-5" || rawValue == "claude-opus-5-5"
    }

    /// Long edge, in pixels, that whole-page images are downsized to
    /// before upload — the model's maximum. Larger images cost more
    /// image tokens (up to ~4,800 per image at the high-res limit vs
    /// ~1,600 at 1568 px).
    public var maxImageLongEdge: Int {
        hasHighResVision ? 2576 : 1568
    }

    /// Total-pixel ceiling for whole-page images, or nil when the
    /// long-edge cap is the only limit applied. High-res models cap
    /// at 3.75 MP, so a portrait page (≈1.41:1) tops out near
    /// 2300 px on the long edge rather than 2576.
    public var maxImagePixels: Int? {
        hasHighResVision ? 3_750_000 : nil
    }

    /// Haiku 5.5 — fastest and most cost-effective. Used for the
    /// text-only Tier 2 features: post-OCR character cleanup,
    /// semantic chapter classification, TOC parsing, plus the
    /// Cloud (Haiku) chat and briefing backends.
    ///
    /// Differences from Haiku 4.5 that callers must respect:
    /// thinking is adaptive by default (every caller here sends
    /// `thinking: .disabled`, which Haiku 5.5 accepts at effort
    /// `high` or below — its default is `medium`); `temperature` /
    /// `top_p` / `top_k` and assistant prefill return a 400; the
    /// tokenizer yields ~30% more tokens for the same text.
    public static let haiku5_5 = CloudModel(rawValue: "claude-haiku-5-5")

    /// Haiku 4.5 — previous Haiku. Kept so persisted usage keyed on
    /// the old id still prices correctly; new calls use `haiku5_5`.
    public static let haiku4_5 = CloudModel(rawValue: "claude-haiku-4-5")

    /// Haiku 4.5 pinned to a dated snapshot — strictest reproducibility
    /// for evaluation pipelines that want byte-for-byte identical
    /// behavior across deploys. Production code typically uses the
    /// alias above.
    public static let haiku4_5_20251001 = CloudModel(rawValue: "claude-haiku-4-5-20251001")

    /// Opus 5.5 — highest-capability tier, used by
    /// `ClaudePageOCREngine` in Manuscript mode for handwritten
    /// material (secretary hand, round hand, 19th-c. cursive,
    /// contemporary informal). Significantly more expensive than
    /// Sonnet for typeset OCR, but the gap in handwriting
    /// recognition justifies the routing.
    ///
    /// Differences from Opus 4.7 that callers must respect: thinking
    /// is always on (`disabled` returns a 400 at every effort), so
    /// `ThinkingConfig.resolved` omits the field and requests default
    /// to effort `low`; forced `tool_choice` returns a 400; requests
    /// opt into server-side refusal fallback; page images go up at
    /// the high-res maximum (2576 px / 3.75 MP). Same tokenizer as 4.7.
    public static let opus5_5 = CloudModel(rawValue: "claude-opus-5-5")

    /// Opus 4.7 — previous Opus. Kept so persisted usage keyed on
    /// the old id still prices correctly; new calls use `opus5_5`.
    public static let opus4_7 = CloudModel(rawValue: "claude-opus-4-7")

    /// Gemini 2.5 Flash — Google's fast multimodal model, used as the
    /// budget alternative to Sonnet for page-OCR. Same XHTML output
    /// schema; ~7-10× cheaper per page on typical book content.
    public static let gemini25Flash = CloudModel(rawValue: "gemini-2.5-flash")

    /// Gemini 3 Flash preview — Pro-tier reasoning at Flash latency.
    /// Preview status (May 2026); model id carries the `-preview`
    /// suffix and can change shape on short notice. ~25-67% more
    /// expensive than 2.5 Flash; we pin `thinking_level: minimal`
    /// for OCR to keep output tokens bounded.
    public static let gemini3FlashPreview = CloudModel(rawValue: "gemini-3-flash-preview")

    /// Gemini 3.5 Flash — stable model from Google I/O 2026, released
    /// May 19. Same multimodal contract as 2.5/3 Flash; thinking pinned
    /// to `minimal` for OCR. 3× the per-token price of 3 Flash Preview;
    /// per-page cost lands around $0.009 (vs $0.006 for 3 Flash Preview
    /// and $0.04 for Sonnet 4.6). Wired as an opt-in alternative for
    /// users running A/B comparisons against Sonnet at lower cost.
    public static let gemini35Flash = CloudModel(rawValue: "gemini-3.5-flash")

    /// Google Cloud Vision API DOCUMENT_TEXT_DETECTION — classical OCR
    /// (not an LLM). Tracked here so `CloudCallBudget.recordUsage`
    /// can attribute the per-page cost; pricing is fixed per request,
    /// so input/output tokens are repurposed: `inputTokens = 0`,
    /// `outputTokens = 1` per page → multiplied by the per-image rate.
    public static let googleDocumentOCR = CloudModel(rawValue: "google-document-ocr")

    /// LandingAI ADE Gen2 parse (`POST /v2/parse`) on DPT-3 Pro — cloud
    /// document-OCR alternative to Cloud Vision, a table extractor, and
    /// a whole-page OCR provider. DPT-3 bills in credits ($1 = 100
    /// credits): 1 credit per page + 0.5 credits per 1,000 output
    /// characters on the sync (priority) tier, rounded up to 0.1
    /// credit. The response reports the exact charge in
    /// `metadata.billing.total_credits`; callers record it as one
    /// synthetic output token per tenth of a credit ($0.001), so a
    /// typical ~3,000-character page (2.5 credits) records 25 tokens.
    public static let landingAIDPT3Pro = CloudModel(rawValue: "landingai-dpt-3-pro")

    /// LandingAI ADE Gen1 parse (`/v1/ade/parse`, DPT-2) — previous
    /// endpoint, flat 3 credits ($0.03) per call carried as one
    /// synthetic output token. Kept so persisted usage keyed on it
    /// still prices correctly; new calls record `landingAIDPT3Pro`.
    public static let landingAIDocumentExtraction = CloudModel(rawValue: "landingai-ade-parse")

    /// Per-million-token pricing in USD. Used by `ConversionStats` to
    /// produce ≈-cost estimates for the post-conversion summary.
    /// Treat as estimates, not invoices — Anthropic's billing is the
    /// authoritative source.
    public var pricing: Pricing {
        switch rawValue {
        case "claude-sonnet-5-5":
            // Sonnet 5.5: $2/M input, $10/M output; cache reads are
            // $0.10/M (0.05× input, not the usual 0.1×).
            return Pricing(inputPerMTok: 2.00, outputPerMTok: 10.00,
                           cacheReadPerMTokOverride: 0.10)
        case "claude-sonnet-4-6":
            return Pricing(inputPerMTok: 3.00, outputPerMTok: 15.00)
        case "claude-haiku-5-5":
            // Haiku 5.5: $0.10/M input, $0.50/M output for prompts of
            // 100K tokens or fewer. Longer prompts bill at $0.50 /
            // $2.50; not modelled because usage is aggregated per
            // model across calls, and every Haiku route here sends
            // prompts well under 100K.
            return Pricing(inputPerMTok: 0.10, outputPerMTok: 0.50)
        case "claude-haiku-4-5", "claude-haiku-4-5-20251001":
            return Pricing(inputPerMTok: 1.00, outputPerMTok: 5.00)
        case "claude-opus-5-5":
            // Opus 5.5: $4/M input, $20/M output; cache reads $0.20/M
            // (0.05× input). Thinking tokens bill as output.
            return Pricing(inputPerMTok: 4.00, outputPerMTok: 20.00,
                           cacheReadPerMTokOverride: 0.20)
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
        case "landingai-dpt-3-pro":
            // One synthetic output token = 0.1 credit = $0.001
            // ($1 buys 100 credits on the Explore and Team plans).
            return Pricing(inputPerMTok: 0.00, outputPerMTok: 1000.00)
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
    /// Set only for models whose cache-read rate isn't 0.1× input
    /// (Sonnet 5.5 reads at 0.05×).
    public let cacheReadPerMTokOverride: Double?

    public init(
        inputPerMTok: Double,
        outputPerMTok: Double,
        cacheReadPerMTokOverride: Double? = nil
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTokOverride = cacheReadPerMTokOverride
    }

    public var cacheCreationPerMTok: Double { inputPerMTok * 1.25 }
    public var cacheReadPerMTok: Double { cacheReadPerMTokOverride ?? inputPerMTok * 0.1 }

    /// Cost in USD for a `Usage` snapshot at this model's rates.
    public func cost(for usage: Usage) -> Double {
        let inputCost = Double(usage.inputTokens) / 1_000_000 * inputPerMTok
        let outputCost = Double(usage.outputTokens) / 1_000_000 * outputPerMTok
        let writeCost = Double(usage.cacheCreationInputTokens) / 1_000_000 * cacheCreationPerMTok
        let readCost = Double(usage.cacheReadInputTokens) / 1_000_000 * cacheReadPerMTok
        return inputCost + outputCost + writeCost + readCost
    }
}
