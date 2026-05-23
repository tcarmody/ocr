import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import EPUB
import Layout
import OCR
import PDFIngest

// MARK: - C-Pipeline-File-Split Stage 2 (page-OCR dispatch)
//
// Extracted from `PDFToEPUBPipeline.swift` 2026-05-18. Holds the
// Cloud page-OCR path: per-page Sonnet/Gemini dispatch (sync
// TaskGroup + Anthropic Messages Batches API), the
// `PendingPageOCR` outcome bundle, the page-OCR-side debug
// dump for `claude-pages.txt`, and the related batch-id helpers.
// Behavior-equivalent to the prior inline shape.
extension PDFToEPUBPipeline {

    struct PendingPageOCR: Sendable {
        let pageIndex: Int
        let anchorId: String
        let pageBoundsCG: CGSize
        let blocks: [Block]
        let footnotes: [Footnote]
        let figures: [FigureExtractor.ExtractedFigure]
        let verdict: EmbeddedTextQualityScorer.Verdict
        let qualityScore: EmbeddedTextQualityScorer.Score?
        let extractorDiagnostics: EmbeddedTextExtractor.Diagnostics?

        init(
            pageIndex: Int,
            anchorId: String,
            pageBoundsCG: CGSize,
            blocks: [Block],
            footnotes: [Footnote],
            figures: [FigureExtractor.ExtractedFigure],
            verdict: EmbeddedTextQualityScorer.Verdict,
            qualityScore: EmbeddedTextQualityScorer.Score?,
            extractorDiagnostics: EmbeddedTextExtractor.Diagnostics?,
            pageOCRStatus: ProviderStatus,
            providerId: String,
            usedLocalFallback: Bool,
            localFallbackEngineId: String = ""
        ) {
            self.pageIndex = pageIndex
            self.anchorId = anchorId
            self.pageBoundsCG = pageBoundsCG
            self.blocks = blocks
            self.footnotes = footnotes
            self.figures = figures
            self.verdict = verdict
            self.qualityScore = qualityScore
            self.extractorDiagnostics = extractorDiagnostics
            self.pageOCRStatus = pageOCRStatus
            self.providerId = providerId
            self.usedLocalFallback = usedLocalFallback
            self.localFallbackEngineId = localFallbackEngineId
        }
        /// What the page-OCR provider did. `.succeeded` means blocks
        /// came from the provider directly; `.refused` / `.empty` /
        /// `.apiError` mean the provider failed and (possibly)
        /// Vision filled in (`usedLocalFallback`).
        let pageOCRStatus: ProviderStatus
        /// Which provider was invoked. Empty for trust-routed pages
        /// (no provider call). "claude" / "gemini-2.5-flash" etc.
        let providerId: String
        /// True when the provider failed for this page and the local
        /// OCR fallback produced blocks instead. Surfaced in the
        /// debug log so the user can see which pages didn't get the
        /// full provider treatment (typical causes: refusal,
        /// content-filter false positives, transient API overload).
        let usedLocalFallback: Bool
        /// Which local engine handled the fallback. Empty when no
        /// fallback fired; "vision" or "tesseract" otherwise — the
        /// stats aggregation buckets per-engine so a Greek/Latin/
        /// Arabic/Hebrew book's Tesseract fallbacks don't show up
        /// labeled as Vision in the post-conversion summary.
        let localFallbackEngineId: String

        /// Convenience: page-OCR call returned usable content.
        var sonnetSucceeded: Bool { pageOCRStatus == .succeeded }
    }

    /// Process one page through the page-OCR (Sonnet) path. Handles
    /// E-Routing trust-check, render, parallel Surya layout, the
    /// Sonnet call, and figure extraction. Returns a `PendingPageOCR`
    /// the caller appends to a per-conversion dict; the document-
    /// ordered assembly happens after all pages complete.
    ///
    /// Throws only on cancellation; Sonnet failures (refusal,
    /// network, parse) are absorbed and surface via
    /// `sonnetSucceeded == false` on the returned value.
    /// `nonisolated` so the page-OCR TaskGroup in `convert` can dispatch
    /// it from `addTask` without tripping Swift 6's "sending closure
    /// from self-isolated context" check. The body only reads the
    /// pipeline's `let` engine properties and `await`s other actor-
    /// isolated methods explicitly — no actor state is mutated.
    nonisolated func runPageOCRPage(
        pageIndex i: Int,
        pdf: LoadedPDF,
        options: Options,
        stagingDir: URL,
        pageEngine: any PageOCREngine,
        figureExtractor: FigureExtractor
    ) async throws -> PendingPageOCR {
        try Task.checkCancellation()
        let anchorId = RegionAwareReflow.anchorId(forPageIndex: i)

        // E-Routing: trust-verdict pages skip Sonnet.
        var routingScore: EmbeddedTextQualityScorer.Score?
        var routingDiagnostics: EmbeddedTextExtractor.Diagnostics?
        if options.cloudFeatures.adaptivePageRouting
           && !options.shouldForceOCR(forPageIndex: i) {
            let extracted = autoreleasepool {
                embeddedExtractor.extract(from: pdf, pageIndex: i)
            }
            let combined = extracted.lines
                .map(\.text).joined(separator: " ")
            let score = qualityScorer.score(
                text: combined,
                expectedLanguages: options.languages.map(\.rawValue)
            )
            routingScore = score
            routingDiagnostics = extracted.diagnostics

            if score.verdict == .trust {
                let observations = extracted.lines.map { line in
                    TextObservation(
                        text: line.text, confidence: 0.95,
                        box: line.box, source: .embedded
                    )
                }
                let trustBlocks = ParagraphReflow().reflow(observations)
                let bounds: CGSize = autoreleasepool {
                    if let pdfPage = pdf.document.page(at: i) {
                        let r = pdfPage.bounds(for: .mediaBox)
                        return CGSize(width: r.width, height: r.height)
                    }
                    return .zero
                }
                return PendingPageOCR(
                    pageIndex: i,
                    anchorId: anchorId,
                    pageBoundsCG: bounds,
                    blocks: trustBlocks,
                    footnotes: [],
                    figures: [],
                    verdict: .trust,
                    qualityScore: score,
                    extractorDiagnostics: extracted.diagnostics,
                    pageOCRStatus: .skippedTrustRouted,
                    providerId: pageEngine.providerId,
                    usedLocalFallback: false
                )
            }
            // Verdict was .reocr; fall through to Sonnet but
            // remember the score + diagnostics so the assembly
            // pass logs them.
        }

        // Sonnet path.
        let renderer = PDFRenderer(dpi: options.dpi)
        let image = try renderer.renderPage(at: i, of: pdf)
        let pageBoundsCG = CGSize(
            width: image.width, height: image.height
        )
        let pngURL = stagingDir.appendingPathComponent(
            String(format: "page-%05d.png", i)
        )
        Self.savePNG(image, to: pngURL)

        // Surya layout in parallel with the Sonnet call.
        let layoutTask = Task<[LayoutRegion]?, Never> {
            let outcome = await self.analyzeLayoutWithRetry(
                pdf: pdf,
                pageIndex: i,
                initialDPI: options.dpi,
                initialPNGURL: pngURL,
                initialPageBounds: pageBoundsCG,
                stagingDir: stagingDir
            )
            return outcome.layout
        }

        var sonnetBlocks: [Block] = []
        var sonnetFootnotes: [Footnote] = []
        var pageOCRStatus: ProviderStatus = .empty
        var usedLocalFallback = false
        var localFallbackEngineId = ""
        do {
            let result = try await pageEngine.recognize(
                pageImage: image, pageIndex: i,
                languages: options.languages
            )
            sonnetBlocks = result.blocks
            sonnetFootnotes = result.footnotes
            pageOCRStatus = .succeeded
        } catch is CancellationError {
            // Cancel the layout task too before propagating.
            layoutTask.cancel()
            throw CancellationError()
        } catch {
            // Provider failed for this page — refusal, content-filter
            // false positive, transient network/overload error, etc.
            // Classify the error so the refusal-rate stat can bucket
            // it, then fall back to local OCR so the page contributes
            // *something* to the EPUB instead of going blank.
            // Tesseract beats Vision for the language set in
            // `shouldPreferTesseract` (polytonic Greek, classical
            // Latin, vocalized Hebrew, Arabic with diacritics, CJK,
            // Cyrillic, Syriac / Coptic / OCS) — route there when
            // applicable instead of always going to Vision. The user
            // can still Re-OCR a single page from the editor to
            // retry the provider later.
            pageOCRStatus = pageEngine.classify(error: error)
            let hints = OCRHints(
                languages: options.languages,
                quality: options.ocrQuality
            )
            if let (fallbackEngine, fallbackId) =
                selectLocalFallbackEngine(for: options.languages) {
                do {
                    let result = try await fallbackEngine.recognize(
                        image: image, hints: hints
                    )
                    let blocks = ParagraphReflow().reflow(
                        result.observations
                    )
                    if !blocks.isEmpty {
                        sonnetBlocks = blocks
                        usedLocalFallback = true
                        localFallbackEngineId = fallbackId
                    }
                } catch {
                    // Local fallback also failed — leave the page
                    // empty. The claude-pages.txt dump still records
                    // the original provider error so the user can
                    // diagnose.
                }
            }
        }

        let layoutRegions = await layoutTask.value
        var figures: [FigureExtractor.ExtractedFigure] = []
        if let regions = layoutRegions, !regions.isEmpty {
            figures = figureExtractor.extract(
                pageIndex: i, regions: regions, pageImage: image
            )
        }
        // Fallback figures when Surya didn't provide a layout.
        // Page-OCR mode has no text observations from a Vision
        // pass (we bypass the cascade), so we deliberately pass
        // empty — the fallback then skips Vision saliency (its
        // false-positive rate is too high without anchors) and
        // returns just PDFKit-XObject figures for born-digital
        // pages. Scanned books in page-OCR mode without Surya
        // get no fallback figures, only the cover image.
        let fallbackFigures = await extractFallbackFigures(
            pdf: pdf, pageIndex: i,
            pageImage: image,
            textObservations: [],
            layoutAvailable: layoutRegions != nil
        )
        figures.append(contentsOf: fallbackFigures)

        return PendingPageOCR(
            pageIndex: i,
            anchorId: anchorId,
            pageBoundsCG: pageBoundsCG,
            blocks: sonnetBlocks,
            footnotes: sonnetFootnotes,
            figures: figures,
            verdict: .reocr,
            qualityScore: routingScore,
            extractorDiagnostics: routingDiagnostics,
            pageOCRStatus: pageOCRStatus,
            providerId: pageEngine.providerId,
            usedLocalFallback: usedLocalFallback,
            localFallbackEngineId: localFallbackEngineId
        )
    }

