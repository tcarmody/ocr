import XCTest
import AI
import OCR
@testable import Pipeline

/// Tests `ConversionStats` — the post-conversion summary returned
/// from `PDFToEPUBPipeline.convert()`. Tests focus on the math
/// (cost rollups across models, source-tally serialization) and
/// the user-facing strings that go into the queue UI.
final class ConversionStatsTests: XCTestCase {

    // MARK: - Summary string

    func test_summary_reads_correctly_when_claude_didnt_fire() {
        let stats = ConversionStats(claudeCallCount: 0, estimatedCostUSD: 0)
        XCTAssertEqual(stats.summary, "Claude not invoked")
    }

    func test_summary_includes_call_count_and_cost_when_claude_fired() {
        let stats = ConversionStats(claudeCallCount: 12, estimatedCostUSD: 0.06)
        XCTAssertEqual(stats.summary, "Claude: 12 calls (~$0.06)")
    }

    func test_formatted_cost_uses_under_one_cent_threshold() {
        let stats = ConversionStats(claudeCallCount: 1, estimatedCostUSD: 0.003)
        XCTAssertEqual(stats.formattedCost, "<$0.01")
    }

    func test_formatted_cost_handles_dollars() {
        let stats = ConversionStats(claudeCallCount: 100, estimatedCostUSD: 1.5)
        XCTAssertEqual(stats.formattedCost, "$1.50")
    }

    // MARK: - Stats construction

    func test_make_stringifies_observation_sources_for_codable_stability() {
        let stats = ConversionStats.make(
            elapsed: 12.5,
            observationsBySource: [.vision: 100, .claude: 12, .tesseract: 28],
            claudeCallCount: 12,
            claudeUsageByModel: [:]
        )
        XCTAssertEqual(stats.observationsBySource["vision"], 100)
        XCTAssertEqual(stats.observationsBySource["claude"], 12)
        XCTAssertEqual(stats.observationsBySource["tesseract"], 28)
        XCTAssertNil(stats.observationsBySource["surya"])
    }

    func test_cost_estimate_sums_per_model_rates() {
        // Sonnet: 1k input + 500 output = 1k×3$/MTok + 500×15$/MTok
        //       = 0.003 + 0.0075 = 0.0105
        // Haiku:  500 input + 250 output = 500×1$/MTok + 250×5$/MTok
        //       = 0.0005 + 0.00125 = 0.00175
        // Total: 0.01225
        let sonnetUsage = ClaudeCallBudget.AggregateUsage(
            inputTokens: 1000, outputTokens: 500
        )
        let haikuUsage = ClaudeCallBudget.AggregateUsage(
            inputTokens: 500, outputTokens: 250
        )
        let stats = ConversionStats.make(
            elapsed: 0,
            observationsBySource: [:],
            claudeCallCount: 2,
            claudeUsageByModel: [.sonnet4_6: sonnetUsage, .haiku4_5: haikuUsage]
        )
        XCTAssertEqual(stats.estimatedCostUSD, 0.01225, accuracy: 0.0001)
    }

    func test_cost_estimate_includes_cache_tokens() {
        // 1k cache-creation = 1k × (1.25 × $3/MTok) = $0.00375
        // 1k cache-read    = 1k × (0.1  × $3/MTok) = $0.0003
        // 1k input         = 1k × $3/MTok          = $0.003
        // 100 output       = 100 × $15/MTok        = $0.0015
        // Total ≈ $0.00855
        let usage = ClaudeCallBudget.AggregateUsage(
            inputTokens: 1000,
            outputTokens: 100,
            cacheCreationInputTokens: 1000,
            cacheReadInputTokens: 1000
        )
        let stats = ConversionStats.make(
            elapsed: 0,
            observationsBySource: [:],
            claudeCallCount: 1,
            claudeUsageByModel: [.sonnet4_6: usage]
        )
        XCTAssertEqual(stats.estimatedCostUSD, 0.00855, accuracy: 0.0001)
    }

    // MARK: - Codable round-trip

