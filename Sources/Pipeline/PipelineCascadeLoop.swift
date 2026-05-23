import Foundation
import CoreGraphics
import AI
import Document
import EPUB
import Layout
import OCR
import PDFIngest

// MARK: - C-Pipeline-File-Split Stage 2 (cascade per-page loop body)
//
// Extracted from `PDFToEPUBPipeline.swift` 2026-05-18. Holds the
// `CascadePageOutcome` value type and the `processCascadePage(...)`
// helper that drives one page through the cascade pipeline
// (embedded-text trust scoring → Vision/Surya concurrent OCR +
// layout → fallback figures → region cascade → optional Haiku
// post-OCR cleanup → figure + table extraction). This is the
// helper P-Cascade-Parallel Phase A introduced; Phase B will
// wrap a bounded TaskGroup around the call in `convert(...)`.
extension PDFToEPUBPipeline {

    // MARK: - Cascade per-page extraction (P-Cascade-Parallel Phase A)

    /// Outcome bundle returned by `processCascadePage(...)`. Carries
    /// everything the convert-loop's cascade branch used to write
    /// directly into its outer accumulators (extractorDiagnostics,
    /// qualityScores, verdictsByPage, figureExtractionsByPage,
    /// tableExtractionsByKey, correctionTrailEntries, layoutErrors,
    /// ocrErrors, pageResults). The caller reassembles these into
    /// the loop's accumulators after each page.
    ///
    /// Pulled out as the first step of `P-Cascade-Parallel` —
    /// extracting this lets Phase B add a bounded TaskGroup over
    /// the cascade-bound pages without further refactoring the
    /// per-page work.
    struct CascadePageOutcome: Sendable {
        let pageObservations: PageObservations
        let verdict: EmbeddedTextQualityScorer.Verdict
        /// Page-local figure list. Caller assigns this into
        /// `figureExtractionsByPage[i]` only when non-empty.
        /// Preserves the prior code's two-stage shape: fallback
        /// figures append, then a successful per-region extract
        /// REPLACES the appended fallback.
        let figures: [FigureExtractor.ExtractedFigure]
        /// Per-region table extractions. Caller maps these to
        /// `tableExtractionsByKey[PageRegionKey(pageIndex:i, regionIndex:...)]`.
        let tableEntries: [(regionIndex: Int, rows: [[TableCell]])]
        let qualityScore: EmbeddedTextQualityScorer.Score
        let extractorDiagnostics: EmbeddedTextExtractor.Diagnostics
        let correctionTrailEntries: [CorrectionTrail.Entry]
        let layoutError: String?
        let ocrError: String?
        let confidenceForProgress: Double
    }

