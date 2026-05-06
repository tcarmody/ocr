import Foundation
import AI
import PDFIngest

/// Pre-flight cost estimator. Given a `DocumentProfile` (from
/// `DocumentProfiler` at queue-add) plus the user's enabled Cloud
/// features, produces a coarse "before you click Convert, this is
/// what it will cost" estimate.
///
/// **The estimate is intentionally rough.** Per-book actual cost
/// depends on which regions trip the cascade's quality floor, how
/// often Haiku rejects via the guardrail, and per-call token counts
/// that vary with region size. The estimate uses fixed per-feature
/// trigger rates and average per-call token counts to land in the
/// right order of magnitude — enough to flag a likely-expensive
/// run before the user kicks it off, not enough to reconcile with
/// Anthropic's billing afterwards.
///
/// Outputs both a single `estimatedCostUSD` and a per-feature
/// breakdown so the queue UI can show a one-liner with a tooltip.
public enum CostEstimator {

    public struct Estimate: Sendable, Equatable, Codable {
        /// Total estimated Claude calls for this conversion across
        /// all enabled features. Capped at `perBookCallCap` — the
        /// cap is a hard ceiling at runtime, so the estimate above
        /// that doesn't represent reality.
        public var estimatedCalls: Int
        /// Total estimated USD cost across all features.
        public var estimatedCostUSD: Double
        /// Per-feature breakdown for the tooltip / detail view.
        public var perFeature: [Line]
        /// True when `estimatedCalls` was capped by `perBookCallCap`.
        /// Surfaced so the UI can warn "your cap will throttle this run."
        public var clampedByCap: Bool

        public struct Line: Sendable, Equatable, Codable {
            public var label: String
            public var model: String
            public var calls: Int
            public var costUSD: Double
        }

        public static let empty = Estimate(
            estimatedCalls: 0,
            estimatedCostUSD: 0,
            perFeature: [],
            clampedByCap: false
        )
    }

    /// Average text-bearing regions per page. Used as the multiplier
    /// for per-region trigger rates. The pipeline's actual per-page
    /// region count varies with content density (poetry pages: ~3,
    /// dense academic pages: ~7-10, two-up scans: ~6). 5 is a
    /// reasonable middle.
    public static let regionsPerPageEstimate: Double = 5

    /// Per-region trigger rate for hard-region OCR. The cascade
    /// invokes Stage 3 (Claude) only when Vision/Tesseract output
    /// trips the quality floor; on a clean born-digital book that's
    /// near zero, on a scanned book it's ~5-15%.
    public static let hardRegionOCRRateScan: Double = 0.10
    public static let hardRegionOCRRateBornDigital: Double = 0.005

    /// Per-region trigger rate for post-OCR Haiku cleanup. Slightly
    /// lower than hard-region OCR — only fires when
    /// `OCRTextQualityScorer.combined < 0.6`, which is a tighter
    /// gate than the cascade's general "this region is suspect"
    /// triggers.
    public static let postOCRCleanupRateScan: Double = 0.10
    public static let postOCRCleanupRateBornDigital: Double = 0.05

    /// Estimated tables per book. Without running Surya layout at
    /// queue-add (too slow), we don't know real table density;
    /// "0.5 tables per book" is a reasonable average across a mixed
    /// corpus of academic books.
    public static let tablesPerBookEstimate: Double = 0.5

    /// Average per-call cost in USD for each enabled feature.
    /// Derived from typical per-call token counts × the model's
    /// rate-table prices. These constants don't account for
    /// prompt-cache read discounts (which apply to system prompt
    /// reuse on Sonnet calls in particular) — the real conversion
    /// will pay slightly less than estimated when caching kicks in.
    public static func costPerCall(_ feature: Feature) -> Double {
        switch feature {
        case .hardRegionOCR:
            // Sonnet 4.6: ~1500 input (region image, ~10K base64
            // chars) + ~500 output (transcription).
            return AnthropicModel.sonnet4_6.pricing.cost(for: Usage(
                inputTokens: 1500, outputTokens: 500
            ))
        case .postOCRCleanupPassages:
            // Haiku 4.5: ~500 input (text + prompts) + ~200 output.
            return AnthropicModel.haiku4_5.pricing.cost(for: Usage(
                inputTokens: 500, outputTokens: 200
            ))
        case .postOCRCleanupVision:
            // Haiku 4.5 with image: ~3000 input + ~200 output.
            return AnthropicModel.haiku4_5.pricing.cost(for: Usage(
                inputTokens: 3000, outputTokens: 200
            ))
        case .tableExtraction:
            // Sonnet 4.6: ~2500 input (table region image) + ~800
            // output (cell array).
            return AnthropicModel.sonnet4_6.pricing.cost(for: Usage(
                inputTokens: 2500, outputTokens: 800
            ))
        case .pageOCR:
            // Sonnet 4.6: ~4000 input (full-page image at 600 DPI,
            // base64) + ~2000 output (XHTML for typical academic
            // page; dense pages can run higher). The output cost
            // dominates; a 400-page book runs ~$16-20.
            return AnthropicModel.sonnet4_6.pricing.cost(for: Usage(
                inputTokens: 4000, outputTokens: 2000
            ))
        }
    }

    public enum Feature: Sendable, Equatable {
        case hardRegionOCR
        case postOCRCleanupPassages
        case postOCRCleanupVision
        case tableExtraction
        case pageOCR
    }