    /// Tier 9 / E-Batches step 2 internal: per-page prep result
    /// from `preparePageForBatch`. `request == nil` means the page
    /// was trust-routed and `partial` is fully populated; otherwise
    /// `partial` has empty blocks/footnotes that the batch result
    /// fills in.
    struct BatchPrepared: Sendable {
        let pageIndex: Int
        let partial: PendingPageOCR
        let request: AnthropicMessageRequest?
    }

    /// Tier 9 / E-Batches step 2. Dispatch the page-OCR Sonnet
    /// calls as a single Anthropic Batches API request. Each
    /// fresh page goes through:
    ///   * **Phase A** (parallel TaskGroup) — render, save PNG,
    ///     run Surya layout + figure extraction, build the
    ///     Sonnet request. Trust-routed pages emit reflowed
    ///     embedded text directly here, skipping the batch.
    ///   * **Phase B** (single batch round-trip) — submit all
    ///     non-trust pages' requests as one batch, wait for
    ///     completion, fetch the JSONL result stream.
    ///   * **Phase C** (sequential) — walk results by custom_id
    ///     ("page-NNN"), parse each into blocks + footnotes,
    ///     fill in the corresponding `PendingPageOCR` slot.
    ///
    /// Trades wall time (Anthropic documents most batches under
    /// an hour, hard cap 24 h) for a 50% input + output token
    /// discount on the Sonnet calls. Figure extraction happens
    /// in Phase A so the page images don't need to stay alive
    /// across the batch wait.
    ///
    /// Falls back silently to the synchronous TaskGroup path on
    /// batch submission / poll / fetch failure — the caller
    /// observes empty `pendingByIndex` entries for affected
    /// pages and the assembly emits empty pages, same as
    /// per-page Sonnet failures.
    func dispatchPageOCRViaBatch(
        freshIndices: [Int],
        pdf: LoadedPDF,
        options: Options,
        stagingDir: URL,
        pageEngine: ClaudePageOCREngine,
        figureExtractor: FigureExtractor,
        apiKey: String,
        progress: ProgressHandler?,
        totalPages: Int,
        debugLogURL: URL?,
        pendingByIndex: inout [Int: PendingPageOCR]
    ) async throws {
        // Mirror of the Gemini dispatcher's logger. Nil URL =
        // no-op so the diagnostic path costs nothing when the
        // caller doesn't request it.
        func dispatchLog(_ message: String) {
            guard let url = debugLogURL else { return }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] [dispatch] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
        dispatchLog("dispatch begin — freshIndices=\(freshIndices.count) totalPages=\(totalPages)")
        // Phase A: per-page prep. Trust-routed pages emit final
        // PendingPageOCR; Sonnet pages emit a partial pending +
        // a request-builder. Run in parallel since prep is I/O-
        // and-CPU bound (render + Surya + base64 encode).
        let concurrency = max(
            1, options.cloudFeatures.parallelPageOCRConcurrency
        )
        // Progress baseline: any pages already in `pendingByIndex`
        // were restored from checkpoints by the for-loop in
        // `convert(...)` (resume path) — count them so this dispatch's
        // emits don't backtrack the queue UI.
        let baselineCount = pendingByIndex.count
        var prepared: [Int: BatchPrepared] = [:]
        var preppedCount = 0
        try await withThrowingTaskGroup(of: BatchPrepared.self) { group in
            var nextSubmit = 0
            var inflight = 0
            while nextSubmit < freshIndices.count || inflight > 0 {
                while inflight < concurrency
                    && nextSubmit < freshIndices.count {
                    let i = freshIndices[nextSubmit]
                    nextSubmit += 1
                    let perform = self.preparePageForBatch
                    let pdfRef = pdf
                    group.addTask { @Sendable in
                        let tuple = try await perform(
                            i,
                            pdfRef, options,
                            stagingDir,
                            pageEngine,
                            figureExtractor
                        )
                        return BatchPrepared(
                            pageIndex: tuple.pageIndex,
                            partial: tuple.partial,
                            request: tuple.request
                        )
                    }
                    inflight += 1
                }
                if let p = try await group.next() {
                    inflight -= 1
                    prepared[p.pageIndex] = p
                    // Per-page heartbeat so the queue UI shows
                    // forward motion during prep (render + Surya
                    // layout). Without this, the row sits at the
                    // for-loop's initial "0/N" emit until Phase C
                    // results come back minutes later — when the
                    // batch submit + poll is in flight, that gap
                    // is long enough to look like a hang.
                    preppedCount += 1
                    progress?(Progress(
                        totalPages: totalPages,
                        completedPages: baselineCount + preppedCount,
                        currentPageMeanConfidence: 1.0
                    ))
                }
            }
        }

        // Trust-routed pages are already fully populated;
        // settle them now so the assembly walk doesn't see them
        // as fresh-but-missing.
        let trustCount = prepared.values.filter { $0.request == nil }.count
        for (i, p) in prepared where p.request == nil {
            pendingByIndex[i] = p.partial
        }
        dispatchLog("Phase A complete — preppedCount=\(preppedCount) trustRouted=\(trustCount)")

        // Phase B: build + submit batch from Sonnet pages.
        let sonnetEntries = freshIndices.compactMap { i -> (Int, AnthropicMessageRequest)? in
            guard let p = prepared[i], let req = p.request else { return nil }
            return (i, req)
        }
        guard !sonnetEntries.isEmpty else {
            dispatchLog("no Sonnet-bound entries — all pages trust-routed; returning")
            return
        }
        dispatchLog("sonnetEntries to batch: \(sonnetEntries.count)")

        // Reserve budget upfront — one call per page in the batch.
        // If the cap can't accommodate the full batch, fall back
        // and let the caller's per-page synchronous path handle
        // it (we'll just leave those pages with empty pending
        // entries; the existing `sonnetSucceeded == false`
        // posture covers downstream).
        let budget = pageEngine.budget
        for _ in sonnetEntries {
            guard await budget.tryConsume() else {
                // Budget exhausted mid-reservation. Treat all
                // remaining as "couldn't dispatch"; their
                // partials become final (empty blocks). We could
                // alternatively shrink the batch to whatever fit;
                // simpler is to bail and let the user know via
                // the cap-clamping cost estimate.
                dispatchLog("budget exhausted mid-reservation — settling partials as final")
                for (i, _) in sonnetEntries {
                    if pendingByIndex[i] == nil,
                       let p = prepared[i] {
                        pendingByIndex[i] = p.partial
                    }
                }
                return
            }
        }

        let batchRequests = sonnetEntries.map { (i, req) in
            AnthropicBatchSubmitRequest.Request(
                customId: String(format: "page-%05d", i),
                params: req
            )
        }
        let batchClient = AnthropicBatchAPIClient(
            apiKeyProvider: { apiKey },
            debugLogURL: debugLogURL
        )
        let submitted: AnthropicBatchSubmitResponse
        do {
            submitted = try await batchClient.submit(
                AnthropicBatchSubmitRequest(requests: batchRequests)
            )
        } catch {
            // Batch submission failed entirely. Settle every
            // Sonnet page's partial as the final pending so the
            // assembly emits empty pages (anchor + figures only).
            dispatchLog("submit threw: \(error) — settling partials")
            for (i, _) in sonnetEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            return
        }

        // Tell the queue UI we've entered the poll-wait window so
        // it can swap the linear bar for an indeterminate spinner
        // + a "Waiting for batch · usually <1 h" label. We re-emit
        // the same page counts so the visible position doesn't
        // jump; only `phase` changes.
        progress?(Progress(
            totalPages: totalPages,
            completedPages: baselineCount + preppedCount,
            currentPageMeanConfidence: 1.0,
            phase: .batchWaiting
        ))

        // Phase B continued: poll until done.
        let final: AnthropicBatchStatusResponse
        do {
            final = try await batchClient.awaitCompletion(
                batchId: submitted.id
            )
        } catch {
            dispatchLog("awaitCompletion threw: \(error) — settling partials")
            for (i, _) in sonnetEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            return
        }
        guard let resultsURL = final.resultsUrl else {
            dispatchLog("terminal status without results_url — settling partials as empty")
            for (i, _) in sonnetEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            return
        }
        dispatchLog("succeeded — fetching results from \(resultsURL)")
        let results: [AnthropicBatchResultLine]
        do {
            results = try await batchClient.fetchResults(from: resultsURL)
        } catch {
            dispatchLog("fetchResults threw: \(error) — settling partials")
            for (i, _) in sonnetEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            return
        }

        // Phase C: walk results, parse each, fill in the
        // matching pending slot. Result order is unspecified;
        // we look up by custom_id.
        var matchedCount = 0
        var unmatchedKeyCount = 0
        var unknownPageCount = 0
        var statusHistogram: [ProviderStatus: Int] = [:]
        var nonSuccessPages: [(Int, ProviderStatus, String?)] = []
        for line in results {
            guard let pageIndex = Self.pageIndexFromCustomId(line.customId) else {
                unmatchedKeyCount += 1
                continue
            }
            guard let prep = prepared[pageIndex] else {
                unknownPageCount += 1
                continue
            }
            matchedCount += 1
            let parsedBlocks: [Block]
            let parsedFootnotes: [Footnote]
            let status: ProviderStatus
            var failureDetail: String? = nil
            switch line.result {
            case .succeeded(let msg):
                await pageEngine.recordBatchUsage(msg.usage)
                let outcome = pageEngine.parseBatchMessageOutcome(
                    msg, pageIndex: pageIndex
                )
                if let parsed = outcome.result {
                    parsedBlocks = parsed.blocks
                    parsedFootnotes = parsed.footnotes
                    status = .succeeded
                } else {
                    parsedBlocks = []
                    parsedFootnotes = []
                    status = outcome.status
                }
            case .refused(let msg):
                await pageEngine.recordBatchUsage(msg.usage)
                parsedBlocks = []
                parsedFootnotes = []
                status = .refused
            case .errored(let message):
                parsedBlocks = []
                parsedFootnotes = []
                status = .apiError
                failureDetail = message
            case .canceled:
                parsedBlocks = []
                parsedFootnotes = []
                status = .apiError
                failureDetail = "canceled"
            case .expired:
                parsedBlocks = []
                parsedFootnotes = []
                status = .apiError
                failureDetail = "expired"
            }
            statusHistogram[status, default: 0] += 1
            if status != .succeeded || parsedBlocks.isEmpty {
                nonSuccessPages.append((pageIndex, status, failureDetail))
            }
            // Re-emit a final PendingPageOCR with Sonnet content
            // merged in. Preserves the partial's anchor / bounds /
            // figures / verdict / quality / diagnostics.
            // `usedLocalFallback` stays false here; the
            // Q-Vision-Backfill-Batch pass below upgrades it for
            // pages that took the Vision fallback path.
            let final = PendingPageOCR(
                pageIndex: prep.partial.pageIndex,
                anchorId: prep.partial.anchorId,
                pageBoundsCG: prep.partial.pageBoundsCG,
                blocks: parsedBlocks,
                footnotes: parsedFootnotes,
                figures: prep.partial.figures,
                verdict: prep.partial.verdict,
                qualityScore: prep.partial.qualityScore,
                extractorDiagnostics: prep.partial.extractorDiagnostics,
                pageOCRStatus: status,
                providerId: pageEngine.providerId,
                usedLocalFallback: false
            )
            pendingByIndex[pageIndex] = final
            // Clamp upward against the Phase A high-water mark so
            // the queue UI never appears to regress between phases.
            // pendingByIndex.count starts at `baselineCount +
            // trustCount` (after the trust settlement above) and
            // climbs to totalPages as Sonnet results land; max'ing
            // with `prepHighWater` keeps the bar at the prep mark
            // until results actually overtake it.
            let prepHighWater = baselineCount + preppedCount
            progress?(Progress(
                totalPages: totalPages,
                completedPages: max(prepHighWater, pendingByIndex.count),
                currentPageMeanConfidence: 1.0
            ))
        }

        // Any Sonnet pages whose result didn't show up in the
        // JSONL (corrupt line, unknown custom_id) get their
        // partial as final so the page emits empty.
        var orphanedPageCount = 0
        var orphanedPages: [Int] = []
        for (i, _) in sonnetEntries where pendingByIndex[i] == nil {
            if let p = prepared[i] {
                pendingByIndex[i] = p.partial
                orphanedPageCount += 1
                orphanedPages.append(i)
            }
        }
        let histogramSummary = statusHistogram
            .sorted(by: { $0.value > $1.value })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        dispatchLog("Phase C summary: results=\(results.count) matched=\(matchedCount) unmatchedKey=\(unmatchedKeyCount) unknownPage=\(unknownPageCount) orphanedPages=\(orphanedPageCount) statusHistogram={\(histogramSummary)}")
        if !nonSuccessPages.isEmpty {
            dispatchLog("non-success pages (pageIdx,status,detail):")
            for (idx, status, detail) in nonSuccessPages.sorted(by: { $0.0 < $1.0 }) {
                dispatchLog("  page=\(idx) status=\(status) detail=\(detail ?? "")")
            }
        }
        if !orphanedPages.isEmpty {
            dispatchLog("orphaned pages (no result line returned): \(orphanedPages.sorted())")
        }

        // Q-Vision-Backfill-Batch: pages whose batch result didn't
        // produce usable blocks (refused, errored, canceled,
        // expired, or empty parse) get a local Vision / Tesseract
        // OCR pass so they contribute *something* to the EPUB
        // instead of going blank. Shared with the Gemini batch
        // dispatcher via `applyVisionBackfillForBatch`.
        var partialsByIndex: [Int: PendingPageOCR] = [:]
        for (idx, prep) in prepared { partialsByIndex[idx] = prep.partial }
        try await applyVisionBackfillForBatch(
            pageIndices: sonnetEntries.map(\.0),
            partialsByIndex: partialsByIndex,
            pdf: pdf,
            options: options,
            providerId: pageEngine.providerId,
            debugLogURL: debugLogURL,
            pendingByIndex: &pendingByIndex
        )
        dispatchLog("dispatch end")
    }