    /// Per-page cascade body. Runs embedded-text extraction +
    /// quality scoring, dispatches on the resulting verdict
    /// (`.trust` skips OCR; `.reocr` runs render → Vision/Surya
    /// concurrently → fallback figures → region cascade → optional
    /// Haiku post-OCR cleanup → figure + table extraction), and
    /// returns the page's outcome bundle. Behavior is bit-for-bit
    /// equivalent to the inline body that lived in the for-loop
    /// prior to this extraction; all accumulator writes have moved
    /// from outer dict-mutations into struct fields the caller
    /// unpacks.
    func processCascadePage(
        pageIndex i: Int,
        pdf: LoadedPDF,
        options: Options,
        stagingDir: URL,
        renderer: PDFRenderer,
        pagePreprocessor: PageImagePreprocessor?,
        hints: OCRHints,
        figureExtractor: FigureExtractor,
        googleDocumentOCREngine: GoogleDocumentOCREngine?,
        landingAIDocumentEngine: LandingAIDocumentEngine?,
        cloudOCREngine: (any OCREngine)?,
        claudePostProcessor: (any PostOCRProcessor)?,
        cloudTableExtractor: (any TableExtractor)?,
        landingAITableExtractor: LandingAITableExtractor?
    ) async throws -> CascadePageOutcome {
        // Sync prep: embedded extraction + quality scoring. Wrap
        // in autoreleasepool so PDFKit/CoreGraphics NSObject
        // temporaries (PDFPage instances, NSStrings from text
        // extraction) drain at the closure boundary instead of
        // piling up on the convert task's outer pool until the
        // entire conversion ends.
        //
        // The scorer takes the user's expected languages so it
        // can downgrade `.trust` → `.reocr` on language mismatch
        // — catches PDFs whose embedded text is coherent but
        // in the wrong language (usually the artifact of a
        // previous bad OCR pass).
        let expectedLanguages = options.languages.map(\.rawValue)
        let (extracted, quality) = autoreleasepool { () -> ((lines: [EmbeddedTextExtractor.Line], diagnostics: EmbeddedTextExtractor.Diagnostics), EmbeddedTextQualityScorer.Score) in
            let e = embeddedExtractor.extract(from: pdf, pageIndex: i)
            let combined = e.lines.map(\.text).joined(separator: " ")
            let q = qualityScorer.score(
                text: combined, expectedLanguages: expectedLanguages
            )
            return (e, q)
        }

        var observations: [TextObservation]
        let pageBounds: CGSize
        let confidenceForProgress: Double
        var layoutForPage: [LayoutRegion]? = nil

        // Per-page accumulators that used to write directly to
        // outer dicts. Caller unpacks these from the outcome.
        var figures: [FigureExtractor.ExtractedFigure] = []
        var tableEntries: [(regionIndex: Int, rows: [[TableCell]])] = []
        var correctionTrail: [CorrectionTrail.Entry] = []
        var layoutError: String? = nil
        var ocrError: String? = nil

        // `forceOCR` (and per-page `forceOCRPageRanges`)
        // override the scorer's `.trust` verdict. The scorer's
        // score/diagnostics are still surfaced in the outcome so
        // the debug log shows what *would* have happened — but
        // the dispatch always takes the `.reocr` branch.
        let effectiveVerdict: EmbeddedTextQualityScorer.Verdict =
            options.shouldForceOCR(forPageIndex: i) ? .reocr : quality.verdict

        switch effectiveVerdict {
        case .trust:
            // Embedded text is good — skip Vision OCR entirely.
            // Bbox lookup hits PDFKit page accessor (autoreleased).
            let trustResult = autoreleasepool { () -> (obs: [TextObservation], bounds: CGSize) in
                let obs = extracted.lines.map { line in
                    TextObservation(
                        text: line.text,
                        confidence: 0.95,
                        box: line.box,
                        source: .embedded
                    )
                }
                let bounds: CGSize
                if let pdfPage = pdf.document.page(at: i) {
                    let r = pdfPage.bounds(for: .mediaBox)
                    bounds = CGSize(width: r.width, height: r.height)
                } else {
                    bounds = .zero
                }
                return (obs, bounds)
            }
            observations = trustResult.obs
            pageBounds = trustResult.bounds
            confidenceForProgress = 1.0

        case .reocr:
            // Render + (preprocess if scan) + savePNG. Largest sync
            // allocation in the loop; CGContext + CFData buffers
            // are CFType so ARC handles release, but the dispatch
            // infra around CGImageDestination autoreleases
            // NSURL/NSData bridging objects.
            let pngURL = stagingDir.appendingPathComponent("page-\(i).png")
            let image: CGImage = try autoreleasepool {
                let raw = try renderer.renderPage(at: i, of: pdf)
                // Preprocessor is non-nil only on scan-likely docs;
                // for everything else the render passes through.
                let cleaned = pagePreprocessor?.process(raw) ?? raw
                Self.savePNG(cleaned, to: pngURL)
                return cleaned
            }
            let pageEngine = selectEngine(
                for: hints.languages,
                preferSurya: options.useHighAccuracyOCR
            )
            // pageBounds is pure image geometry — hoist it before
            // the concurrent block so analyzeLayoutWithRetry can
            // use it without depending on the OCR result.
            let initialPageBounds = CGSize(
                width: image.width, height: image.height
            )

            // P-Vision-Concurrency: run Vision OCR and Surya layout
            // concurrently. Both read from the already-rendered
            // CGImage / saved PNG and produce independent outputs.
            // analyzeLayoutWithRetry is a no-op when layoutAnalyzer
            // is nil, so the guard is handled inside that method.
            let pdfRef = pdf
            async let ocrTask = ocrPageWithFallback(
                image: image, pdf: pdfRef, pageIndex: i,
                initialDPI: options.dpi,
                primaryEngine: pageEngine, hints: hints
            )
            async let layoutTask = analyzeLayoutWithRetry(
                pdf: pdfRef,
                pageIndex: i,
                initialDPI: options.dpi,
                initialPNGURL: pngURL,
                initialPageBounds: initialPageBounds,
                stagingDir: stagingDir
            )

            let (result, ocrErrorTrail) = try await ocrTask
            let layoutOutcome = await layoutTask

            if let trail = ocrErrorTrail {
                ocrError = trail
            }
            observations = gapFiller.fill(
                visionObservations: result.observations,
                embeddedLines: extracted.lines
            )
            pageBounds = initialPageBounds
            confidenceForProgress = result.meanConfidence

            layoutForPage = layoutOutcome.layout
            if let err = layoutOutcome.error {
                layoutError = err
            }

            // No-Surya figure fallback. Routes around the
            // layout array entirely — picks up born-digital
            // XObjects first, then Vision saliency, and
            // appends ExtractedFigures directly to the
            // figure-asset pile so the reflow's non-region-
            // aware path still processes body text. No-op
            // when Surya provided a layout.
            let fallbackFigures = await extractFallbackFigures(
                pdf: pdf, pageIndex: i,
                pageImage: image,
                textObservations: observations,
                layoutAvailable: layoutForPage != nil
            )
            if !fallbackFigures.isEmpty {
                figures.append(contentsOf: fallbackFigures)
            }

            // Phase 4.5: per-region cascade. Vision → Surya
            // (whole-page re-OCR, region-by-region replacement) →
            // Tesseract (per-region crop). Skipped when the user
            // already forced Surya for the whole page (no point
            // re-OCRing what's already Surya output) or when
            // there's no layout to localize problems.
            if !options.useHighAccuracyOCR,
               let regions = layoutForPage, !regions.isEmpty {
                switch options.processingMode {
                case .privateLocal:
                    observations = await RegionCascade.run(
                        observations: observations,
                        regions: regions,
                        pageImage: image,
                        hints: hints,
                        suryaEngine: suryaEngine,
                        tesseractEngine: tesseractEngine
                    )
                case .cloud:
                    let suppressLocalEngines =
                        options.useCloudEnhancedOCR
                        || options.disableLocalCascadeEscalation
                    let cascadeSurya = suppressLocalEngines
                        ? nil : suryaEngine
                    let cascadeTess = suppressLocalEngines
                        ? nil : tesseractEngine
                    // Stage 2.5 picks the LandingAI engine when the
                    // user explicitly opted in (it's the alternative),
                    // otherwise falls back to the Google default.
                    // RegionCascade catches both engines' budget-
                    // exhausted errors at the per-region loop site.
                    let documentAIEngine: (any OCREngine)? =
                        landingAIDocumentEngine ?? googleDocumentOCREngine
                    observations = await RegionCascade.run(
                        observations: observations,
                        regions: regions,
                        pageImage: image,
                        hints: hints,
                        suryaEngine: cascadeSurya,
                        tesseractEngine: cascadeTess,
                        documentAIEngine: documentAIEngine,
                        claudeEngine: cloudOCREngine,
                        forceClaudeOnAllRegions: options.disableLocalCascadeEscalation
                    )
                }
            }

            // Cloud Phase 6: post-OCR Haiku cleanup. After the
            // cascade has settled the per-region OCR text, walk
            // the text-bearing regions and ask Haiku to fix
            // character-level errors on the ones whose
            // `OCRTextQualityScorer` score falls below the
            // post-processor's trigger threshold. The processor
            // gates internally on quality + length + budget;
            // accepted corrections replace the region's
            // observations, rejected ones are no-ops. When
            // vision mode is enabled the page image is passed in
            // so each region can be cropped and sent alongside
            // the OCR text — costlier but higher quality.
            if let postProcessor = claudePostProcessor,
               let regions = layoutForPage, !regions.isEmpty {
                let mode: ClaudePostProcessor.Mode =
                    options.cloudFeatures.postOCRCleanupVisionMode
                        ? .vision : .passages
                let outcome = await Self.applyPostOCRCleanup(
                    observations: observations,
                    regions: regions,
                    pageImage: image,
                    pageIndex: i,
                    hints: hints,
                    mode: mode,
                    postProcessor: postProcessor
                )
                observations = outcome.observations
                correctionTrail.append(contentsOf: outcome.trailEntries)
            }

            // Phase 6: extract figures (.picture, .formula) from
            // the rendered page so the reflow can emit
            // `Block.figure` and the EPUB writer can embed the
            // bytes. Done here because the page CGImage is only
            // alive during this loop iteration.
            if let regions = layoutForPage, !regions.isEmpty {
                let extracted = figureExtractor.extract(
                    pageIndex: i, regions: regions, pageImage: image
                )
                if !extracted.isEmpty {
                    // Mirror the prior assignment-semantics: a
                    // successful per-region extract REPLACES the
                    // fallback figures appended above. (Behavior
                    // preserved from the pre-extraction inline
                    // code at the loop site.)
                    figures = extracted
                }
            }

            // Phase 6 (Path A): for each `.table` region, run
            // Surya's table-structure model on a cropped image
            // and map this page's OCR observations onto cells.
            // Skipped when the sidecar isn't available; reflow
            // falls back to `TableHeuristic` for those regions.
            if let regions = layoutForPage {
                let extractors: [any TableExtractor] = {
                    switch options.processingMode {
                    case .privateLocal:
                        return [tableExtractor].compactMap { $0 }
                    case .cloud:
                        // Cloud first, Surya as offline fallback for
                        // declines / refusals / parse failures.
                        // LandingAI prepended when the user opted in —
                        // ADE is purpose-built for tables and often
                        // beats the Claude prompt path on dense
                        // layouts; Claude picks up cases where ADE
                        // returned no parseable table.
                        return [
                            landingAITableExtractor as (any TableExtractor)?,
                            cloudTableExtractor,
                            tableExtractor as (any TableExtractor)?,
                        ].compactMap { $0 }
                    }
                }()
                if !extractors.isEmpty {
                    for (regionIdx, region) in regions.enumerated()
                    where region.kind == .table {
                        for ext in extractors {
                            if let rows = await ext.extract(
                                pageImage: image,
                                regionBox: region.box,
                                observations: observations,
                                stagingDir: stagingDir,
                                pageIndex: i,
                                regionIndex: regionIdx
                            ) {
                                tableEntries.append((regionIdx, rows))
                                break
                            }
                        }
                    }
                }
            }
            // No per-page PNG cleanup — the staging dir's lifecycle
            // (temp removed in `defer`, debug folder kept) handles
            // it as a single batch.
        }

        return CascadePageOutcome(
            pageObservations: PageObservations(
                pageIndex: i,
                pageBounds: pageBounds,
                observations: observations,
                layoutRegions: layoutForPage
            ),
            verdict: effectiveVerdict,
            figures: figures,
            tableEntries: tableEntries,
            qualityScore: quality,
            extractorDiagnostics: extracted.diagnostics,
            correctionTrailEntries: correctionTrail,
            layoutError: layoutError,
            ocrError: ocrError,
            confidenceForProgress: confidenceForProgress
        )
    }
}
