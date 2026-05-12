import Foundation
import AI
import OCR

/// Post-conversion summary returned by `PDFToEPUBPipeline.convert(...)`.
///
/// Lets the caller (today: `JobRunner`; tomorrow: the editor's re-OCR
/// path and the AI trail inspector) surface "did Claude fire on this
/// book, and how much did it cost" without parsing the debug log.
///
/// Codable so it can persist on a `Job` value through the queue
/// store's JSON round-trip.
public struct ConversionStats: Sendable, Codable, Equatable {
    /// Wall-clock seconds spent in `convert(...)`.
    public var elapsed: TimeInterval
    /// Total observations emitted across all pages, broken down by
    /// the engine that produced each one. The `[String: Int]`
    /// representation (rather than `[ObservationSource: Int]`)
    /// keeps the JSON encoding stable across `ObservationSource`
    /// case additions / renames.
    public var observationsBySource: [String: Int]
    /// Pages whose embedded text the scorer trusted — OCR did NOT
    /// run on these. Important to surface separately from the
    /// observation counts because trusted-text observations come
    /// out as `source: .embedded` in the tally, and the user
    /// reading "100% embedded" might mistakenly think the cascade
    /// approved the result when in fact OCR was bypassed entirely.
    public var pagesTrustedEmbeddedText: Int
    /// Pages that went through render + OCR + cascade.
    public var pagesReOCRd: Int
    /// Pages where Claude page-OCR refused / errored / timed out
    /// / returned an unparseable result and the pipeline fell back
    /// to local Vision OCR so the page contributed *something* to
    /// the EPUB. Surfaced to make quality degradation visible —
    /// otherwise a user looking at a poorly-rendered page can't
    /// tell whether it's a Sonnet bug or expected lower-quality
    /// fallback. 0 when Claude wasn't invoked at all.
    public var pagesUsingVisionFallback: Int
    /// Number of Claude API calls granted by the budget over this
    /// conversion. Includes refused calls (which still cost tokens)
    /// but not budget-exhausted attempts (which never reached the
    /// network).
    public var claudeCallCount: Int
    /// Per-model token usage. Sonnet (OCR + tables) and Haiku
    /// (cleanup features) sum independently — preserved separately
    /// so the cost estimate is accurate at different rates.
    public var claudeUsageByModel: [String: ClaudeCallBudget.AggregateUsage]
    /// Estimated USD cost across all Claude calls. Computed from
    /// per-model usage and the rate table on `AnthropicModel`.
    /// Estimate, not invoice — Anthropic's billing is authoritative.
    public var estimatedCostUSD: Double

    public init(
        elapsed: TimeInterval = 0,
        observationsBySource: [String: Int] = [:],
        pagesTrustedEmbeddedText: Int = 0,
        pagesReOCRd: Int = 0,
        pagesUsingVisionFallback: Int = 0,
        claudeCallCount: Int = 0,
        claudeUsageByModel: [String: ClaudeCallBudget.AggregateUsage] = [:],
        estimatedCostUSD: Double = 0
    ) {
        self.elapsed = elapsed
        self.observationsBySource = observationsBySource
        self.pagesTrustedEmbeddedText = pagesTrustedEmbeddedText
        self.pagesReOCRd = pagesReOCRd
        self.pagesUsingVisionFallback = pagesUsingVisionFallback
        self.claudeCallCount = claudeCallCount
        self.claudeUsageByModel = claudeUsageByModel
        self.estimatedCostUSD = estimatedCostUSD
    }

    private enum CodingKeys: String, CodingKey {
        case elapsed, observationsBySource
        case pagesTrustedEmbeddedText, pagesReOCRd
        case pagesUsingVisionFallback
        case claudeCallCount, claudeUsageByModel, estimatedCostUSD
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.elapsed = try c.decode(TimeInterval.self, forKey: .elapsed)
        self.observationsBySource = try c.decode([String: Int].self, forKey: .observationsBySource)
        // Decode the trust-verdict fields optionally so stats persisted
        // before this field existed don't break the queue store.
        self.pagesTrustedEmbeddedText = try c.decodeIfPresent(Int.self, forKey: .pagesTrustedEmbeddedText) ?? 0
        self.pagesReOCRd = try c.decodeIfPresent(Int.self, forKey: .pagesReOCRd) ?? 0
        // Same optional posture for the Vision-fallback count —
        // older queue rows persisted before Q-Refused-Fallback-Surface
        // (2026-05-12) don't carry it.
        self.pagesUsingVisionFallback = try c.decodeIfPresent(Int.self, forKey: .pagesUsingVisionFallback) ?? 0
        self.claudeCallCount = try c.decode(Int.self, forKey: .claudeCallCount)
        self.claudeUsageByModel = try c.decode([String: ClaudeCallBudget.AggregateUsage].self, forKey: .claudeUsageByModel)
        self.estimatedCostUSD = try c.decode(Double.self, forKey: .estimatedCostUSD)
    }

