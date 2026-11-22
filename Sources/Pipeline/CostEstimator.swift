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
/// often the cleanup model rejects via the guardrail, and per-call
/// token counts that vary with region size. The estimate uses fixed
/// per-feature trigger rates and average per-call token counts to
/// land in the right order of magnitude — enough to flag a likely-
/// expensive run before the user kicks it off, not enough to
/// reconcile with the provider's billing afterwards. Provider-
/// agnostic: counts cloud calls against whichever model the user
/// configured (Anthropic + Google Gemini + Google Cloud Vision +
/// LandingAI ADE all factor in).
///
/// Outputs both a single `estimatedCostUSD` and a per-feature
/// breakdown so the queue UI can show a one-liner with a tooltip.
public enum CostEstimator {

    public struct Estimate: Sendable, Equatable, Codable {
        /// Total estimated cloud calls for this conversion across
        /// all enabled features and providers. Capped at
        /// `perBookCallCap` — the cap is a hard ceiling at runtime,
        /// so the estimate above that doesn't represent reality.
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
    /// invokes the final cloud tier (Claude Sonnet or Gemini Flash
    /// depending on `pageOCRProvider`) only when Vision/Tesseract
    /// output trips the quality floor; on a clean born-digital
    /// book that's near zero, on a scanned book it's ~5-15%. The
    /// per-call cost constant below assumes Sonnet rates as the
    /// upper bound — Gemini-routed runs are cheaper in practice.
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
            // Sonnet 5.5: ~1500 input (region image, ~10K base64
            // chars) + ~650 output (transcription; 4.6 figure of 500
            // scaled ~1.3x for the 5.5 tokenizer).
            return CloudModel.sonnet5_5.pricing.cost(for: Usage(
                inputTokens: 1500, outputTokens: 650
            ))
        case .postOCRCleanupPassages:
            // Haiku 5.5: ~650 input (text + prompts) + ~260 output
            // (Haiku 4.5 figures of 500 / 200, scaled ~1.3x for the
            // Haiku 5.5 tokenizer).
            return CloudModel.haiku5_5.pricing.cost(for: Usage(
                inputTokens: 650, outputTokens: 260
            ))
        case .postOCRCleanupVision:
            // Haiku 5.5 with image: ~3150 input (image + ~650 text)
            // + ~260 output, tokenizer-scaled as above.
            return CloudModel.haiku5_5.pricing.cost(for: Usage(
                inputTokens: 3150, outputTokens: 260
            ))
        case .tableExtraction:
            // Sonnet 5.5: ~2500 input (table region image) + ~1040
            // output (cell array; tokenizer-scaled from 800).
            return CloudModel.sonnet5_5.pricing.cost(for: Usage(
                inputTokens: 2500, outputTokens: 1040
            ))
        case .pageOCR:
            // Sonnet 5.5: ~7200 input (full-page image at the high-res
            // limit, 2576 px / 3.75 MP:
            // ~4800 image tokens vs ~1600 at the old 1568 px, plus
            // prompt) + ~2600 output (XHTML for typical academic
            // page, tokenizer-scaled from 2000; dense pages can run
            // higher). ~$0.04 / page; a 400-page book runs ~$15-19.
            return CloudModel.sonnet5_5.pricing.cost(for: Usage(
                inputTokens: 7200, outputTokens: 2600
            ))
        case .pageOCRGemini:
            // Gemini 2.5 Flash: ~1000 input (image tiles bill at
            // ~258 tokens/tile vs Claude's ~1500) + ~2000 output.
            // Per-page cost lands around $0.005 vs Sonnet 5.5 ~$0.04
            // — a 400-page book runs ~$2-3.
            return CloudModel.gemini25Flash.pricing.cost(for: Usage(
                inputTokens: 1000, outputTokens: 2000
            ))
        case .pageOCRGemini3Preview:
            // Gemini 3 Flash preview: ~25-67% more expensive than
            // 2.5 Flash at the per-token level. Same token shape on
            // input (image tiles ~258 tokens). Output token count
            // assumes `thinking_level: minimal` — without that pin
            // reasoning would inflate output significantly.
            return CloudModel.gemini3FlashPreview.pricing.cost(for: Usage(
                inputTokens: 1000, outputTokens: 2000
            ))
        case .pageOCRGemini35:
            // Gemini 3.5 Flash (stable, May 2026): 3× the per-token
            // rates of 3 Flash Preview. Per-page lands ~$0.02 — about
            // half of Sonnet. Same `thinking_level: minimal` pin so
            // output stays bounded.
            return CloudModel.gemini35Flash.pricing.cost(for: Usage(
                inputTokens: 1000, outputTokens: 2000
            ))
        case .googleDocumentOCR:
            // Cloud Vision DOCUMENT_TEXT_DETECTION: fixed $0.0015
            // per call. Encoded in `CloudModel.pricing` as one
            // synthetic output token × $1500/M.
            return CloudModel.googleDocumentOCR.pricing.cost(for: Usage(
                inputTokens: 0, outputTokens: 1
            ))
        case .landingAIDocumentOCR:
            // LandingAI DPT-3 Pro on a cropped region (Stage 2.5
            // alternative, or one table region): 1 credit for the
            // page + 0.5 credits per 1,000 output characters. A
            // typical ~500-character region lands at ~1.3 credits,
            // carried as 13 tenth-of-a-credit tokens ($0.013).
            return CloudModel.landingAIDPT3Pro.pricing.cost(for: Usage(
                inputTokens: 0, outputTokens: 13
            ))
        case .landingAIPageOCR:
            // LandingAI DPT-3 Pro on a whole page: 1 credit + 0.5 per
            // 1,000 output characters; a typical ~3,000-character
            // academic page is ~2.5 credits = 25 tokens ($0.025).
            // Dense pages cost more — the charge scales with output.
            return CloudModel.landingAIDPT3Pro.pricing.cost(for: Usage(
                inputTokens: 0, outputTokens: 25
            ))
        case .chapterStructurePass:
            // Sonnet 5.5: one call per book validating the chapter
            // list. ~6.5K input tokens (chapter titles + opening text
            // per chapter, capped at 16K) + ~1.3K output (per-chapter
            // decision JSON), tokenizer-scaled from 5K / 1K. Lands
            // around $0.02-0.04 per book.
            return CloudModel.sonnet5_5.pricing.cost(for: Usage(
                inputTokens: 6500, outputTokens: 1300
            ))
        case .chapterMissedBreakDetection:
            // Sonnet 5.5: one call per book reading the full text.
            // ~104K input tokens (capped via mid-chapter truncation
            // for very long books) + ~650 output (typically 0-3
            // insertions), tokenizer-scaled from 80K / 500. Lands
            // around $0.21-0.26 per book.
            return CloudModel.sonnet5_5.pricing.cost(for: Usage(
                inputTokens: 104_000, outputTokens: 650
            ))
        case .frontBackMatterSplitting:
            // Sonnet 5.5: one call per book scanning only the
            // chapters identified as front-matter / back-matter.
            // Typical book: ~5 candidate chapters × ~3K chars each
            // ≈ 20K-26K input tokens + ~390 output (tokenizer-scaled
            // from 15-20K / 300). Lands around $0.04-0.06 per book;
            // floor at $0 when the book has
            // no front/back-matter chapters (call doesn't fire).
            return CloudModel.sonnet5_5.pricing.cost(for: Usage(
                inputTokens: 23_400, outputTokens: 390
            ))
        }
    }

    public enum Feature: Sendable, Equatable {
        case hardRegionOCR
        case postOCRCleanupPassages
        case postOCRCleanupVision
        case tableExtraction
        case pageOCR
        /// Gemini 2.5 Flash page-OCR. ~7-10× cheaper per page than
        /// `.pageOCR` (Sonnet 5.5); same XHTML output schema.
        case pageOCRGemini
        /// Gemini 3 Flash preview page-OCR. Pricier than 2.5 Flash
        /// but with stronger reasoning; thinking pinned to minimal
        /// so output token count stays comparable.
        case pageOCRGemini3Preview
        /// Gemini 3.5 Flash page-OCR. Stable model (May 2026); 3×
        /// the per-token cost of 3 Flash Preview but ~50% cheaper
        /// than Sonnet. Thinking pinned to minimal so output token
        /// count stays bounded for pure transcription.
        case pageOCRGemini35
        /// Cloud Vision DOCUMENT_TEXT_DETECTION — cascade Stage 2.5.
        /// Fixed $0.0015 per call regardless of region size.
        case googleDocumentOCR
        /// LandingAI ADE parse (DPT-3 Pro) on a cropped region —
        /// cascade Stage 2.5 alternative and optional table extractor.
        /// ~$0.013 per call; the charge scales with output length.
        case landingAIDocumentOCR
        /// LandingAI ADE parse (DPT-3 Pro) as the whole-page OCR
        /// provider. ~$0.025 per typical page.
        case landingAIPageOCR
        /// P-Sonnet-Structure (chapter pass). One Sonnet call per
        /// book validating the splitter's chapter list.
        case chapterStructurePass
        /// P-Sonnet-Structure (missed-break pass). One Sonnet call
        /// per book reading the full document to find missed
        /// chapter breaks.
        case chapterMissedBreakDetection
        /// P-Sonnet-Structure (bundled front/back-matter pass). One
        /// Sonnet call per book scanning chapters identified as
        /// front-matter / back-matter for bundling.
        case frontBackMatterSplitting
    }

    /// Compute a coarse pre-flight cost estimate. When
    /// `useWholePageOCR` is set, the cascade-based per-region
    /// estimate is replaced with a single per-page Sonnet line item
    /// — the Phase 2 path makes one call per page instead of
    /// selectively escalating regions, so per-region rates don't
    /// apply.
    public static func estimate(
        profile: DocumentProfile,
        cloudFeatures: AISettings.CloudFeatures,
        perBookCallCap: Int,
        useWholePageOCR: Bool = false,
        pageOCRProvider: PageOCRProvider = .claude
    ) -> Estimate {
        guard profile.pageCount > 0 else { return .empty }
        let regions = Double(profile.pageCount) * regionsPerPageEstimate

        var lines: [Estimate.Line] = []
        var totalCalls = 0
        var totalCost: Double = 0

        // Page-OCR mode: one call per page; replaces the
        // hard-region-OCR + post-OCR-cleanup line items entirely.
        // Provider pick changes both per-call cost and the label.
        if useWholePageOCR {
            let calls = profile.pageCount
            let feature: Feature
            let label: String
            let modelId: String
            switch pageOCRProvider {
            case .claude:
                feature = .pageOCR
                label = "Page OCR (whole-page Sonnet)"
                modelId = CloudModel.sonnet5_5.rawValue
            case .gemini25Flash:
                feature = .pageOCRGemini
                label = "Page OCR (Gemini 2.5 Flash)"
                modelId = CloudModel.gemini25Flash.rawValue
            case .gemini3FlashPreview:
                feature = .pageOCRGemini3Preview
                label = "Page OCR (Gemini 3 Flash preview)"
                modelId = CloudModel.gemini3FlashPreview.rawValue
            case .gemini35Flash:
                feature = .pageOCRGemini35
                label = "Page OCR (Gemini 3.5 Flash)"
                modelId = CloudModel.gemini35Flash.rawValue
            case .landingAI:
                // LandingAI DPT-3 Pro bills per page plus output
                // characters, so a whole page costs more than a
                // cropped region — its own Feature.
                feature = .landingAIPageOCR
                label = "Page OCR (LandingAI DPT-3 Pro)"
                modelId = CloudModel.landingAIDPT3Pro.rawValue
            }
            let cost = Double(calls) * costPerCall(feature)
            lines.append(.init(
                label: label, model: modelId,
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
                        model: CloudModel.sonnet5_5.rawValue,
                        calls: tableCalls, costUSD: tableCost
                    ))
                    totalCalls += tableCalls
                    totalCost += tableCost
                }
            }

            // Chapter structure refinement — also independent of
            // OCR mode; one Sonnet call validating the splitter's
            // chapter list.
            if cloudFeatures.chapterStructurePass {
                let cost = costPerCall(.chapterStructurePass)
                lines.append(.init(
                    label: "Chapter structure (Sonnet)",
                    model: CloudModel.sonnet5_5.rawValue,
                    calls: 1, costUSD: cost
                ))
                totalCalls += 1
                totalCost += cost
            }
            if cloudFeatures.chapterMissedBreakDetection {
                let cost = costPerCall(.chapterMissedBreakDetection)
                lines.append(.init(
                    label: "Missed chapter breaks (Sonnet, full text)",
                    model: CloudModel.sonnet5_5.rawValue,
                    calls: 1, costUSD: cost
                ))
                totalCalls += 1
                totalCost += cost
            }
            if cloudFeatures.frontBackMatterSplitting {
                let cost = costPerCall(.frontBackMatterSplitting)
                lines.append(.init(
                    label: "Front/back-matter splitting (Sonnet)",
                    model: CloudModel.sonnet5_5.rawValue,
                    calls: 1, costUSD: cost
                ))
                totalCalls += 1
                totalCost += cost
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
                    model: CloudModel.sonnet5_5.rawValue,
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
                    model: CloudModel.haiku5_5.rawValue,
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
                    model: CloudModel.sonnet5_5.rawValue,
                    calls: calls, costUSD: cost
                ))
                totalCalls += calls
                totalCost += cost
            }
        }

        // Chapter structure refinement (Sonnet). One call per book.
        if cloudFeatures.chapterStructurePass {
            let cost = costPerCall(.chapterStructurePass)
            lines.append(.init(
                label: "Chapter structure (Sonnet)",
                model: CloudModel.sonnet5_5.rawValue,
                calls: 1, costUSD: cost
            ))
            totalCalls += 1
            totalCost += cost
        }
        // Missed-break detection (Sonnet, full text). One call per book.
        if cloudFeatures.chapterMissedBreakDetection {
            let cost = costPerCall(.chapterMissedBreakDetection)
            lines.append(.init(
                label: "Missed chapter breaks (Sonnet, full text)",
                model: CloudModel.sonnet5_5.rawValue,
                calls: 1, costUSD: cost
            ))
            totalCalls += 1
            totalCost += cost
        }
        // Front/back-matter splitting (Sonnet). One call per book
        // when the book has any front/back-matter chapters; floors
        // at zero otherwise (the call never fires).
        if cloudFeatures.frontBackMatterSplitting {
            let cost = costPerCall(.frontBackMatterSplitting)
            lines.append(.init(
                label: "Front/back-matter splitting (Sonnet)",
                model: CloudModel.sonnet5_5.rawValue,
                calls: 1, costUSD: cost
            ))
            totalCalls += 1
            totalCost += cost
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