    /// Helper for `dispatchPageOCRViaBatch`. Does Phase A for
    /// one page: trust check (returns final pending if trust),
    /// else render + Surya layout + figure extraction + build
    /// Sonnet request (returns partial pending + request).
    /// `nonisolated` for the same reason as `runPageOCRPage` — called
    /// from a TaskGroup in the batch-API dispatch path; needs to be
    /// safely sendable as a closure.
    nonisolated func preparePageForBatch(
        pageIndex i: Int,
        pdf: LoadedPDF,
        options: Options,
        stagingDir: URL,
        pageEngine: ClaudePageOCREngine,
        figureExtractor: FigureExtractor
    ) async throws -> (pageIndex: Int, partial: PendingPageOCR, request: AnthropicMessageRequest?) {
        try Task.checkCancellation()
        let anchorId = RegionAwareReflow.anchorId(forPageIndex: i)

        var routingScore: EmbeddedTextQualityScorer.Score?
        var routingDiagnostics: EmbeddedTextExtractor.Diagnostics?
        if options.cloudFeatures.adaptivePageRouting
           && !options.shouldForceOCR(forPageIndex: i) {
            let extracted = autoreleasepool {
                embeddedExtractor.extract(from: pdf, pageIndex: i)
            }
            let combined = extracted.lines
                .map(\.text).joined(separator: " ")
            let score = qualityScorer.score(
                text: combined,
                expectedLanguages: options.languages.map(\.rawValue)
            )
            routingScore = score
            routingDiagnostics = extracted.diagnostics
            if score.verdict == .trust {
                let observations = extracted.lines.map { line in
                    TextObservation(
                        text: line.text, confidence: 0.95,
                        box: line.box, source: .embedded
                    )
                }
                let trustBlocks = ParagraphReflow().reflow(observations)
                let bounds: CGSize = autoreleasepool {
                    if let pdfPage = pdf.document.page(at: i) {
                        let r = pdfPage.bounds(for: .mediaBox)
                        return CGSize(width: r.width, height: r.height)
                    }
                    return .zero
                }
                let pending = PendingPageOCR(
                    pageIndex: i,
                    anchorId: anchorId,
                    pageBoundsCG: bounds,
                    blocks: trustBlocks,
                    footnotes: [],
                    figures: [],
                    verdict: .trust,
                    qualityScore: score,
                    extractorDiagnostics: extracted.diagnostics,
                    pageOCRStatus: .skippedTrustRouted,
                    providerId: pageEngine.providerId,
                    usedLocalFallback: false
                )
                return (i, pending, nil)
            }
        }

        // Sonnet path: render, save PNG, kick layout, do figure
        // extraction NOW (before batch wait so we don't hold the
        // page image alive across the batch wait), build request.
        let renderer = PDFRenderer(dpi: options.dpi)
        let image = try renderer.renderPage(at: i, of: pdf)
        let pageBoundsCG = CGSize(
            width: image.width, height: image.height
        )
        let pngURL = stagingDir.appendingPathComponent(
            String(format: "page-%05d.png", i)
        )
        Self.savePNG(image, to: pngURL)

        let layoutOutcome = await analyzeLayoutWithRetry(
            pdf: pdf, pageIndex: i,
            initialDPI: options.dpi,
            initialPNGURL: pngURL,
            initialPageBounds: pageBoundsCG,
            stagingDir: stagingDir
        )
        var figures: [FigureExtractor.ExtractedFigure] = []
        if let regions = layoutOutcome.layout, !regions.isEmpty {
            figures = figureExtractor.extract(
                pageIndex: i, regions: regions, pageImage: image
            )
        }
        // PDFKit XObject fallback when Surya isn't installed. Same
        // posture as the sync page-OCR path: skip Vision saliency
        // in page-OCR mode (no text-observation anchor) so only
        // born-digital pages produce fallback figures here.
        let fallbackFigures = await extractFallbackFigures(
            pdf: pdf, pageIndex: i,
            pageImage: image,
            textObservations: [],
            layoutAvailable: layoutOutcome.layout != nil
        )
        figures.append(contentsOf: fallbackFigures)

        let request = pageEngine.buildBatchRequest(
            pageImage: image, languages: options.languages
        )

        // Placeholder status — Phase C overwrites with the real
        // result. `.empty` is the right default for "Sonnet entry
        // built, no response yet"; pages that never get a result
        // surface as empty (their pending stays at this default
        // in `dispatchPageOCRViaBatch`'s "didn't show up" fallthrough).
        let partial = PendingPageOCR(
            pageIndex: i,
            anchorId: anchorId,
            pageBoundsCG: pageBoundsCG,
            blocks: [],
            footnotes: [],
            figures: figures,
            verdict: .reocr,
            qualityScore: routingScore,
            extractorDiagnostics: routingDiagnostics,
            pageOCRStatus: .empty,
            providerId: pageEngine.providerId,
            usedLocalFallback: false
        )
        return (i, partial, request)
    }

