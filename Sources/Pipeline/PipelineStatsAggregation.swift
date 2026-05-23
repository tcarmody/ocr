import Foundation
import AI
import Document
import OCR
import PDFIngest

// MARK: - C-Pipeline-File-Split Stage 2 (stats aggregation)
//
// Extracted from `PDFToEPUBPipeline.swift` 2026-05-18. Walks the
// per-page accumulators (observations-by-source, trust/reocr
// verdicts, local-fallback engine usage, page-OCR status buckets)
// at the end of `convert(...)` and packs them into a
// `ConversionStats` value. Behavior-equivalent to the prior inline
// shape; lifted out so the convert orchestrator stays focused on
// the dispatch logic.
extension PDFToEPUBPipeline {

    func aggregateConversionStats(
        pageResults: [PageObservations],
        verdictsByPage: [Int: EmbeddedTextQualityScorer.Verdict],
        pageOCRPendingByIndex: [Int: PendingPageOCR],
        claudeBudget: CloudCallBudget,
        conversionStart: Date
    ) async -> ConversionStats {
        // Tally observations by source across every page. This walks
        // the post-cascade pageResults (i.e. the observations the
        // EPUB was actually built from), so a `.claude`-source
        // observation reflects work Claude did that survived the
        // guardrail check, not just calls attempted.
        var bySource: [ObservationSource: Int] = [:]
        for page in pageResults {
            for obs in page.observations {
                bySource[obs.source, default: 0] += 1
            }
        }
        // Pull final budget snapshot. Per-model usage is recorded by
        // every Claude-backed engine (today: ClaudeOCREngine; future
        // table + Haiku features will accumulate here too).
        let claudeCallCount = await claudeBudget.consumed
        let claudeUsage = await claudeBudget.modelUsage
        let trusted = verdictsByPage.values.filter { $0 == .trust }.count
        let reocrd = verdictsByPage.values.filter { $0 == .reocr }.count
        // Q-Refused-Fallback-Surface (2026-05-12): count pages
        // where the Claude page-OCR path declined or errored and
        // the pipeline fell back to a local engine. Per-engine
        // since 2026-05-17 — Greek/Latin/Arabic/Hebrew/CJK/Cyrillic
        // books route their fallbacks through Tesseract instead
        // of Vision, and the summary reflects which engine ran.
        let visionFallback = pageOCRPendingByIndex.values.filter {
            $0.usedLocalFallback && $0.localFallbackEngineId == "vision"
        }.count
        let tesseractFallback = pageOCRPendingByIndex.values.filter {
            $0.usedLocalFallback && $0.localFallbackEngineId == "tesseract"
        }.count
        // Q-Refusal-Rate (2026-05-14): split the fallback bucket by
        // cause so the user can see refusal rate (the headline) vs
        // empty responses vs API errors. Page-OCR only; cascade
        // refusals aren't tracked yet.
        var refused = 0
        var emptyResp = 0
        var apiError = 0
        var rateLimited = 0
        var refusedIndices: [Int] = []
        var providerId = ""
        for (_, pending) in pageOCRPendingByIndex {
            if providerId.isEmpty, !pending.providerId.isEmpty {
                providerId = pending.providerId
            }
            switch pending.pageOCRStatus {
            case .refused:
                refused += 1
                refusedIndices.append(pending.pageIndex)
            case .empty:           emptyResp += 1
            case .apiError:        apiError += 1
            case .rateLimited:     rateLimited += 1
            case .succeeded, .skippedTrustRouted,
                 .budgetExhausted, .canceled:
                break
            }
        }
        refusedIndices.sort()
        // Cap at 200 indices in the persisted stats — the debug-log
        // dump carries the full set when the user needs it.
        let refusedIndicesCapped = Array(refusedIndices.prefix(200))
        return ConversionStats.make(
            elapsed: Date().timeIntervalSince(conversionStart),
            observationsBySource: bySource,
            pagesTrustedEmbeddedText: trusted,
            pagesReOCRd: reocrd,
            pagesUsingVisionFallback: visionFallback,
            pagesUsingTesseractFallback: tesseractFallback,
            pagesRefused: refused,
            pagesEmpty: emptyResp,
            pagesAPIError: apiError,
            pagesRateLimited: rateLimited,
            refusedPageIndices: refusedIndicesCapped,
            pageOCRProviderId: providerId,
            claudeCallCount: claudeCallCount,
            claudeUsageByModel: claudeUsage
        )
    }
}
