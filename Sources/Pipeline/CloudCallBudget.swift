import Foundation
import AI

/// Per-book ceiling on Cloud-LLM API calls, shared across every
/// Cloud-mode feature that consumes a remote model (OCR, table
/// extraction, post-OCR cleanup, semantic classification, TOC
/// parsing). Provider-agnostic: counts calls to Anthropic
/// (Sonnet / Haiku / Opus), Google (Gemini Flash variants),
/// Cloud Vision, and LandingAI ADE against the same per-book
/// reservoir. Previously named `ClaudeCallBudget` from the days
/// when only Sonnet talked to a network model — renamed when
/// Gemini joined the page-OCR roster.
///
/// Why one shared budget rather than one per feature: the user sets a
/// single "max calls per book" in Settings and expects that to bound
/// the cost of the conversion as a whole. A per-feature cap would let
/// a book with many tables blow past the user's intended ceiling
/// because each feature has its own reservoir.
///
/// Construct one per `convert(...)` call; pass to every cloud-backed
/// engine the conversion uses. When the budget is exhausted, callers
/// see `tryConsume()` return `false` and should fall back to the prior
/// tier (the cascade does this for OCR; future phases follow the same
/// pattern).
///
/// Also accumulates per-model token usage via `recordUsage(_:for:)` so
/// the post-conversion stats panel can report cloud calls + estimated
/// cost. Engines should call `recordUsage` after every successful
/// API call.
public actor CloudCallBudget {
    /// Initial cap (i.e., `AISettings.perBookCallCap`). `nonisolated`
    /// because it's set once at init and never mutates — callers can
    /// read it without a hop into the actor.
    public nonisolated let cap: Int
    /// Calls already granted this conversion.
    public private(set) var consumed: Int = 0
    /// Aggregate token usage by model. Empty until the first
    /// `recordUsage` call.
    public private(set) var modelUsage: [AnthropicModel: AggregateUsage] = [:]

    /// Per-model accumulated token totals across one conversion.
    /// Sendable + Codable so it can be persisted on a `Job` value
    /// for the queue UI's stats panel.
    public struct AggregateUsage: Sendable, Codable, Equatable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheCreationInputTokens: Int
        public var cacheReadInputTokens: Int

        public init(
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            cacheCreationInputTokens: Int = 0,
            cacheReadInputTokens: Int = 0
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
        }

        /// Total billable tokens across all four categories — useful
        /// for one-line summaries.
        public var total: Int {
            inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens
        }

        /// Convert to an `AI.Usage` snapshot so existing pricing
        /// helpers (`Pricing.cost(for:)`) work without translation.
        public var asUsage: Usage {
            Usage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationInputTokens: cacheCreationInputTokens,
                cacheReadInputTokens: cacheReadInputTokens
            )
        }
    }

    public init(cap: Int) {
        self.cap = max(0, cap)
    }

    /// Try to claim one call from the budget. Returns `true` if granted
    /// (and the consumed counter is incremented), `false` once the cap
    /// is reached. Callers must check the return value before issuing
    /// the network request.
    public func tryConsume() -> Bool {
        guard consumed < cap else { return false }
        consumed += 1
        return true
    }

    /// Record token usage from one successful API response. Called by
    /// every Claude-backed engine after `client.send(...)` returns.
    /// Per-model accumulation lets the stats panel break down cost by
    /// Sonnet (vision OCR + tables) vs Haiku (cleanup features).
    public func recordUsage(_ usage: Usage, for model: AnthropicModel) {
        var aggregate = modelUsage[model] ?? AggregateUsage()
        aggregate.inputTokens += usage.inputTokens
        aggregate.outputTokens += usage.outputTokens
        aggregate.cacheCreationInputTokens += usage.cacheCreationInputTokens
        aggregate.cacheReadInputTokens += usage.cacheReadInputTokens
        modelUsage[model] = aggregate
    }

    /// Calls still available. Useful for log lines and the cost cap UI.
    public var remaining: Int { max(0, cap - consumed) }

    /// True when the cap has been hit. Equivalent to `remaining == 0`
    /// but reads more naturally at the call site.
    public var isExhausted: Bool { remaining == 0 }
}