    /// `"page-00042"` → `42`. Returns nil if the custom_id
    /// isn't in our format (defensive — we always produce
    /// matching ids on submit).
    static func pageIndexFromCustomId(_ customId: String) -> Int? {
        guard customId.hasPrefix("page-") else { return nil }
        return Int(customId.dropFirst("page-".count))
    }

    // MARK: - Vision-backfill for batch refusals

    /// Q-Vision-Backfill-Batch. Shared between the Anthropic and
    /// Gemini batch dispatchers. After Phase C, any batched page
    /// whose final `PendingPageOCR` carries no blocks AND wasn't
    /// `.succeeded` (refused, empty parts, errored, expired,
    /// canceled, decode-failed) gets a local Vision / Tesseract
    /// OCR pass against the page image. Preserves the original
    /// `pageOCRStatus` so refusal-rate stats stay honest, but
    /// flips `usedLocalFallback = true` and stamps the fallback
    /// engine's id so downstream callers can attribute the body.
    ///
    /// Conditions for skipping:
    ///   * No pages qualify → "all pages already populated" path
    ///   * No local fallback engine available for the requested
    ///     languages (e.g. classical script with no Tesseract
    ///     traineddata installed) → "no fallback engine" path
    ///
    /// `partialsByIndex` lets the dispatcher pass the per-page
    /// `PendingPageOCR` partial the helper needs to preserve
    /// anchorId / pageBoundsCG / figures across the refill,
    /// without coupling to the provider-specific `prepared`
    /// dictionary type (Anthropic's `BatchPrepared` vs Gemini's
    /// `GeminiBatchPrepared`).
    func applyVisionBackfillForBatch(
        pageIndices: [Int],
        partialsByIndex: [Int: PendingPageOCR],
        pdf: LoadedPDF,
        options: Options,
        providerId: String,
        debugLogURL: URL?,
        pendingByIndex: inout [Int: PendingPageOCR]
    ) async throws {
        // Local logger — same shape as the dispatcher's, but
        // prefixed `[vision-backfill]` so the log clearly shows
        // which phase emitted the line.
        func log(_ message: String) {
            guard let url = debugLogURL else { return }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] [vision-backfill] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }

