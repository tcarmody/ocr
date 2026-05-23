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
    /// fallback. 0 when Claude wasn't invoked at all. Subdivided
    /// by cause via `pagesRefused` / `pagesEmpty` / `pagesAPIError`.
    public var pagesUsingVisionFallback: Int
    /// Pages where the page-OCR provider failed and the **Tesseract**
    /// fallback produced blocks instead. Distinct from
    /// `pagesUsingVisionFallback` so a Greek / Latin / Arabic /
    /// Hebrew / CJK / Cyrillic book's failures show up under the
    /// engine that actually ran — Vision's numbers stay correct for
    /// English-and-Romance books, and the routing change is visible
    /// in the summary instead of being hidden behind a "Vision"
    /// label.
    public var pagesUsingTesseractFallback: Int
    /// Pages where the provider explicitly refused (Anthropic
    /// `stop_reason: refusal`, Gemini SAFETY / RECITATION). The
    /// headline measurement for content-policy mismatch.
    public var pagesRefused: Int
    /// Pages where the provider returned without refusal but with
    /// no parseable text. Usually a model hiccup rather than a
    /// policy decision; commonly recovers on retry.
    public var pagesEmpty: Int
    /// Pages where the provider call failed at the HTTP / network /
    /// decode layer. Transient by nature; would benefit from retry.
    public var pagesAPIError: Int
    /// Pages where the provider returned 429 (or equivalent) and
    /// the in-client retry budget ran out before the call
    /// succeeded. Distinct from `pagesAPIError` because the fix
    /// is rate-limit configuration (`ClaudeRateLimiter.shared`
    /// caps, or an Anthropic tier upgrade), not retrying harder.
    public var pagesRateLimited: Int
    /// First N page indices (0-based) that were refused. Capped to
    /// keep the persisted size bounded; the debug log carries the
    /// full set when the user wants to dig.
    public var refusedPageIndices: [Int]
    /// Which page-OCR provider ran for this conversion. Stamped
    /// onto stats so future runs of the same book on a different
    /// provider can be compared. Empty when page-OCR mode wasn't
    /// used (cascade-only conversions).
    public var pageOCRProviderId: String
    /// Number of Claude API calls granted by the budget over this
    /// conversion. Includes refused calls (which still cost tokens)
    /// but not budget-exhausted attempts (which never reached the
    /// network).
    public var claudeCallCount: Int
    /// Per-model token usage. Sonnet (OCR + tables) and Haiku
    /// (cleanup features) sum independently — preserved separately
    /// so the cost estimate is accurate at different rates.
    public var claudeUsageByModel: [String: CloudCallBudget.AggregateUsage]
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
        pagesUsingTesseractFallback: Int = 0,
        pagesRefused: Int = 0,
        pagesEmpty: Int = 0,
        pagesAPIError: Int = 0,
        pagesRateLimited: Int = 0,
        refusedPageIndices: [Int] = [],
        pageOCRProviderId: String = "",
        claudeCallCount: Int = 0,
        claudeUsageByModel: [String: CloudCallBudget.AggregateUsage] = [:],
        estimatedCostUSD: Double = 0
    ) {
        self.elapsed = elapsed
        self.observationsBySource = observationsBySource
        self.pagesTrustedEmbeddedText = pagesTrustedEmbeddedText
        self.pagesReOCRd = pagesReOCRd
        self.pagesUsingVisionFallback = pagesUsingVisionFallback
        self.pagesUsingTesseractFallback = pagesUsingTesseractFallback
        self.pagesRefused = pagesRefused
        self.pagesEmpty = pagesEmpty
        self.pagesAPIError = pagesAPIError
        self.pagesRateLimited = pagesRateLimited
        self.refusedPageIndices = refusedPageIndices
        self.pageOCRProviderId = pageOCRProviderId
        self.claudeCallCount = claudeCallCount
        self.claudeUsageByModel = claudeUsageByModel
        self.estimatedCostUSD = estimatedCostUSD
    }

    private enum CodingKeys: String, CodingKey {
        case elapsed, observationsBySource
        case pagesTrustedEmbeddedText, pagesReOCRd
        case pagesUsingVisionFallback, pagesUsingTesseractFallback
        case pagesRefused, pagesEmpty, pagesAPIError, pagesRateLimited
        case refusedPageIndices, pageOCRProviderId
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
        // Per-engine Tesseract fallback count lands 2026-05-17; older
        // queue rows default to 0.
        self.pagesUsingTesseractFallback = try c.decodeIfPresent(Int.self, forKey: .pagesUsingTesseractFallback) ?? 0
        // Refusal-rate fields land in 2026-05-14; default to zero so
        // older queue rows round-trip unchanged.
        self.pagesRefused = try c.decodeIfPresent(Int.self, forKey: .pagesRefused) ?? 0
        self.pagesEmpty = try c.decodeIfPresent(Int.self, forKey: .pagesEmpty) ?? 0
        self.pagesAPIError = try c.decodeIfPresent(Int.self, forKey: .pagesAPIError) ?? 0
        // Rate-limit bucket lands 2026-05-17 alongside
        // ClaudeRateLimiter.shared; older queue rows default to 0.
        self.pagesRateLimited = try c.decodeIfPresent(Int.self, forKey: .pagesRateLimited) ?? 0
        self.refusedPageIndices = try c.decodeIfPresent([Int].self, forKey: .refusedPageIndices) ?? []
        self.pageOCRProviderId = try c.decodeIfPresent(String.self, forKey: .pageOCRProviderId) ?? ""
        self.claudeCallCount = try c.decode(Int.self, forKey: .claudeCallCount)
        self.claudeUsageByModel = try c.decode([String: CloudCallBudget.AggregateUsage].self, forKey: .claudeUsageByModel)
        self.estimatedCostUSD = try c.decode(Double.self, forKey: .estimatedCostUSD)
    }

    /// Pages where the page-OCR provider succeeded — derived from
    /// the failure counts and the re-OCR'd total.
    public var pagesProviderSucceeded: Int {
        max(0, pagesReOCRd - pagesRefused - pagesEmpty - pagesAPIError)
    }

    /// Fraction of provider-invoked pages that came back refused.
    /// 0.0 when no provider call ran. Surface in the UI as a
    /// percentage; the absolute count is in `pagesRefused`.
    public var refusalRate: Double {
        // Denominator: every page where the provider was actually
        // asked. Trust-routed pages don't count (no call was made);
        // budget-exhausted pages don't count either (no call reached
        // the network). Approximated by `pagesReOCRd` since every
        // re-OCR'd page either succeeded with the provider or
        // failed through one of the tracked statuses.
        guard pagesReOCRd > 0 else { return 0 }
        return Double(pagesRefused) / Double(pagesReOCRd)
    }

    /// One-line summary for log output and quick UI rendering.
    /// Calls out the trust verdict explicitly when *every* page was
    /// trusted (so OCR didn't run at all) — that's a frequent
    /// source of "the output looks bad and Claude wasn't invoked,
    /// what gives" confusion. When the page-OCR provider refused
    /// any pages, the refusal count + rate lead the summary —
    /// users with high refusal rates need to see the headline first.
    public var summary: String {
        let totalPages = pagesTrustedEmbeddedText + pagesReOCRd
        let refusalSuffix: String
        if pagesRefused > 0 {
            let pct = String(format: "%.0f%%", refusalRate * 100)
            let providerLabel = pageOCRProviderId.isEmpty
                ? "" : " (\(pageOCRProviderId))"
            refusalSuffix = " · \(pagesRefused) refused (\(pct))\(providerLabel)"
        } else {
            refusalSuffix = ""
        }
        let rateLimitSuffix = pagesRateLimited > 0
            ? " · \(pagesRateLimited) rate-limited"
            : ""
        let fallbackSuffix: String
        switch (pagesUsingVisionFallback, pagesUsingTesseractFallback) {
        case (0, 0):
            fallbackSuffix = ""
        case let (v, 0):
            fallbackSuffix = " · \(v) page\(v == 1 ? "" : "s") fell back to Vision"
        case let (0, t):
            fallbackSuffix = " · \(t) page\(t == 1 ? "" : "s") fell back to Tesseract"
        case let (v, t):
            fallbackSuffix = " · \(v) → Vision, \(t) → Tesseract fallback"
        }
        if totalPages > 0, pagesReOCRd == 0 {
            return "Trusted embedded PDF text on all \(totalPages) pages — OCR did not run"
                + fallbackSuffix + rateLimitSuffix
        }
        if claudeCallCount > 0 {
            return "Claude: \(claudeCallCount) calls (~\(formattedCost))"
                + refusalSuffix + rateLimitSuffix + fallbackSuffix
        }
        if pagesTrustedEmbeddedText > 0 && pagesReOCRd > 0 {
            return "OCR'd \(pagesReOCRd) of \(totalPages) pages (rest trusted embedded text); Claude not invoked"
                + refusalSuffix + rateLimitSuffix + fallbackSuffix
        }
        return "Claude not invoked" + refusalSuffix + rateLimitSuffix + fallbackSuffix
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
        pagesUsingTesseractFallback: Int = 0,
        pagesRefused: Int = 0,
        pagesEmpty: Int = 0,
        pagesAPIError: Int = 0,
        pagesRateLimited: Int = 0,
        refusedPageIndices: [Int] = [],
        pageOCRProviderId: String = "",
        claudeCallCount: Int,
        claudeUsageByModel: [AnthropicModel: CloudCallBudget.AggregateUsage]
    ) -> ConversionStats {
        // Stringify keys for JSON stability.
        let sources: [String: Int] = Dictionary(
            uniqueKeysWithValues: observationsBySource.map {
                (Self.sourceKey($0.key), $0.value)
            }
        )
        let usage: [String: CloudCallBudget.AggregateUsage] = Dictionary(
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
            pagesUsingTesseractFallback: pagesUsingTesseractFallback,
            pagesRefused: pagesRefused,
            pagesEmpty: pagesEmpty,
            pagesAPIError: pagesAPIError,
            pagesRateLimited: pagesRateLimited,
            refusedPageIndices: refusedPageIndices,
            pageOCRProviderId: pageOCRProviderId,
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