    /// Compute a coarse pre-flight cost estimate. When
    /// `useClaudePageOCR` is set, the cascade-based per-region
    /// estimate is replaced with a single per-page Sonnet line item
    /// — the Phase 2 path makes one call per page instead of
    /// selectively escalating regions, so per-region rates don't
    /// apply.
    public static func estimate(
        profile: DocumentProfile,
        cloudFeatures: AISettings.CloudFeatures,
        perBookCallCap: Int,
        useClaudePageOCR: Bool = false
    ) -> Estimate {
        guard profile.pageCount > 0 else { return .empty }
        let regions = Double(profile.pageCount) * regionsPerPageEstimate

        var lines: [Estimate.Line] = []
        var totalCalls = 0
        var totalCost: Double = 0

        // Page-OCR mode: one Sonnet call per page; replaces the
        // hard-region-OCR + post-OCR-cleanup line items entirely.
        // Table extraction can still run as a separate feature.
        if useClaudePageOCR {
            let calls = profile.pageCount
            let cost = Double(calls) * costPerCall(.pageOCR)
            lines.append(.init(
                label: "Page OCR (whole-page Sonnet)",
                model: AnthropicModel.sonnet4_6.rawValue,
                calls: calls, costUSD: cost
            ))
            totalCalls += calls
            totalCost += cost

            // Table extraction is independent of OCR mode — it
            // operates on Surya-detected `.table` regions, runs
            // even when the page-OCR path supplies the body text.
            if cloudFeatures.tableExtraction {
                let tableCalls = Int(tablesPerBookEstimate.rounded())
                if tableCalls > 0 {
                    let tableCost = Double(tableCalls)
                        * costPerCall(.tableExtraction)
                    lines.append(.init(
                        label: "Table extraction",
                        model: AnthropicModel.sonnet4_6.rawValue,
                        calls: tableCalls, costUSD: tableCost
                    ))
                    totalCalls += tableCalls
                    totalCost += tableCost
                }
            }

            return clamp(
                lines: lines,
                totalCalls: totalCalls,
                totalCost: totalCost,
                perBookCallCap: perBookCallCap
            )
        }

        // Hard-region OCR (Sonnet, on `.cloud` mode + feature toggle).
        if cloudFeatures.hardRegionOCR {
            let rate = profile.isLikelyScan
                ? hardRegionOCRRateScan
                : hardRegionOCRRateBornDigital
            let calls = Int((regions * rate).rounded())
            if calls > 0 {
                let cost = Double(calls) * costPerCall(.hardRegionOCR)
                lines.append(.init(
                    label: "Hard-region OCR",
                    model: AnthropicModel.sonnet4_6.rawValue,
                    calls: calls, costUSD: cost
                ))
                totalCalls += calls
                totalCost += cost
            }
        }

        // Post-OCR cleanup (Haiku). Vision mode uses the same call
        // count as passages — same regions trigger; it just costs
        // more per call.
        if cloudFeatures.postOCRCleanup {
            let rate = profile.isLikelyScan
                ? postOCRCleanupRateScan
                : postOCRCleanupRateBornDigital
            let calls = Int((regions * rate).rounded())
            if calls > 0 {
                let feature: Feature = cloudFeatures.postOCRCleanupVisionMode
                    ? .postOCRCleanupVision : .postOCRCleanupPassages
                let cost = Double(calls) * costPerCall(feature)
                lines.append(.init(
                    label: "Post-OCR cleanup"
                        + (cloudFeatures.postOCRCleanupVisionMode ? " (vision)" : ""),
                    model: AnthropicModel.haiku4_5.rawValue,
                    calls: calls, costUSD: cost
                ))
                totalCalls += calls
                totalCost += cost
            }
        }

        // Table extraction (Sonnet). Per-book estimate, not per-page;
        // tables are rare regardless of page count.
        if cloudFeatures.tableExtraction {
            let calls = Int(tablesPerBookEstimate.rounded())
            if calls > 0 {
                let cost = Double(calls) * costPerCall(.tableExtraction)
                lines.append(.init(
                    label: "Table extraction",
                    model: AnthropicModel.sonnet4_6.rawValue,
                    calls: calls, costUSD: cost
                ))
                totalCalls += calls
                totalCost += cost
            }
        }

        return clamp(
            lines: lines,
            totalCalls: totalCalls,
            totalCost: totalCost,
            perBookCallCap: perBookCallCap
        )
    }

    /// Clamp totals + line items against `perBookCallCap`. The
    /// runtime budget enforces this hard ceiling, so any estimate
    /// above it is unrealistic — scale every line proportionally and
    /// flag the clamp for the UI so the user can either raise the
    /// cap or understand why their job will throttle.
    private static func clamp(
        lines: [Estimate.Line],
        totalCalls: Int,
        totalCost: Double,
        perBookCallCap: Int
    ) -> Estimate {
        let clamped = totalCalls > perBookCallCap
        guard clamped, totalCalls > 0 else {
            return Estimate(
                estimatedCalls: totalCalls,
                estimatedCostUSD: totalCost,
                perFeature: lines,
                clampedByCap: false
            )
        }
        let scale = Double(perBookCallCap) / Double(totalCalls)
        let scaledLines = lines.map { line in
            Estimate.Line(
                label: line.label,
                model: line.model,
                calls: Int((Double(line.calls) * scale).rounded()),
                costUSD: line.costUSD * scale
            )
        }
        return Estimate(
            estimatedCalls: perBookCallCap,
            estimatedCostUSD: totalCost * scale,
            perFeature: scaledLines,
            clampedByCap: true
        )
    }
}