    /// Persisted on `Job` values via the queue store's JSON
    /// encoding. Round-trip ensures stats survive an app restart.
    func test_round_trips_through_json() throws {
        let original = ConversionStats(
            elapsed: 18.4,
            observationsBySource: ["vision": 100, "claude": 12],
            claudeCallCount: 12,
            claudeUsageByModel: [
                "claude-sonnet-4-6": ClaudeCallBudget.AggregateUsage(
                    inputTokens: 5000, outputTokens: 1200
                )
            ],
            estimatedCostUSD: 0.033
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversionStats.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }
}

/// Tests for `ClaudeCallBudget`'s usage-recording extension. The
/// existing `ClaudeCallBudgetTests` covered the consume/cap logic;
/// these add per-model usage accumulation.
final class ClaudeCallBudgetUsageTests: XCTestCase {

    func test_recordUsage_accumulates_across_calls() async {
        let budget = ClaudeCallBudget(cap: 100)
        await budget.recordUsage(
            Usage(inputTokens: 100, outputTokens: 50),
            for: .sonnet4_6
        )
        await budget.recordUsage(
            Usage(inputTokens: 200, outputTokens: 75),
            for: .sonnet4_6
        )
        let usage = await budget.modelUsage[.sonnet4_6]
        XCTAssertEqual(usage?.inputTokens, 300)
        XCTAssertEqual(usage?.outputTokens, 125)
    }

    func test_recordUsage_separates_models() async {
        let budget = ClaudeCallBudget(cap: 100)
        await budget.recordUsage(
            Usage(inputTokens: 100, outputTokens: 50),
            for: .sonnet4_6
        )
        await budget.recordUsage(
            Usage(inputTokens: 80, outputTokens: 30),
            for: .haiku4_5
        )
        let sonnet = await budget.modelUsage[.sonnet4_6]
        let haiku = await budget.modelUsage[.haiku4_5]
        XCTAssertEqual(sonnet?.inputTokens, 100)
        XCTAssertEqual(haiku?.inputTokens, 80)
    }

    func test_recordUsage_accumulates_cache_fields() async {
        let budget = ClaudeCallBudget(cap: 100)
        await budget.recordUsage(
            Usage(
                inputTokens: 100,
                outputTokens: 50,
                cacheCreationInputTokens: 1000,
                cacheReadInputTokens: 2000
            ),
            for: .sonnet4_6
        )
        let usage = await budget.modelUsage[.sonnet4_6]
        XCTAssertEqual(usage?.cacheCreationInputTokens, 1000)
        XCTAssertEqual(usage?.cacheReadInputTokens, 2000)
        XCTAssertEqual(usage?.total, 100 + 50 + 1000 + 2000)
    }

    func test_aggregate_usage_codable_round_trips() throws {
        let usage = ClaudeCallBudget.AggregateUsage(
            inputTokens: 1234,
            outputTokens: 567,
            cacheCreationInputTokens: 89,
            cacheReadInputTokens: 12
        )
        let encoded = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(
            ClaudeCallBudget.AggregateUsage.self, from: encoded
        )
        XCTAssertEqual(usage, decoded)
    }
}

/// Tests for `Pricing` — the per-model rate table on `AnthropicModel`.
final class PricingTests: XCTestCase {
    func test_sonnet_rates() {
        let p = AnthropicModel.sonnet4_6.pricing
        XCTAssertEqual(p.inputPerMTok, 3.00)
        XCTAssertEqual(p.outputPerMTok, 15.00)
    }

    func test_haiku_rates() {
        let p = AnthropicModel.haiku4_5.pricing
        XCTAssertEqual(p.inputPerMTok, 1.00)
        XCTAssertEqual(p.outputPerMTok, 5.00)
    }

    func test_haiku_dated_alias_uses_same_rates() {
        let p = AnthropicModel.haiku4_5_20251001.pricing
        XCTAssertEqual(p.inputPerMTok, 1.00)
    }

    func test_unknown_model_falls_back_to_sonnet_rates() {
        let p = AnthropicModel(rawValue: "claude-future-9-9").pricing
        XCTAssertEqual(p.inputPerMTok, 3.00)
    }

    func test_cache_rates_derived_from_input() {
        let p = AnthropicModel.sonnet4_6.pricing
        XCTAssertEqual(p.cacheCreationPerMTok, 3.75)  // 1.25× input
        XCTAssertEqual(p.cacheReadPerMTok, 0.30, accuracy: 0.001)  // 0.1× input
    }
}