    /// One-line summary for log output and quick UI rendering.
    /// Calls out the trust verdict explicitly when *every* page was
    /// trusted (so OCR didn't run at all) — that's a frequent
    /// source of "the output looks bad and Claude wasn't invoked,
    /// what gives" confusion.
    public var summary: String {
        let totalPages = pagesTrustedEmbeddedText + pagesReOCRd
        let fallbackSuffix = pagesUsingVisionFallback > 0
            ? " · \(pagesUsingVisionFallback) page\(pagesUsingVisionFallback == 1 ? "" : "s") fell back to Vision"
            : ""
        if totalPages > 0, pagesReOCRd == 0 {
            return "Trusted embedded PDF text on all \(totalPages) pages — OCR did not run"
                + fallbackSuffix
        }
        if claudeCallCount > 0 {
            return "Claude: \(claudeCallCount) calls (~\(formattedCost))"
                + fallbackSuffix
        }
        if pagesTrustedEmbeddedText > 0 && pagesReOCRd > 0 {
            return "OCR'd \(pagesReOCRd) of \(totalPages) pages (rest trusted embedded text); Claude not invoked"
                + fallbackSuffix
        }
        return "Claude not invoked" + fallbackSuffix
    }

    /// Formatted cost string with sensible precision: "<$0.01" for
    /// near-zero, "$0.06" for cents, "$1.50" for dollars.
    public var formattedCost: String {
        if estimatedCostUSD < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", estimatedCostUSD)
    }
}

extension ConversionStats {
    /// Build stats from the raw inputs the pipeline has on hand at
    /// the end of `convert(...)`. The caller (PDFToEPUBPipeline)
    /// passes the page-level observation tally and the post-run
    /// budget actor's snapshot; we compose the report.
    static func make(
        elapsed: TimeInterval,
        observationsBySource: [ObservationSource: Int],
        pagesTrustedEmbeddedText: Int = 0,
        pagesReOCRd: Int = 0,
        pagesUsingVisionFallback: Int = 0,
        claudeCallCount: Int,
        claudeUsageByModel: [AnthropicModel: ClaudeCallBudget.AggregateUsage]
    ) -> ConversionStats {
        // Stringify keys for JSON stability.
        let sources: [String: Int] = Dictionary(
            uniqueKeysWithValues: observationsBySource.map {
                (Self.sourceKey($0.key), $0.value)
            }
        )
        let usage: [String: ClaudeCallBudget.AggregateUsage] = Dictionary(
            uniqueKeysWithValues: claudeUsageByModel.map { ($0.key.rawValue, $0.value) }
        )
        // Cost = sum over models of (model's pricing × accumulated usage).
        let cost = claudeUsageByModel.reduce(0.0) { acc, kv in
            acc + kv.key.pricing.cost(for: kv.value.asUsage)
        }
        return ConversionStats(
            elapsed: elapsed,
            observationsBySource: sources,
            pagesTrustedEmbeddedText: pagesTrustedEmbeddedText,
            pagesReOCRd: pagesReOCRd,
            pagesUsingVisionFallback: pagesUsingVisionFallback,
            claudeCallCount: claudeCallCount,
            claudeUsageByModel: usage,
            estimatedCostUSD: cost
        )
    }

    static func sourceKey(_ source: ObservationSource) -> String {
        switch source {
        case .vision:    return "vision"
        case .embedded:  return "embedded"
        case .tesseract: return "tesseract"
        case .surya:     return "surya"
        case .claude:    return "claude"
        }
    }
}