        let needsFallback = pageIndices.filter { i in
            guard let pending = pendingByIndex[i] else { return true }
            return !pending.sonnetSucceeded && pending.blocks.isEmpty
        }
        guard !needsFallback.isEmpty else {
            log("no pages need backfill")
            return
        }
        log("needed for \(needsFallback.count) pages: \(needsFallback)")
        let visionRenderer = PDFRenderer(dpi: options.dpi)
        let hints = OCRHints(
            languages: options.languages,
            quality: options.ocrQuality
        )
        guard let (fallbackEngine, fallbackId) =
            selectLocalFallbackEngine(for: options.languages)
        else {
            log("no local fallback engine available for these languages — leaving pages empty")
            return
        }
        var fallbackSucceeded = 0
        var fallbackFailed = 0
        var fallbackProducedNoBlocks = 0
        for i in needsFallback {
            try Task.checkCancellation()
            guard let partial = partialsByIndex[i] else { continue }
            do {
                let image = try visionRenderer.renderPage(at: i, of: pdf)
                let result = try await fallbackEngine.recognize(
                    image: image, hints: hints
                )
                let blocks = ParagraphReflow().reflow(result.observations)
                guard !blocks.isEmpty else {
                    fallbackProducedNoBlocks += 1
                    continue
                }
                // Preserve the original failure status so refusal-
                // rate stats count this page correctly even though
                // local OCR filled in the body. usedLocalFallback
                // flag tells downstream consumers the body didn't
                // come from the configured page-OCR provider.
                let priorStatus = pendingByIndex[i]?.pageOCRStatus
                    ?? .apiError
                pendingByIndex[i] = PendingPageOCR(
                    pageIndex: partial.pageIndex,
                    anchorId: partial.anchorId,
                    pageBoundsCG: partial.pageBoundsCG,
                    blocks: blocks,
                    footnotes: partial.footnotes,
                    figures: partial.figures,
                    verdict: partial.verdict,
                    qualityScore: partial.qualityScore,
                    extractorDiagnostics: partial.extractorDiagnostics,
                    pageOCRStatus: priorStatus,
                    providerId: providerId,
                    usedLocalFallback: true,
                    localFallbackEngineId: fallbackId
                )
                fallbackSucceeded += 1
            } catch {
                // Local OCR also failed — leave the page empty.
                // Same posture as the sync path's nested catch.
                fallbackFailed += 1
            }
        }
        log("end — succeeded=\(fallbackSucceeded) producedNoBlocks=\(fallbackProducedNoBlocks) failed=\(fallbackFailed) engine=\(fallbackId)")
    }

    // MARK: - Gemini batch dispatch (P-Gemini-Batch)

    /// Internal per-page Gemini Phase A result. Parallel to
    /// `BatchPrepared` but carries a JSONL-line `Data` instead of
    /// an `AnthropicMessageRequest`. `entryLine == nil` means the
    /// page was trust-routed and `partial` is fully populated.
    struct GeminiBatchPrepared: Sendable {
        let pageIndex: Int
        let partial: PendingPageOCR
        let entryLine: Data?
    }

    /// Phase A for one page in the Gemini batch path. Same trust-
    /// routing + render + Surya + figure extraction as
    /// `preparePageForBatch`; the only divergence is the request
    /// build at the end (Gemini batch entry JSON instead of
    /// `AnthropicMessageRequest`).
    nonisolated func prepareGeminiPageForBatch(
        pageIndex i: Int,
        pdf: LoadedPDF,
        options: Options,
        stagingDir: URL,
        pageEngine: GeminiPageOCREngine,
        figureExtractor: FigureExtractor
    ) async throws -> GeminiBatchPrepared {
        try Task.checkCancellation()
        let anchorId = RegionAwareReflow.anchorId(forPageIndex: i)

        var routingScore: EmbeddedTextQualityScorer.Score?
        var routingDiagnostics: EmbeddedTextExtractor.Diagnostics?
        if options.cloudFeatures.adaptivePageRouting
           && !options.shouldForceOCR(forPageIndex: i) {
            let extracted = autoreleasepool {
                embeddedExtractor.extract(from: pdf, pageIndex: i)
            }
            let combined = extracted.lines
                .map(\.text).joined(separator: " ")
            let score = qualityScorer.score(
                text: combined,
                expectedLanguages: options.languages.map(\.rawValue)
            )
            routingScore = score
            routingDiagnostics = extracted.diagnostics
            if score.verdict == .trust {
                let observations = extracted.lines.map { line in
                    TextObservation(
                        text: line.text, confidence: 0.95,
                        box: line.box, source: .embedded
                    )
                }
                let trustBlocks = ParagraphReflow().reflow(observations)
                let bounds: CGSize = autoreleasepool {
                    if let pdfPage = pdf.document.page(at: i) {
                        let r = pdfPage.bounds(for: .mediaBox)
                        return CGSize(width: r.width, height: r.height)
                    }
                    return .zero
                }
                let pending = PendingPageOCR(
                    pageIndex: i,
                    anchorId: anchorId,
                    pageBoundsCG: bounds,
                    blocks: trustBlocks,
                    footnotes: [],
                    figures: [],
                    verdict: .trust,
                    qualityScore: score,
                    extractorDiagnostics: extracted.diagnostics,
                    pageOCRStatus: .skippedTrustRouted,
                    providerId: pageEngine.providerId,
                    usedLocalFallback: false
                )
                return GeminiBatchPrepared(
                    pageIndex: i, partial: pending, entryLine: nil
                )
            }
        }

        // Gemini path: render, save PNG, kick Surya layout, extract
        // figures, build one batch-entry JSON line.
        let renderer = PDFRenderer(dpi: options.dpi)
        let image = try renderer.renderPage(at: i, of: pdf)
        let pageBoundsCG = CGSize(
            width: image.width, height: image.height
        )
        let pngURL = stagingDir.appendingPathComponent(
            String(format: "page-%05d.png", i)
        )
        Self.savePNG(image, to: pngURL)

        let layoutOutcome = await analyzeLayoutWithRetry(
            pdf: pdf, pageIndex: i,
            initialDPI: options.dpi,
            initialPNGURL: pngURL,
            initialPageBounds: pageBoundsCG,
            stagingDir: stagingDir
        )
        var figures: [FigureExtractor.ExtractedFigure] = []
        if let regions = layoutOutcome.layout, !regions.isEmpty {
            figures = figureExtractor.extract(
                pageIndex: i, regions: regions, pageImage: image
            )
        }
        let fallbackFigures = await extractFallbackFigures(
            pdf: pdf, pageIndex: i,
            pageImage: image,
            textObservations: [],
            layoutAvailable: layoutOutcome.layout != nil
        )
        figures.append(contentsOf: fallbackFigures)

        let entryLine = pageEngine.buildBatchEntryData(
            pageImage: image,
            languages: options.languages,
            pageIndex: i
        )

        let partial = PendingPageOCR(
            pageIndex: i,
            anchorId: anchorId,
            pageBoundsCG: pageBoundsCG,
            blocks: [],
            footnotes: [],
            figures: figures,
            verdict: .reocr,
            qualityScore: routingScore,
            extractorDiagnostics: routingDiagnostics,
            pageOCRStatus: .empty,
            providerId: pageEngine.providerId,
            usedLocalFallback: false
        )
        return GeminiBatchPrepared(
            pageIndex: i, partial: partial, entryLine: entryLine
        )
    }

    /// Dispatch the Gemini page-OCR calls as a single Google
    /// Batches API request. Same Phase A/B/C shape as the
    /// Anthropic equivalent; differences live in the middle:
    ///
    ///   * Phase B uploads a JSONL of per-page entries via the
    ///     Files API, submits the batch referencing that file
    ///     (file-based path — image-heavy batches exceed the
    ///     20 MB inline cap), polls until terminal.
    ///   * `JOB_STATE_EXPIRED` / `_FAILED` / `_CANCELLED` are
    ///     handled like an Anthropic batch failure: settle every
    ///     non-trust page's partial as final, surface empty
    ///     pages, let the user re-run.
    ///   * Phase C looks up results by `metadata.key` (same
    ///     `"page-NNNNN"` format as Claude's `custom_id`) and
    ///     parses each response into blocks + footnotes.
    ///
    /// Best-effort cleanup of the uploaded input + downloaded
    /// result files at the end so Google's per-account storage
    /// doesn't accumulate cruft across many conversions.
    func dispatchGeminiPageOCRViaBatch(
        freshIndices: [Int],
        pdf: LoadedPDF,
        options: Options,
        stagingDir: URL,
        pageEngine: GeminiPageOCREngine,
        figureExtractor: FigureExtractor,
        apiKey: String,
        modelId: String,
        progress: ProgressHandler?,
        totalPages: Int,
        debugLogURL: URL?,
        pendingByIndex: inout [Int: PendingPageOCR]
    ) async throws {
        // Inline file-append logger, mirrors the client's `log(_:)`.
        // Nil URL = no-op. Used to mark the dispatch-level phase
        // boundaries (Phase A done, fallthroughs) the client itself
        // can't see.
        func dispatchLog(_ message: String) {
            guard let url = debugLogURL else { return }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] [dispatch] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
        dispatchLog("dispatch begin — freshIndices=\(freshIndices.count) totalPages=\(totalPages) model=\(modelId)")
        // Phase A — same shape as Anthropic dispatch.
        let concurrency = max(
            1, options.cloudFeatures.parallelPageOCRConcurrency
        )
        let baselineCount = pendingByIndex.count
        var prepared: [Int: GeminiBatchPrepared] = [:]
        var preppedCount = 0
        try await withThrowingTaskGroup(of: GeminiBatchPrepared.self) { group in
            var nextSubmit = 0
            var inflight = 0
            while nextSubmit < freshIndices.count || inflight > 0 {
                while inflight < concurrency
                    && nextSubmit < freshIndices.count {
                    let i = freshIndices[nextSubmit]
                    nextSubmit += 1
                    let perform = self.prepareGeminiPageForBatch
                    let pdfRef = pdf
                    group.addTask { @Sendable in
                        try await perform(
                            i, pdfRef, options,
                            stagingDir, pageEngine, figureExtractor
                        )
                    }
                    inflight += 1
                }
                if let p = try await group.next() {
                    inflight -= 1
                    prepared[p.pageIndex] = p
                    preppedCount += 1
                    progress?(Progress(
                        totalPages: totalPages,
                        completedPages: baselineCount + preppedCount,
                        currentPageMeanConfidence: 1.0
                    ))
                }
            }
        }

        // Trust-routed pages settle immediately.
        let trustCount = prepared.values.filter { $0.entryLine == nil }.count
        for (i, p) in prepared where p.entryLine == nil {
            pendingByIndex[i] = p.partial
        }
        dispatchLog("Phase A complete — preppedCount=\(preppedCount) trustRouted=\(trustCount)")

        // Gather Gemini-bound entries.
        let geminiEntries = freshIndices.compactMap { i -> (Int, Data)? in
            guard let p = prepared[i], let line = p.entryLine else { return nil }
            return (i, line)
        }
        guard !geminiEntries.isEmpty else {
            dispatchLog("no Gemini-bound entries — all pages trust-routed; returning")
            return
        }
        dispatchLog("geminiEntries to batch: \(geminiEntries.count)")

        // Reserve budget upfront — one call per page.
        let budget = pageEngine.budget
        for _ in geminiEntries {
            guard await budget.tryConsume() else {
                dispatchLog("budget exhausted mid-reservation — settling partials as final")
                for (i, _) in geminiEntries {
                    if pendingByIndex[i] == nil,
                       let p = prepared[i] {
                        pendingByIndex[i] = p.partial
                    }
                }
                return
            }
        }

        // Build JSONL bytes.
        var jsonl = Data()
        for (_, line) in geminiEntries {
            jsonl.append(line)
            jsonl.append(0x0A)  // newline
        }
        dispatchLog("built JSONL bytes=\(jsonl.count) for \(geminiEntries.count) entries")

        let batchClient = GeminiBatchAPIClient(
            apiKeyProvider: { apiKey },
            debugLogURL: debugLogURL
        )

        // Phase B — upload, submit, poll. On any failure, settle
        // every Gemini-bound page's partial as final and return.
        let inputFileName: String
        do {
            inputFileName = try await batchClient.uploadJSONL(
                jsonl, displayName: "humanist-batch-input.jsonl"
            )
        } catch {
            dispatchLog("uploadJSONL threw: \(error) — settling partials")
            for (i, _) in geminiEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            return
        }

        let submitted: GeminiBatchSubmitResponse
        do {
            let req = GeminiBatchSubmitRequest(
                displayName: "humanist-page-batch",
                inputFileName: inputFileName
            )
            submitted = try await batchClient.submit(
                model: modelId, request: req
            )
        } catch {
            dispatchLog("submit threw: \(error) — settling partials")
            for (i, _) in geminiEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            // Best-effort cleanup of the uploaded input file.
            try? await batchClient.deleteFile(name: inputFileName)
            return
        }

        // Signal "batch waiting" to the queue UI — same shape as
        // the Anthropic path so the row gets the spinner + label.
        progress?(Progress(
            totalPages: totalPages,
            completedPages: baselineCount + preppedCount,
            currentPageMeanConfidence: 1.0,
            phase: .batchWaiting
        ))

        let final: GeminiBatchStatusResponse
        do {
            final = try await batchClient.awaitCompletion(
                name: submitted.name
            )
        } catch {
            dispatchLog("awaitCompletion threw: \(error) — settling partials")
            for (i, _) in geminiEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            try? await batchClient.deleteFile(name: inputFileName)
            return
        }

        guard final.state == .succeeded,
              let resultsFile = final.resultsFileName else {
            // FAILED / CANCELLED / EXPIRED — same posture as
            // Anthropic batch failure. Surface empty pages.
            dispatchLog("terminal state=\(final.state.rawValue) resultsFileName=\(final.resultsFileName ?? "nil") errorMessage=\(final.errorMessage ?? "nil") — settling partials as empty")
            for (i, _) in geminiEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            try? await batchClient.deleteFile(name: inputFileName)
            return
        }
        dispatchLog("succeeded — fetching results file=\(resultsFile)")

        let results: [GeminiBatchResultLine]
        do {
            results = try await batchClient.fetchResults(
                fileName: resultsFile
            )
        } catch {
            dispatchLog("fetchResults threw: \(error) — settling partials")
            for (i, _) in geminiEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            try? await batchClient.deleteFile(name: inputFileName)
            try? await batchClient.deleteFile(name: resultsFile)
            return
        }

        // Phase C — walk results, parse each, fill in pending slots.
        var matchedCount = 0
        var unmatchedKeyCount = 0
        var unknownPageCount = 0
        // Per-status histogram so the log surfaces the
        // "scattered pages failed" pattern at a glance instead
        // of forcing the reader to count by hand.
        var statusHistogram: [ProviderStatus: Int] = [:]
        // Pages with a non-success final status, listed by index
        // so the user can correlate against the PDF and see
        // whether (e.g.) page 7 is a content the model refuses.
        var nonSuccessPages: [(Int, ProviderStatus, String?)] = []
        for line in results {
            guard let pageIndex = Self.pageIndexFromCustomId(line.key) else {
                unmatchedKeyCount += 1
                continue
            }
            guard let prep = prepared[pageIndex] else {
                unknownPageCount += 1
                continue
            }
            matchedCount += 1
            let parsedBlocks: [Block]
            let parsedFootnotes: [Footnote]
            let status: ProviderStatus
            var failureDetail: String? = nil
            switch line.result {
            case .succeeded(let raw):
                let outcome = await pageEngine.parseBatchResponseOutcome(
                    rawJSON: raw, pageIndex: pageIndex
                )
                if let parsed = outcome.result {
                    parsedBlocks = parsed.blocks
                    parsedFootnotes = parsed.footnotes
                    status = .succeeded
                } else {
                    parsedBlocks = []
                    parsedFootnotes = []
                    status = outcome.status
                    // Also record when a "succeeded" line parsed
                    // to .empty (zero blocks despite the model
                    // succeeding) — common Gemini failure mode
                    // worth surfacing separately.
                    if status == .succeeded && parsedBlocks.isEmpty {
                        failureDetail = "succeeded-but-parsed-empty"
                    }
                }
            case .errored(let message):
                parsedBlocks = []
                parsedFootnotes = []
                status = .apiError
                failureDetail = message
            }
            statusHistogram[status, default: 0] += 1
            if status != .succeeded || parsedBlocks.isEmpty {
                nonSuccessPages.append((pageIndex, status, failureDetail))
            }
            let finalPending = PendingPageOCR(
                pageIndex: prep.partial.pageIndex,
                anchorId: prep.partial.anchorId,
                pageBoundsCG: prep.partial.pageBoundsCG,
                blocks: parsedBlocks,
                footnotes: parsedFootnotes,
                figures: prep.partial.figures,
                verdict: prep.partial.verdict,
                qualityScore: prep.partial.qualityScore,
                extractorDiagnostics: prep.partial.extractorDiagnostics,
                pageOCRStatus: status,
                providerId: pageEngine.providerId,
                usedLocalFallback: false
            )
            pendingByIndex[pageIndex] = finalPending
            let prepHighWater = baselineCount + preppedCount
            progress?(Progress(
                totalPages: totalPages,
                completedPages: max(prepHighWater, pendingByIndex.count),
                currentPageMeanConfidence: 1.0
            ))
        }

        // Any Gemini-bound pages whose result didn't appear in
        // the JSONL get their partial as final.
        var orphanedPageCount = 0
        var orphanedPages: [Int] = []
        for (i, _) in geminiEntries where pendingByIndex[i] == nil {
            if let p = prepared[i] {
                pendingByIndex[i] = p.partial
                orphanedPageCount += 1
                orphanedPages.append(i)
            }
        }
        let histogramSummary = statusHistogram
            .sorted(by: { $0.value > $1.value })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        dispatchLog("Phase C summary: results=\(results.count) matched=\(matchedCount) unmatchedKey=\(unmatchedKeyCount) unknownPage=\(unknownPageCount) orphanedPages=\(orphanedPageCount) statusHistogram={\(histogramSummary)}")
        if !nonSuccessPages.isEmpty {
            dispatchLog("non-success pages (pageIdx,status,detail):")
            for (idx, status, detail) in nonSuccessPages.sorted(by: { $0.0 < $1.0 }) {
                dispatchLog("  page=\(idx) status=\(status) detail=\(detail ?? "")")
            }
        }
        if !orphanedPages.isEmpty {
            dispatchLog("orphaned pages (no result line returned): \(orphanedPages.sorted())")
        }

        // Q-Vision-Backfill-Batch: same posture as Anthropic batch.
        // Refused / empty / errored pages get a local Vision /
        // Tesseract OCR pass so the EPUB has *something* on them
        // instead of staying blank. Important for Gemini because
        // Flash's safety filter triggers on a non-trivial slice
        // of academic content (e.g., scattered pages in the
        // Becker book hit "succeeded-but-parsed-empty" / refused).
        var partialsByIndex: [Int: PendingPageOCR] = [:]
        for (idx, prep) in prepared { partialsByIndex[idx] = prep.partial }
        try await applyVisionBackfillForBatch(
            pageIndices: geminiEntries.map(\.0),
            partialsByIndex: partialsByIndex,
            pdf: pdf,
            options: options,
            providerId: pageEngine.providerId,
            debugLogURL: debugLogURL,
            pendingByIndex: &pendingByIndex
        )

        // Best-effort cleanup. Failures here are logged via the
        // try? but don't affect the conversion outcome — Google
        // expires files automatically.
        try? await batchClient.deleteFile(name: inputFileName)
        try? await batchClient.deleteFile(name: resultsFile)
        dispatchLog("dispatch end")
    }

    /// page-OCR path (after Surya extraction) and the resume
    /// fast-path (re-walking checkpointed `figures`).
    ///
    /// Cover detection is intentionally absent — the cascade path's
    /// `RegionAwareReflow.detectCoverFigure` runs on `pageResults`,
    /// which we don't populate here. EPUBs from the page-OCR path
    /// currently have no cover image; future work can reapply the
    /// "page-0 single dominant figure ≥ 50% of page area" rule here.
    func buildPageOCRFigureAsset(
        fig: FigureExtractor.ExtractedFigure,
        index: Int
    ) -> (assetId: String, asset: FigureAsset, block: Block) {
        let assetId = String(format: "fig-%05d", index)
        let asset = FigureAsset(
            id: assetId,
            data: fig.data,
            mediaType: fig.mediaType,
            intrinsicSize: fig.intrinsicSize,
            isCover: false
        )
        let alt = fig.regionKind == .formula ? "formula" : "figure"
        let block = Block.figure(assetId: assetId, alt: alt, caption: [])
        return (assetId, asset, block)
    }


    /// Save a CGImage as PNG to the given URL. Used by the debug-log
    /// path so we can visually inspect what Vision was actually fed.
    /// Silently no-ops on failure — debug aid, not load-bearing.
    static func savePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
    }

    /// Dump the per-page Sonnet response captures to a debug file.
    /// Each page section reads:
    ///   `--- page N (parsed-empty: yes/no) ---`
    ///   followed by the raw XHTML Sonnet returned (or `[REFUSED]` /
    ///   `[EMPTY]` markers when nothing came back). Useful for
    ///   diagnosing pages that produced no content in the EPUB —
    ///   the parsed-empty flag pinpoints whether the parser dropped
    ///   valid content or Sonnet returned nothing usable.
    /// Dump the chapter-promotion + chapter-split decision summary
    /// to `chapters.txt` in the debug staging dir. Sits next to the
    /// existing `log.txt` (reflow / observation-level) and
    /// `claude-pages.txt` (raw Sonnet XHTML). The three together
    /// give a full forensic trail from page observations → final
    /// chapter shape.
    static func writeChapterDecisionLog(
        promoter: ChapterHeadingPromoter.Diagnostics,
        splitter: ChapterSplitter.Diagnostics,
        tocDriven: TOCDrivenSplitter.Diagnostics?,
        outline: PDFOutlineSplitter.Diagnostics?,
        chapters: [Chapter],
        to url: URL
    ) throws {
        var out = "Chapter shape decision log\n"
        out += "==========================\n\n"

        out += "PROMOTER (pattern-based pre-splitter pass)\n"
        out += "paragraphs scanned: \(promoter.paragraphsScanned)\n"
        out += "promotions: \(promoter.promotions.count)\n"
        if promoter.promotions.isEmpty {
            out += "  (no chapter-marker paragraphs matched)\n"
        } else {
            for p in promoter.promotions {
                if let fused = p.fusedTitle {
                    out += "  + \(p.marker) ⇒ '\(p.headingText)' (fused: '\(fused)')\n"
                } else {
                    out += "  + \(p.marker) ⇒ '\(p.headingText)'\n"
                }
            }
        }
        out += "\n"

        if let outline {
            out += "SPLITTER (PDF outline path)\n"
            out += "outline entries: \(outline.entriesSeen)\n"
            out += "resolved to block index: \(outline.resolvedEntries)\n"
            out += "unresolved: \(outline.unresolvedEntries)\n\n"
            out += "FINAL CHAPTERS (\(chapters.count))\n"
            for (i, ch) in chapters.enumerated() {
                let title = ch.title ?? "(untitled)"
                out += "  \(i + 1). \(title) — \(ch.blocks.count) blocks\n"
            }
            try out.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        if let toc = tocDriven {
            out += "SPLITTER (TOC-driven path, strategy: \(toc.matchStrategy.rawValue))\n"
            out += "entries seen: \(toc.entriesSeen)\n"
            out += "arabic entries: \(toc.arabicEntries)\n"
            switch toc.matchStrategy {
            case .titleMatch:
                out += "boundaries: matched by heading text (offset learning skipped)\n"
            case .pageOffset:
                if let offset = toc.inferredOffset {
                    out += "inferred offset: \(offset) (pdf_index = display_page + \(offset) - 1)\n"
                } else {
                    out += "inferred offset: (offset learning failed)\n"
                }
            }
            out += "resolved to block index: \(toc.resolvedEntries)\n"
            out += "unresolved: \(toc.unresolvedEntries)\n\n"
            out += "FINAL CHAPTERS (\(chapters.count))\n"
            for (i, ch) in chapters.enumerated() {
                let title = ch.title ?? "(untitled)"
                out += "  \(i + 1). \(title) — \(ch.blocks.count) blocks\n"
            }
            try out.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        out += "SPLITTER\n"
        out += "headings seen: \(splitter.headingsSeen)\n"
        if !splitter.headingCountsByLevel.isEmpty {
            let levels = splitter.headingCountsByLevel.keys.sorted()
            let summary = levels.map { lvl in
                "H\(lvl)=\(splitter.headingCountsByLevel[lvl] ?? 0)"
            }.joined(separator: " ")
            out += "by level: \(summary)\n"
        }
        out += "detected chapter level: H\(splitter.detectedChapterLevel)\n"
        if let from = splitter.levelOverriddenFrom {
            out += "(ratio override fired: first-pass picked H\(from), promoted to H\(splitter.detectedChapterLevel))\n"
        }
        out += "eligible breaks: \(splitter.eligibleBreakCount)\n"
        out += "degenerate fallback used: \(splitter.degenerateFallbackUsed ? "yes" : "no")\n"
        if !splitter.filtered.isEmpty {
            out += "filtered headings (\(splitter.filtered.count)):\n"
            var byReason: [ChapterSplitter.Diagnostics.FilterReason: [ChapterSplitter.Diagnostics.Filtered]] = [:]
            for f in splitter.filtered {
                byReason[f.reason, default: []].append(f)
            }
            for reason in [
                ChapterSplitter.Diagnostics.FilterReason.runningHead,
                .tooShort, .startsLowercase, .midSentenceTerminator
            ] {
                guard let items = byReason[reason], !items.isEmpty else { continue }
                out += "  [\(reason.rawValue)] \(items.count)\n"
                for item in items.prefix(10) {
                    let preview = String(item.text.prefix(80))
                    out += "    - H\(item.level): \(preview)\n"
                }
                if items.count > 10 {
                    out += "    ... and \(items.count - 10) more\n"
                }
            }
        }
        out += "\n"

        out += "FINAL CHAPTERS (\(chapters.count))\n"
        for (i, ch) in chapters.enumerated() {
            let title = ch.title ?? "(untitled)"
            out += "  \(i + 1). \(title) — \(ch.blocks.count) blocks\n"
        }

        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeClaudePageResponses(
        _ responses: [ClaudePageOCREngine.CapturedResponse],
        to url: URL
    ) throws {
        // Bucket every response into a single status tag for the
        // header summary. Sentinel-only raw bodies start with "["
        // (e.g. "[REFUSED]", "[REFUSED: SAFETY]", "[EMPTY]",
        // "[FINISH: …]", "[API ERROR…]"); everything else is a
        // model-produced XHTML body.
        var refused: [Int] = []
        var empty: [Int] = []
        var apiError: [Int] = []
        var succeeded = 0
        for r in responses {
            let raw = r.rawXHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("[REFUSED") {
                refused.append(r.pageIndex)
            } else if raw.hasPrefix("[EMPTY") || raw.hasPrefix("[FINISH") {
                empty.append(r.pageIndex)
            } else if raw.hasPrefix("[API ERROR")
                || raw.hasPrefix("[SEND FAILED")
                || raw.hasPrefix("[DECODE FAILED") {
                apiError.append(r.pageIndex)
            } else {
                succeeded += 1
            }
        }
        refused.sort()
        empty.sort()
        apiError.sort()

        let total = max(1, responses.count)
        let refusalPct = Double(refused.count) / Double(total) * 100
        var out = "Page-OCR raw responses\n"
        out += "======================\n"
        out += "pages captured:  \(responses.count)\n"
        out += "succeeded:       \(succeeded)\n"
        out += String(format: "refused:         %d (%.1f%%)\n",
                      refused.count, refusalPct)
        out += "empty:           \(empty.count)\n"
        out += "api-error:       \(apiError.count)\n"
        out += "parsed-empty:    \(responses.filter(\.parsedBlocksEmpty).count)\n"
        if !refused.isEmpty {
            let preview = refused.prefix(50)
                .map { String($0) }
                .joined(separator: ", ")
            out += "refused pages:   \(preview)"
            if refused.count > 50 {
                out += " (+ \(refused.count - 50) more)"
            }
            out += "\n"
        }
        out += "\n"
        for r in responses.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            let emptyTag = r.parsedBlocksEmpty ? " (parsed-empty: yes)" : ""
            out += "--- page \(r.pageIndex)\(emptyTag) ---\n"
            out += r.rawXHTML
            if !r.rawXHTML.hasSuffix("\n") { out += "\n" }
            out += "\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }
}
