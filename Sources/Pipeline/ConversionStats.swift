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
        claudeCallCount: Int = 0,
        claudeUsageByModel: [String: ClaudeCallBudget.AggregateUsage] = [:],
        estimatedCostUSD: Double = 0
    ) {
        self.elapsed = elapsed
        self.observationsBySource = observationsBySource
        self.claudeCallCount = claudeCallCount
        self.claudeUsageByModel = claudeUsageByModel
        self.estimatedCostUSD = estimatedCostUSD
    }

    /// One-line summary for log output and quick UI rendering.
    /// Examples:
    ///   "Claude not invoked"
    ///   "Claude: 12 calls (~$0.06)"
    public var summary: String {
        guard claudeCallCount > 0 else { return "Claude not invoked" }
        return "Claude: \(claudeCallCount) calls (~\(formattedCost))"
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
