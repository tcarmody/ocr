import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import PDFIngest
import OCR
import EPUB
import Layout

/// End-to-end orchestration: PDF on disk → EPUB on disk.
///
/// Two-pass design:
///   1. Render every page, OCR it, collect observations + geometry.
///   2. Run the reflow pipeline:
///        a. `HeaderFooterClassifier` learns running heads / footers /
///           page numbers across pages and marks them for removal.
///        b. `ParagraphReflow` groups remaining observations into
///           paragraphs per page using bounding-box geometry.
///        c. Cross-page bridge merges paragraphs split mid-word at page
///           boundaries (soft hyphens spanning pages).
///
/// Tesseract routing, layout-aware blocking, footnote linking, and
/// page-level parallelism arrive in later phases. The shape of this
/// type stays the same.
public actor PDFToEPUBPipeline {
    public struct Options: Sendable {
        public var dpi: CGFloat
        public var languages: [BCP47]
        public var ocrQuality: OCRHints.Quality
        /// When true, keep all per-page PNG renders + the debug log
        /// in a sibling folder `<basename>.humanist-debug/` next to
        /// the output EPUB. When false (default), PNGs are written
        /// to a temp directory and deleted at end of conversion;
        /// no log file is produced. Useful only when investigating
        /// why a specific page came out wrong — at bulk scale these
        /// artifacts add hundreds of files per book.
        public var emitDebugLog: Bool
        /// Force Surya as the OCR engine for every page that goes
        /// through the reocr branch. Slower (~10–20 s/page on Apple
        /// Silicon vs Vision's ~1 s) but recovers lines that Vision
        /// silently drops on certain page typography.
        public var useHighAccuracyOCR: Bool
        /// Master switch for Cloud-mode features (Claude-backed
        /// engines for hard-region OCR + table extraction + cleanup).
        /// Defaults to `.privateLocal` — first-run conversions need
        /// no setup and no data leaves the machine.
        public var processingMode: ProcessingMode
        /// Per-feature toggles consulted only when
        /// `processingMode == .cloud`. In `.privateLocal` mode the
        /// values are inert.
        public var cloudFeatures: AISettings.CloudFeatures
        /// Hard ceiling on Claude calls per book, shared across all
        /// Cloud-mode features. Pipeline constructs one
        /// `ClaudeCallBudget` per `convert(...)` from this value and
        /// passes it to every Claude engine the conversion uses.
        public var perBookCallCap: Int
        /// API key resolver. Held as a closure so the keychain-backed
        /// store can rotate keys without rebuilding `Options`. Returns
        /// nil → Cloud mode degrades silently to local-only with a
        /// debug-log line.
        public var anthropicAPIKeyProvider: @Sendable () -> String?
        /// **Experimental / spike use only.** When true and
        /// `processingMode == .cloud`, the OCR cascade pulls Surya
        /// + Tesseract out of the escalation chain *and* feeds every
        /// text-bearing region to Claude unconditionally (bypassing
        /// the quality-floor gate and the prior-tier guardrail that
        /// would otherwise prevent rewrites). Result: a pure-Claude
        /// CER measurement, suitable for "would Claude beat the
        /// local stack head-to-head" comparisons. Used by
        /// `SpikeRunner`; production callers must leave this off
        /// — the cascade is designed to gate Claude behind a quality
        /// floor for cost control.
        public var disableLocalCascadeEscalation: Bool

        public init(
            dpi: CGFloat = 400,
            languages: [BCP47] = [.en],
            ocrQuality: OCRHints.Quality = .accurate,
            emitDebugLog: Bool = false,
            useHighAccuracyOCR: Bool = false,
            processingMode: ProcessingMode = .privateLocal,
            cloudFeatures: AISettings.CloudFeatures = AISettings.CloudFeatures(),
            perBookCallCap: Int = 200,
            anthropicAPIKeyProvider: @escaping @Sendable () -> String? = { nil },
            disableLocalCascadeEscalation: Bool = false
        ) {
            self.dpi = dpi
            self.languages = languages
            self.ocrQuality = ocrQuality
            self.emitDebugLog = emitDebugLog
            self.useHighAccuracyOCR = useHighAccuracyOCR
            self.processingMode = processingMode
            self.cloudFeatures = cloudFeatures
            self.perBookCallCap = perBookCallCap
            self.anthropicAPIKeyProvider = anthropicAPIKeyProvider
            self.disableLocalCascadeEscalation = disableLocalCascadeEscalation
        }
    }

    public struct Progress: Sendable {
        public var totalPages: Int
        public var completedPages: Int
        public var currentPageMeanConfidence: Double  // NaN if no observations
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void

    private let loader = PDFLoader()
    private let visionEngine: any OCREngine
    private let tesseractEngine: (any OCREngine)?
    private let suryaEngine: (any OCREngine)?
    private let layoutAnalyzer: SuryaLayoutAnalyzer?
    private let tableExtractor: SuryaTableExtractor?
    private let embeddedExtractor = EmbeddedTextExtractor()
    private let gapFiller = EmbeddedTextGapFiller()
    private let qualityScorer = EmbeddedTextQualityScorer()

    public init(
        visionEngine: any OCREngine = VisionOCREngine(),
        tesseractEngine: (any OCREngine)? = TesseractOCREngine.detect(),
        // Default to the process-wide shared SuryaConnection so all
        // pipelines (one per job in bulk runs) talk to the same Python
        // sidecar. `.detect()` here would spawn a fresh ~5-15 GB
        // interpreter per pipeline and orphan the previous one.
        suryaConnection: SuryaConnection? = SuryaConnection.shared
    ) {
        self.visionEngine = visionEngine
        self.tesseractEngine = tesseractEngine
        // Surya layout + OCR + table all share one Python process.
        // Constructing every wrapper from the same connection means
        // weights for whichever modes are exercised load once for
        // the lifetime of the app.
        if let suryaConnection {
            self.suryaEngine = SuryaOCREngine(connection: suryaConnection)
            self.layoutAnalyzer = SuryaLayoutAnalyzer(connection: suryaConnection)
            self.tableExtractor = SuryaTableExtractor(connection: suryaConnection)
        } else {
            self.suryaEngine = nil
            self.layoutAnalyzer = nil
            self.tableExtractor = nil
        }
    }

    /// Build the Cloud-mode OCR engine for one conversion, or nil
    /// when Cloud mode is off, the hard-region-OCR feature toggle
    /// is off, or no API key is configured. Returning nil from any
    /// of those conditions makes `RegionCascade` skip Stage 3
    /// entirely — `.cloud` mode without a key behaves like
    /// `.privateLocal`, which is the right "fail open" posture.
    static func makeClaudeOCREngine(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeOCREngine? {
        guard options.processingMode == .cloud else { return nil }
        guard options.cloudFeatures.hardRegionOCR else { return nil }
        // Capture the key once per conversion. Rotation mid-conversion
        // is rare; if it happens, this conversion uses the key it
        // started with. The next conversion picks up the rotated key.
        guard let key = options.anthropicAPIKeyProvider(),
              !key.isEmpty else { return nil }
        let client = AnthropicAPIClient(apiKeyProvider: { key })
        return ClaudeOCREngine(client: client, budget: budget)
    }

    /// Route an OCR call to the right engine.
    ///
    ///   * `preferSurya` (high-accuracy mode): Surya wins if available.
    ///     Fall back through Tesseract → Vision when not.
    ///   * Otherwise: Tesseract for ancient/non-Latin scripts, Vision
    ///     for everything else.
    ///
    /// Missing engines degrade gracefully (logged, not raised).
    private func selectEngine(for languages: [BCP47], preferSurya: Bool) -> any OCREngine {
        if preferSurya, let suryaEngine { return suryaEngine }
        if let tesseractEngine, Self.shouldPreferTesseract(for: languages) {
            return tesseractEngine
        }
        return visionEngine
    }

    /// Languages where Tesseract beats Vision in the cases the plan
    /// enumerates: ancient scripts (Greek, Latin) and non-Latin scripts
    /// (Hebrew, Syriac, Coptic, Arabic, CJK, Cyrillic).
    /// Re-OCR a single page of a PDF using the caller-chosen engine,
    /// then run it through the same layout + region-aware reflow the
    /// converter does in bulk. Used by the editor's "Re-OCR Current
    /// Page With…" command.
    ///
    /// When Surya layout is available, the chosen engine runs **per
    /// region** (each column, body block, footnote, etc. gets its
    /// own crop). That's what keeps Tesseract from merging left- and
    /// right-column words into one cross-column "line" — Tesseract
    /// clusters by Y globally, so a whole-page call scrambles
    /// columns. Per-region OCR sidesteps the issue for any engine.
    ///
    /// Falls back to a single whole-page call when no layout is
    /// available (Surya not installed, both layout attempts failed).
    public func reOCRSinglePage(
        pdfURL: URL,
        pageIndex: Int,
        engine: any OCREngine,
        languages: [BCP47],
        ocrQuality: OCRHints.Quality = .accurate,
        dpi: CGFloat = 400
    ) async throws -> SinglePageResult {
        let pdf = try loader.load(pdfURL)
        guard pageIndex >= 0, pageIndex < pdf.pageCount else {
            throw SinglePageError.invalidPageIndex(pageIndex, pageCount: pdf.pageCount)
        }
        let renderer = PDFRenderer(dpi: dpi)
        let hints = OCRHints(languages: languages, quality: ocrQuality)

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Humanist-rescan-\(UUID().uuidString)", isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: stagingDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let image = try renderer.renderPage(at: pageIndex, of: pdf)
        let pngURL = stagingDir.appendingPathComponent("page.png")
        Self.savePNG(image, to: pngURL)
        let pageBounds = CGSize(width: image.width, height: image.height)

        // Layout first (with retry-at-lower-DPI). If we get regions,
        // the engine runs per-region; otherwise we fall back to
        // whole-page OCR.
        var layoutRegions: [LayoutRegion]? = nil
        if layoutAnalyzer != nil {
            let outcome = await analyzeLayoutWithRetry(
                pdf: pdf,
                pageIndex: pageIndex,
                initialDPI: dpi,
                initialPNGURL: pngURL,
                initialPageBounds: pageBounds,
                stagingDir: stagingDir
            )
            layoutRegions = outcome.layout
        }

        let observations: [TextObservation]
        if let regions = layoutRegions,
           regions.contains(where: { Self.reOCRTextBearingKinds.contains($0.kind) }) {
            observations = await ocrPerRegion(
                engine: engine, image: image, regions: regions, hints: hints
            )
        } else {
            // No usable layout — single whole-page call. Tesseract
            // will scramble columns in this fallback, but there's no
            // better option without region info.
            let result = try await engine.recognize(image: image, hints: hints)
            observations = result.observations
        }

        let pageObs = PageObservations(
            pageIndex: pageIndex,
            pageBounds: pageBounds,
            observations: observations,
            layoutRegions: layoutRegions
        )
        let reflowed = RegionAwareReflow.reflow(pageResults: [pageObs])

        return SinglePageResult(
            blocks: reflowed.blocks,
            footnotes: reflowed.footnotes,
            pageAnchors: reflowed.pageAnchors
        )
    }

    /// Region kinds that should be OCR'd individually in the
    /// per-region re-OCR path. Includes `.footnote` so footnote
    /// content is re-OCR'd alongside body — they get spliced into
    /// chapter footnotes by `FootnoteLinker`.
    private static let reOCRTextBearingKinds: Set<LayoutRegion.Kind> = [
        .text, .sectionHeader, .title, .listItem, .caption, .footnote,
    ]

    /// Run `engine` on each text-bearing region of `image` (cropped
    /// to the region's bbox), translate observations back into
    /// page-normalized coordinates, and confine each set to its own
    /// region so a stray edge-of-crop glyph doesn't bleed out.
    /// Mirrors what `RegionCascade` does for region-level Tesseract
    /// crops, applied as the standard re-OCR strategy.
    private func ocrPerRegion(
        engine: any OCREngine,
        image: CGImage,
        regions: [LayoutRegion],
        hints: OCRHints
    ) async -> [TextObservation] {
        var combined: [TextObservation] = []
        for region in regions where Self.reOCRTextBearingKinds.contains(region.kind) {
            guard let cropped = RegionCascade.cropImage(image, to: region.box)
            else { continue }
            do {
                let result = try await engine.recognize(image: cropped, hints: hints)
                let translated = RegionCascade.translate(
                    observations: result.observations,
                    fromCropOf: region.box,
                    intoFullPage: image
                )
                let confined = RegionCascade.filter(
                    observations: translated, inRegion: region
                )
                combined.append(contentsOf: confined)
            } catch {
                // Swallow per-region OCR failures — the rest of the
                // page still produces useful output. Caller's overall
                // throw path is reserved for unrecoverable errors
                // (PDF load, bad page index, etc.).
                continue
            }
        }
        return combined
    }

    /// Run primary OCR on `image`. On error, retry once at a smaller
    /// DPI (Surya's buffer-overflow errors are dimension-keyed); if
    /// that also fails, fall back to Vision so the conversion
    /// continues with degraded quality on that page rather than the
    /// whole job failing. Cancellation is re-thrown unchanged.
    ///
    /// Returns (result, errorTrail). When `errorTrail` is non-nil the
    /// caller can surface it in the debug log so the user knows which
    /// pages got fallback treatment.
    private func ocrPageWithFallback(
        image: CGImage,
        pdf: LoadedPDF,
        pageIndex: Int,
        initialDPI: CGFloat,
        primaryEngine: any OCREngine,
        hints: OCRHints
    ) async throws -> (result: OCRResult, errorTrail: String?) {
        do {
            let result = try await primaryEngine.recognize(
                image: image, hints: hints
            )
            return (result, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch let primaryError {
            // Retry at 75% DPI with the same engine. Surya's "index N
            // out of bounds" errors are tied to image dimensions, so
            // a smaller render often gets through.
            let retryDPI = max(150, initialDPI * 0.75)
            do {
                let retryRenderer = PDFRenderer(dpi: retryDPI)
                let retryImage = try retryRenderer.renderPage(
                    at: pageIndex, of: pdf
                )
                let result = try await primaryEngine.recognize(
                    image: retryImage, hints: hints
                )
                let trail = "primary@\(Int(initialDPI))dpi failed "
                    + "(\(primaryError)); succeeded at \(Int(retryDPI))dpi"
                return (result, trail)
            } catch is CancellationError {
                throw CancellationError()
            } catch let retryError {
                // Both attempts with the chosen engine failed. Vision
                // is always installed — fall back so the page
                // produces *some* output instead of nothing.
                do {
                    let visionResult = try await visionEngine.recognize(
                        image: image, hints: hints
                    )
                    let trail = "primary@\(Int(initialDPI))dpi failed "
                        + "(\(primaryError)); retry@\(Int(retryDPI))dpi failed "
                        + "(\(retryError)); fell back to Vision"
                    return (visionResult, trail)
                } catch let fallbackError {
                    // Vision also failed — return empty observations
                    // so the page is blank but the job continues.
                    let trail = "all engines failed (primary: "
                        + "\(primaryError); retry: \(retryError); "
                        + "Vision fallback: \(fallbackError))"
                    return (
                        OCRResult(text: "", meanConfidence: .nan, observations: []),
                        trail
                    )
                }
            }
        }
    }

    /// Run Surya layout with one fallback retry at 75% DPI. Surya
    /// occasionally throws internal buffer-overflow errors keyed to
    /// specific image dimensions; the smaller retry image usually
    /// dodges them. Returned layout bboxes are normalized 0..1 so
    /// they still align with the high-DPI image used for OCR and
    /// cascade — the retry render only matters to Surya.
    ///
    /// Returns (layout, errorDescription). Either both are
    /// meaningful (success: layout non-nil, error nil) or layout is
    /// nil and error describes both attempts.
    private func analyzeLayoutWithRetry(
        pdf: LoadedPDF,
        pageIndex: Int,
        initialDPI: CGFloat,
        initialPNGURL: URL,
        initialPageBounds: CGSize,
        stagingDir: URL
    ) async -> (layout: [LayoutRegion]?, error: String?) {
        guard let analyzer = layoutAnalyzer else { return (nil, nil) }
        do {
            let result = try await analyzer.analyze(
                imageURL: initialPNGURL, pageBounds: initialPageBounds
            )
            return (result, nil)
        } catch let primaryError {
            let retryDPI = max(150, initialDPI * 0.75)
            do {
                let retryRenderer = PDFRenderer(dpi: retryDPI)
                let retryImage = try retryRenderer.renderPage(at: pageIndex, of: pdf)
                let retryURL = stagingDir.appendingPathComponent(
                    "page-\(pageIndex)-retry.png"
                )
                Self.savePNG(retryImage, to: retryURL)
                let retryBounds = CGSize(
                    width: retryImage.width, height: retryImage.height
                )
                let result = try await analyzer.analyze(
                    imageURL: retryURL, pageBounds: retryBounds
                )
                return (result, nil)
            } catch let retryError {
                let msg = "primary@\(Int(initialDPI))dpi: \(primaryError); "
                    + "retry@\(Int(retryDPI))dpi: \(retryError)"
                return (nil, msg)
            }
        }
    }

    public struct SinglePageResult: Sendable {
        public var blocks: [Block]
        public var footnotes: [Footnote]
        public var pageAnchors: [PageAnchor]
    }

    public enum SinglePageError: Error, LocalizedError {
        case invalidPageIndex(Int, pageCount: Int)
        public var errorDescription: String? {
            switch self {
            case .invalidPageIndex(let i, let count):
                return "PDF has \(count) page\(count == 1 ? "" : "s"); page \(i + 1) is out of range."
            }
        }
    }

    public static func shouldPreferTesseract(for languages: [BCP47]) -> Bool {
        let tesseractStrong: Set<String> = [
            "grc", "la",                               // ancient
            "he", "ar",                                // RTL
            "syr", "cop", "san", "chu",                // other ancient/liturgical
            "zh", "ja", "ko",                          // CJK
            "ru", "uk",                                // Cyrillic
        ]
        for lang in languages {
            let primary = lang.rawValue.split(separator: "-", maxSplits: 1).first.map(String.init)
                ?? lang.rawValue
            if tesseractStrong.contains(primary) { return true }
        }
        return false
    }

    public func convert(
        pdfURL: URL,
        outputURL: URL,
        options: Options = Options(),
        progress: ProgressHandler? = nil
    ) async throws {
        // Mutable so we can periodically reload to drain PDFKit's
        // internal page cache. PDFKit `PDFDocument` lazily caches
        // rendered page representations; on a 600-page book that
        // cache pushes resident memory into the GB range. Dropping
        // and re-loading from URL is the only public way to flush.
        var pdf = try loader.load(pdfURL)
        let totalPages = pdf.pageCount
        // Reload every N pages. 25 is the empirical sweet spot —
        // small enough that PDFKit's per-page cache stays bounded
        // across long books, large enough that the re-parse cost
        // (~50ms per reload on a 600-page book) is amortized.
        let pdfReloadInterval = 25
        let renderer = PDFRenderer(dpi: options.dpi)
        let hints = OCRHints(languages: options.languages, quality: options.ocrQuality)

        let title = pdf.title ?? pdfURL.deletingPathExtension().lastPathComponent
        let language = options.languages.first ?? .en

        // Where per-page PNG renders go. Two modes:
        //   * Debug on  → `<basename>.humanist-debug/` next to the
        //                 EPUB. PNGs + log accumulate there so the
        //                 user can inspect after a bad conversion;
        //                 one folder per book is easy to delete.
        //   * Debug off → a fresh temp directory. Cleaned up at the
        //                 end of conversion (and reaped by macOS if
        //                 we crash). The source folder gets just the
        //                 .epub — important at bulk scale.
        let stagingDir: URL
        let stagingIsTemp: Bool
        if options.emitDebugLog {
            stagingDir = outputURL.deletingPathExtension()
                .appendingPathExtension("humanist-debug")
            stagingIsTemp = false
        } else {
            stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("Humanist-staging-\(UUID().uuidString)", isDirectory: true)
            stagingIsTemp = true
        }
        try? FileManager.default.createDirectory(
            at: stagingDir, withIntermediateDirectories: true
        )
        // Always clean up temp on the way out, success or failure.
        defer {
            if stagingIsTemp {
                try? FileManager.default.removeItem(at: stagingDir)
            }
        }

        // Pass 1 — for each page:
        //   a. Extract the embedded text layer (cheap; PDFKit access).
        //   b. Score its quality.
        //   c. Branch:
        //        - .trust  → skip Vision entirely; emit observations
        //                    synthesized from embedded lines.
        //        - .reocr → render + Vision OCR, then gap-fill any lines
        //                    Vision missed using whatever embedded text
        //                    exists.
        var pageResults: [PageObservations] = []
        pageResults.reserveCapacity(pdf.pageCount)
        var extractorDiagnostics: [Int: EmbeddedTextExtractor.Diagnostics] = [:]
        var qualityScores: [Int: EmbeddedTextQualityScorer.Score] = [:]
        // Page index → sidecar/Surya error message when layout failed.
        // Surfaced in the debug log so silent layout failures aren't
        // invisible (they explain why a page reverts to heuristic reflow).
        var layoutErrors: [Int: String] = [:]
        // Page index → trail of OCR fallbacks. Non-empty when the
        // primary engine threw and we recovered via lower-DPI retry
        // or Vision fallback. Lets the user see which pages got
        // degraded treatment in high-accuracy mode.
        var ocrErrors: [Int: String] = [:]
        // Page index → figures extracted from `.picture` / `.formula`
        // regions on that page. Built during pass 1 because we need
        // the rendered page CGImage; consumed by the reflow pass to
        // emit `Block.figure` and by EPUBBuilder to write
        // OEBPS/images/* asset bytes.
        var figureExtractionsByPage: [Int: [FigureExtractor.ExtractedFigure]] = [:]
        let figureExtractor = FigureExtractor()
        // (pageIdx, regionIdx) → Surya-derived table rows. Built
        // during pass 1 (sidecar requires the cropped page image).
        // Reflow consumes this; when no entry is present for a
        // `.table` region, reflow falls back to `TableHeuristic`.
        var tableExtractionsByKey: [CaptionAssociator.PageRegionKey: [[TableCell]]] = [:]

        // Cloud-mode engines, constructed once per conversion and
        // shared across pages. Nil unless `processingMode == .cloud`
        // AND the relevant per-feature toggle is on AND an API key
        // is configured. The cascade falls back to local-only when
        // any of those conditions fail.
        let claudeBudget = ClaudeCallBudget(cap: options.perBookCallCap)
        let claudeOCREngine: ClaudeOCREngine? = Self.makeClaudeOCREngine(
            options: options, budget: claudeBudget
        )

        for i in 0..<totalPages {
            try Task.checkCancellation()

            // Periodic reload to drain PDFKit's per-page cache. The
            // old document deallocates here, taking its accumulated
            // rendered-page representations with it. Skip i==0 so we
            // don't re-load on the first iteration.
            if i > 0 && i % pdfReloadInterval == 0 {
                pdf = try loader.load(pdfURL)
            }

            // Sync prep: embedded extraction + quality scoring. Wrap
            // in autoreleasepool so PDFKit/CoreGraphics NSObject
            // temporaries (PDFPage instances, NSStrings from text
            // extraction) drain at the closure boundary instead of
            // piling up on the convert task's outer pool until the
            // entire conversion ends.
            let (extracted, quality) = autoreleasepool { () -> ((lines: [EmbeddedTextExtractor.Line], diagnostics: EmbeddedTextExtractor.Diagnostics), EmbeddedTextQualityScorer.Score) in
                let e = embeddedExtractor.extract(from: pdf, pageIndex: i)
                let combined = e.lines.map(\.text).joined(separator: " ")
                let q = qualityScorer.score(text: combined)
                return (e, q)
            }
            extractorDiagnostics[i] = extracted.diagnostics
            qualityScores[i] = quality

            var observations: [TextObservation]
            let pageBounds: CGSize
            let confidenceForProgress: Double
            var layoutForPage: [LayoutRegion]? = nil

            switch quality.verdict {
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
                // Render + savePNG: largest sync allocation in the
                // loop. CGContext + CFData buffers are CFType so ARC
                // handles release, but the dispatch infra around
                // CGImageDestination autoreleases NSURL/NSData
                // bridging objects.
                let pngURL = stagingDir.appendingPathComponent("page-\(i).png")
                let image: CGImage = try autoreleasepool {
                    let img = try renderer.renderPage(at: i, of: pdf)
                    Self.savePNG(img, to: pngURL)
                    return img
                }
                let pageEngine = selectEngine(
                    for: hints.languages,
                    preferSurya: options.useHighAccuracyOCR
                )
                let (result, ocrErrorTrail) = try await ocrPageWithFallback(
                    image: image, pdf: pdf, pageIndex: i,
                    initialDPI: options.dpi,
                    primaryEngine: pageEngine, hints: hints
                )
                if let trail = ocrErrorTrail {
                    ocrErrors[i] = trail
                }
                observations = gapFiller.fill(
                    visionObservations: result.observations,
                    embeddedLines: extracted.lines
                )
                pageBounds = CGSize(width: image.width, height: image.height)
                confidenceForProgress = result.meanConfidence

                // Phase 4: layout analysis with retry-at-lower-DPI on
                // sidecar buffer-overflow errors. See
                // `analyzeLayoutWithRetry` for the strategy.
                if layoutAnalyzer != nil {
                    let outcome = await analyzeLayoutWithRetry(
                        pdf: pdf,
                        pageIndex: i,
                        initialDPI: options.dpi,
                        initialPNGURL: pngURL,
                        initialPageBounds: pageBounds,
                        stagingDir: stagingDir
                    )
                    layoutForPage = outcome.layout
                    if let err = outcome.error {
                        layoutErrors[i] = err
                    }
                }

                // Phase 4.5: per-region cascade. Vision → Surya
                // (whole-page re-OCR, region-by-region replacement) →
                // Tesseract (per-region crop). Skipped when the user
                // already forced Surya for the whole page (no point
                // re-OCRing what's already Surya output) or when
                // there's no layout to localize problems.
                //
                // Phase 2 dispatch on `processingMode`: `.privateLocal`
                // takes the existing local-only path; `.cloud` will
                // route the high-quality tier to Claude in Phase 3.
                // For now the two arms are identical so behavior is
                // unchanged regardless of mode.
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
                        // Phase 3: Claude wired in as the cascade's
                        // final tier (after Vision → Surya →
                        // Tesseract). Engine is non-nil only when the
                        // user has Cloud mode on, the hard-region-OCR
                        // toggle on, and an API key configured —
                        // otherwise the cascade behaves identically
                        // to `.privateLocal`.
                        //
                        // Spike-only: `disableLocalCascadeEscalation`
                        // pulls Surya + Tesseract out of the cascade
                        // AND tells the cascade to feed every region
                        // to Claude unconditionally (`forceClaudeOnAllRegions`).
                        // Layout still runs — we still need regions
                        // to crop for Claude. Production never sets
                        // this combination.
                        let cascadeSurya = options.disableLocalCascadeEscalation
                            ? nil : suryaEngine
                        let cascadeTess = options.disableLocalCascadeEscalation
                            ? nil : tesseractEngine
                        observations = await RegionCascade.run(
                            observations: observations,
                            regions: regions,
                            pageImage: image,
                            hints: hints,
                            suryaEngine: cascadeSurya,
                            tesseractEngine: cascadeTess,
                            claudeEngine: claudeOCREngine,
                            forceClaudeOnAllRegions: options.disableLocalCascadeEscalation
                        )
                    }
                }

                // Phase 6: extract figures (.picture, .formula) from
                // the rendered page so the reflow can emit
                // `Block.figure` and the EPUB writer can embed the
                // bytes. Done here because the page CGImage is only
                // alive during this loop iteration.
                if let regions = layoutForPage, !regions.isEmpty {
                    let figures = figureExtractor.extract(
                        pageIndex: i, regions: regions, pageImage: image
                    )
                    if !figures.isEmpty {
                        figureExtractionsByPage[i] = figures
                    }
                }

                // Phase 6 (Path A): for each `.table` region, run
                // Surya's table-structure model on a cropped image
                // and map this page's OCR observations onto cells.
                // Skipped when the sidecar isn't available; reflow
                // falls back to `TableHeuristic` for those regions.
                //
                // Phase 2 dispatch: `.privateLocal` uses the Surya
                // table-rec model; `.cloud` will route to a future
                // `ClaudeTableExtractor` (Sonnet) in Phase 5 when
                // `AISettings.cloudFeatures.tableExtraction` is on.
                // Today both arms are identical.
                if let regions = layoutForPage {
                    switch options.processingMode {
                    case .privateLocal:
                        if let tableExtractor {
                            for (regionIdx, region) in regions.enumerated()
                            where region.kind == .table {
                                if let rows = await tableExtractor.extract(
                                    pageImage: image,
                                    regionBox: region.box,
                                    observations: observations,
                                    stagingDir: stagingDir,
                                    pageIndex: i,
                                    regionIndex: regionIdx
                                ) {
                                    let key = CaptionAssociator.PageRegionKey(
                                        pageIndex: i, regionIndex: regionIdx
                                    )
                                    tableExtractionsByKey[key] = rows
                                }
                            }
                        }
                    case .cloud:
                        // TODO Phase 5: route through ClaudeTableExtractor.
                        // Falls back to Surya path when Claude declines.
                        if let tableExtractor {
                            for (regionIdx, region) in regions.enumerated()
                            where region.kind == .table {
                                if let rows = await tableExtractor.extract(
                                    pageImage: image,
                                    regionBox: region.box,
                                    observations: observations,
                                    stagingDir: stagingDir,
                                    pageIndex: i,
                                    regionIndex: regionIdx
                                ) {
                                    let key = CaptionAssociator.PageRegionKey(
                                        pageIndex: i, regionIndex: regionIdx
                                    )
                                    tableExtractionsByKey[key] = rows
                                }
                            }
                        }
                    }
                }

                // No per-page PNG cleanup — the staging dir's lifecycle
                // (temp removed in `defer`, debug folder kept) handles
                // it as a single batch.
            }

            pageResults.append(PageObservations(
                pageIndex: i,
                pageBounds: pageBounds,
                observations: observations,
                layoutRegions: layoutForPage
            ))
            progress?(Progress(
                totalPages: totalPages,
                completedPages: i + 1,
                currentPageMeanConfidence: confidenceForProgress
            ))

            // Yield gives the runtime a chance to drain any pool
            // accumulated by the awaited Vision/Surya work above and
            // lets cancellation/UI updates propagate. Without this,
            // long-running convert tasks hold autoreleased temporaries
            // (Vision NSObject results, dispatch-bridged NSData) for
            // the entire conversion.
            await Task.yield()
        }

        // Build caption associations once across the whole book — the
        // orientation (caption-above vs caption-below) is decided
        // book-wide and locked, so we have to see all pages first.
        let regionsByPage: [Int: [LayoutRegion]] = pageResults.reduce(into: [:]) {
            $0[$1.pageIndex] = $1.layoutRegions ?? []
        }
        let captionAssociations = CaptionAssociator.associate(
            regionsByPage: regionsByPage
        )

        // Pass 2 — reflow (and optionally a debug log of every observation's fate).
        let reflowed: ReflowOutput
        if options.emitDebugLog {
            // Log lives in the same `humanist-debug/` folder as the
            // PNGs so all artifacts for one book stay together.
            let logURL = stagingDir.appendingPathComponent("log.txt")
            reflowed = Self.reflow(
                pageResults: pageResults,
                figureExtractions: figureExtractionsByPage,
                tableExtractions: tableExtractionsByKey,
                captionAssociations: captionAssociations,
                debugLogURL: logURL,
                extractorDiagnostics: extractorDiagnostics,
                qualityScores: qualityScores,
                layoutErrors: layoutErrors,
                ocrErrors: ocrErrors
            )
        } else {
            reflowed = Self.reflow(
                pageResults: pageResults,
                figureExtractions: figureExtractionsByPage,
                tableExtractions: tableExtractionsByKey,
                captionAssociations: captionAssociations
            )
        }

        // Phase 1 of structured-document detection: split the flat
        // block stream into chapters at every level-1 heading.
        // Footnotes, page anchors, and figure assets are distributed
        // to the chapter they belong to so EPUB readers see a real
        // multi-chapter navigation tree.
        let chapters = ChapterSplitter.split(
            blocks: reflowed.blocks,
            footnotes: reflowed.footnotes,
            pageAnchors: reflowed.pageAnchors,
            figureAssets: reflowed.figureAssets,
            bookFallbackTitle: title
        )
        let book = Book(
            title: title,
            language: language,
            chapters: chapters
        )

        try EPUBBuilder().write(book: book, to: outputURL)
    }

    /// Result of `reflow` — body block stream + chapter-level
    /// footnotes that body runs reference via `InlineRun.noterefId`,
    /// + page-boundary anchors emitted into the block stream so the
    /// editor can sync preview scroll with PDF page (Phase 7.D),
    /// + figure assets referenced by `Block.figure` blocks (Phase 6).
    public struct ReflowOutput: Sendable, Equatable {
        public let blocks: [Block]
        public let footnotes: [Footnote]
        public let pageAnchors: [PageAnchor]
        public let figureAssets: [FigureAsset]
        public init(
            blocks: [Block],
            footnotes: [Footnote],
            pageAnchors: [PageAnchor] = [],
            figureAssets: [FigureAsset] = []
        ) {
            self.blocks = blocks
            self.footnotes = footnotes
            self.pageAnchors = pageAnchors
            self.figureAssets = figureAssets
        }
    }

    /// Convert per-page observations into a clean block stream.
    ///
    /// If any page has Surya layout regions, the region-aware reflow
    /// path runs (per-region body text, drops H/F/footnote regions
    /// structurally, uses Surya's reading order across columns).
    /// Pages without regions fall back through the heuristic
    /// HeaderFooterClassifier + ParagraphReflow path.
    ///
    /// Visible for testing.
    static func reflow(
        pageResults: [PageObservations],
        figureExtractions: [Int: [FigureExtractor.ExtractedFigure]] = [:],
        tableExtractions: [CaptionAssociator.PageRegionKey: [[TableCell]]] = [:],
        captionAssociations: CaptionAssociator.Associations = CaptionAssociator.Associations(
            captionByFigure: [:], orientation: .below
        ),
        debugLogURL: URL? = nil,
        extractorDiagnostics: [Int: EmbeddedTextExtractor.Diagnostics] = [:],
        qualityScores: [Int: EmbeddedTextQualityScorer.Score] = [:],
        layoutErrors: [Int: String] = [:],
        ocrErrors: [Int: String] = [:]
    ) -> ReflowOutput {
        let hasAnyLayout = pageResults.contains { ($0.layoutRegions?.isEmpty == false) }

        let merged: [Block]
        let footnotes: [Footnote]
        let pageAnchors: [PageAnchor]
        let figureAssets: [FigureAsset]
        let classification: HeaderFooterClassifier.Result

        if hasAnyLayout {
            // Layout path. We still run the H/F classifier so the debug
            // log can show what *would* have been dropped, but the
            // region-aware reflow makes its own structural decisions.
            classification = HeaderFooterClassifier().classifyWithReasons(pageResults)
            let result = RegionAwareReflow.reflow(
                pageResults: pageResults,
                figureExtractions: figureExtractions,
                tableExtractions: tableExtractions,
                captionAssociations: captionAssociations
            )
            merged = result.blocks
            footnotes = result.footnotes
            pageAnchors = result.pageAnchors
            figureAssets = result.figureAssets
        } else {
            // Heuristic-only path (Phase 1.5 behavior). No layout
            // regions means no footnote regions, so no popups either.
            classification = HeaderFooterClassifier().classifyWithReasons(pageResults)
            let drop = classification.dropSet
            let reflower = ParagraphReflow()

            var blocks: [Block] = []
            for page in pageResults {
                let kept = page.observations.enumerated().compactMap { (idx, obs) -> TextObservation? in
                    let key = ObservationKey(pageIndex: page.pageIndex, observationIndex: idx)
                    return drop.contains(key) ? nil : obs
                }
                blocks.append(contentsOf: reflower.reflow(kept))
            }
            merged = Self.bridgeBoundaries(blocks)
            footnotes = []
            pageAnchors = []
            figureAssets = []
        }

        if let debugLogURL {
            try? writeDebugLog(
                pages: pageResults,
                classification: classification,
                blocks: merged,
                extractorDiagnostics: extractorDiagnostics,
                qualityScores: qualityScores,
                layoutErrors: layoutErrors,
                ocrErrors: ocrErrors,
                footnotes: footnotes,
                to: debugLogURL
            )
        }
        return ReflowOutput(
            blocks: merged,
            footnotes: footnotes,
            pageAnchors: pageAnchors,
            figureAssets: figureAssets
        )
    }

    /// Save a CGImage as PNG to the given URL. Used by the debug-log
    /// path so we can visually inspect what Vision was actually fed.
    /// Silently no-ops on failure — debug aid, not load-bearing.
    private static func savePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
    }

    private static func writeDebugLog(
        pages: [PageObservations],
        classification: HeaderFooterClassifier.Result,
        blocks: [Block],
        extractorDiagnostics: [Int: EmbeddedTextExtractor.Diagnostics],
        qualityScores: [Int: EmbeddedTextQualityScorer.Score],
        layoutErrors: [Int: String],
        ocrErrors: [Int: String],
        footnotes: [Footnote],
        to url: URL
    ) throws {
        var out = ""
        out += "Humanist debug log\n"
        out += "==================\n"
        out += "pages: \(pages.count)\n"
        out += "blocks emitted: \(blocks.count)\n"
        out += "observations dropped: \(classification.dropSet.count)\n\n"

        if !qualityScores.isEmpty {
            out += "EMBEDDED TEXT QUALITY (per page)\n"
            out += "format: page: verdict combined=N.NN  mojibake=N.NN  singleChar=N.NN  langConf=N.NN  lang=XX  chars=N words=N\n\n"
            for pageIdx in qualityScores.keys.sorted() {
                guard let q = qualityScores[pageIdx] else { continue }
                out += String(
                    format: "Page %d: %-5@ combined=%.2f  mojibake=%.2f  singleChar=%.2f  langConf=%.2f  lang=%@  chars=%d words=%d\n",
                    pageIdx, q.verdict.rawValue,
                    q.combined, q.mojibakeRatio, q.singleCharWordRatio, q.languageConfidence,
                    q.dominantLanguage ?? "—", q.totalCharCount, q.totalWordCount
                )
            }
            out += "\n"
        }

        if !extractorDiagnostics.isEmpty {
            out += "EMBEDDED TEXT EXTRACTOR DIAGNOSTICS\n"
            out += "format: page: pageStringChars=N selectionsByLine=N kept=N (fallback used? kept=N)\n\n"
            for pageIdx in extractorDiagnostics.keys.sorted() {
                guard let d = extractorDiagnostics[pageIdx] else { continue }
                let fallback = d.characterFallbackUsed
                    ? " | char-fallback used, kept=\(d.characterFallbackKept)"
                    : ""
                out += "Page \(pageIdx): pageStringChars=\(d.pageStringCharCount) " +
                    "selectionsByLine=\(d.selectionByLineCount) kept=\(d.selectionByLineKept)\(fallback)\n"
            }
            out += "\n"
        }

        if !layoutErrors.isEmpty {
            out += "LAYOUT ANALYZER ERRORS\n"
            out += "format: page: error message (Surya/sidecar failure → page fell back to heuristic reflow)\n\n"
            for pageIdx in layoutErrors.keys.sorted() {
                let msg = layoutErrors[pageIdx] ?? ""
                out += "Page \(pageIdx): \(msg)\n"
            }
            out += "\n"
        }

        if !ocrErrors.isEmpty {
            out += "OCR FALLBACK TRAILS\n"
            out += "format: page: trail (primary engine failed → action taken)\n"
            out += "  These pages got degraded OCR: lower-DPI retry of the primary,\n"
            out += "  Vision fallback, or empty result if everything failed.\n\n"
            for pageIdx in ocrErrors.keys.sorted() {
                let msg = ocrErrors[pageIdx] ?? ""
                out += "Page \(pageIdx): \(msg)\n"
            }
            out += "\n"
        }

        let parsedByPage = RegionAwareReflow.lastFootnotesPerPage
        if !parsedByPage.isEmpty || !footnotes.isEmpty {
            out += "FOOTNOTES (per page, parsed from .footnote regions)\n"
            out += "format: page/marker id=ID  body excerpt\n\n"
            for pageIdx in parsedByPage.keys.sorted() {
                let parsed = parsedByPage[pageIdx] ?? []
                for fn in parsed {
                    let excerpt = fn.body.count > 120
                        ? String(fn.body.prefix(120)) + "…"
                        : fn.body
                    out += "Page \(pageIdx)/\(fn.marker)  id=\(fn.id)  \(excerpt)\n"
                }
            }
            out += "\nlinked into chapter: \(footnotes.count) footnote(s)\n\n"
        }

        // Heuristic footnote reclassifications — Surya tagged the
        // region as `.text` but our marker / position / gap heuristic
        // promoted it to `.footnote`. Visible here so we can see what
        // fired (and didn't) on a given PDF and tune thresholds.
        let reclasByPage = RegionAwareReflow.lastReclassificationsPerPage
        if !reclasByPage.isEmpty {
            out += "FOOTNOTE RECLASSIFICATIONS (heuristic: marker + bottom-half + gap)\n"
            out += "format: page/regionIdx originalKind → newKind  excerpt\n"
            out += "         signals: …\n\n"
            for pageIdx in reclasByPage.keys.sorted() {
                for r in reclasByPage[pageIdx] ?? [] {
                    out += "Page \(pageIdx)/region\(r.regionIndex)  \(r.originalKind) → \(r.newKind)  \"\(r.firstLineExcerpt)\"\n"
                    out += "   signals: \(r.signals.joined(separator: ", "))\n"
                }
            }
            out += "\n"
        }

        // Header / footer reclassifications — Surya missed the
        // pageHeader/pageFooter label and tagged the region as
        // `.text`; the position + size + brevity heuristic dropped
        // it from the body stream.
        let hfByPage = RegionAwareReflow.lastHFReclassificationsPerPage
        if !hfByPage.isEmpty {
            out += "HEADER/FOOTER RECLASSIFICATIONS (heuristic: extreme zone + short region + ≤100 chars)\n"
            out += "format: page/regionIdx originalKind → newKind  excerpt\n"
            out += "         signals: …\n\n"
            for pageIdx in hfByPage.keys.sorted() {
                for r in hfByPage[pageIdx] ?? [] {
                    out += "Page \(pageIdx)/region\(r.regionIndex)  \(r.originalKind) → \(r.newKind)  \"\(r.firstLineExcerpt)\"\n"
                    out += "   signals: \(r.signals.joined(separator: ", "))\n"
                }
            }
            out += "\n"
        }

        // Cross-page recurrence decisions — `.text` regions in the
        // top zone classified as either `.pageHeader` (recurring
        // running heads) or `.sectionHeader` (unique chapter titles).
        let crossPageByPage = RegionAwareReflow.lastCrossPageDecisionsPerPage
        if !crossPageByPage.isEmpty {
            out += "CROSS-PAGE TOP-REGION CLASSIFICATION (recurrence ≥3 pages → pageHeader, else sectionHeader)\n"
            out += "format: page/regionIdx originalKind → newKind  excerpt  normalized=\"…\"  pages=N\n\n"
            for pageIdx in crossPageByPage.keys.sorted() {
                for d in crossPageByPage[pageIdx] ?? [] {
                    out += "Page \(pageIdx)/region\(d.regionIndex)  \(d.originalKind) → \(d.newKind)  \"\(d.firstLineExcerpt)\"  normalized=\"\(d.normalizedText)\"  pages=\(d.recurrenceCount)\n"
                }
            }
            out += "\n"
        }

        // Region splits — Surya merged body + footnote into a single
        // `.text` region; we detected an internal vertical gap with
        // a footnote marker on the lower side and split it in two.
        let splitsByPage = RegionAwareReflow.lastRegionSplitsPerPage
        if !splitsByPage.isEmpty {
            out += "REGION SPLITS (heuristic: large internal gap + footnote marker on lower side)\n"
            out += "format: page/originalRegionIdx upperKind/lowerKind  excerpt  gap=N.NNN > 2.5×medianH=N.NNN\n\n"
            for pageIdx in splitsByPage.keys.sorted() {
                for s in splitsByPage[pageIdx] ?? [] {
                    out += String(
                        format: "Page %d/region%d  %@/%@  \"%@\"  gap=%.3f > 2.5×medianH=%.3f\n",
                        pageIdx, s.originalRegionIndex, s.upperKind, s.lowerKind,
                        s.footnoteExcerpt, s.gap, s.medianLineHeight
                    )
                }
            }
            out += "\n"
        }

        // Heading reading-order promotions — Surya tagged the region
        // as a heading correctly but ordered it after body content;
        // we moved it to the front because it was visually above all
        // body on the page.
        let promotionsByPage = RegionAwareReflow.lastHeadingPromotionsPerPage
        if !promotionsByPage.isEmpty {
            out += "HEADING READING-ORDER PROMOTIONS (heuristic: heading visually above all body)\n"
            out += "format: page/regionIdx kind  excerpt  oldOrder → newOrder  midY=N.NN > topBodyMidY=N.NN\n\n"
            for pageIdx in promotionsByPage.keys.sorted() {
                for p in promotionsByPage[pageIdx] ?? [] {
                    out += String(
                        format: "Page %d/region%d  %@  \"%@\"  %d → %d  midY=%.3f > topBodyMidY=%.3f\n",
                        pageIdx, p.regionIndex, p.kind, p.firstLineExcerpt,
                        p.oldReadingOrder, p.newReadingOrder,
                        p.headingMidY, p.topBodyMidY
                    )
                }
            }
            out += "\n"
        }

        // Surya layout regions per page — when Phase 4 is active.
        let pagesWithLayout = pages.filter { ($0.layoutRegions?.isEmpty == false) }
        if !pagesWithLayout.isEmpty {
            out += "LAYOUT REGIONS (Surya, per page in reading order)\n"
            out += "format: page/idx pos=N kind=K box=[x, y, w, h] conf=N.NN\n\n"
            for page in pages {
                guard let regions = page.layoutRegions, !regions.isEmpty else { continue }
                out += "--- Page \(page.pageIndex) — \(regions.count) regions\n"
                let sorted = regions.sorted { a, b in
                    switch (a.readingOrder, b.readingOrder) {
                    case let (x, y) where x >= 0 && y >= 0: return x < y
                    case (let x, _) where x >= 0:           return true
                    case (_, let y) where y >= 0:           return false
                    default:                                 return false
                    }
                }
                for (idx, r) in sorted.enumerated() {
                    let b = r.box
                    out += String(
                        format: "%d/%-3d pos=%-3d kind=%-14@ box=[%.3f, %.3f, %.3f, %.3f] conf=%.2f\n",
                        page.pageIndex, idx, r.readingOrder, r.kind.rawValue,
                        b.minX, b.minY, b.width, b.height, r.confidence
                    )
                }
                out += "\n"
            }
        }

        out += "OBSERVATIONS (per page)\n"
        out += "format: [FATE] page/idx src (x, y, w, h) conf=N.NN region=POS:KIND | text\n"
        out += "  src = v (Vision), t (Tesseract), s (Surya), e (embedded PDF text layer)\n"
        out += "  region = which Surya region the observation was attributed to (RegionAwareReflow only)\n\n"
        for page in pages {
            let visionCount    = page.observations.filter { $0.source == .vision }.count
            let tesseractCount = page.observations.filter { $0.source == .tesseract }.count
            let suryaCount     = page.observations.filter { $0.source == .surya }.count
            let embeddedCount  = page.observations.filter { $0.source == .embedded }.count
            out += "--- Page \(page.pageIndex) — \(page.observations.count) observations " +
                "(\(visionCount) Vision, \(tesseractCount) Tesseract, " +
                "\(suryaCount) Surya, \(embeddedCount) embedded)\n"
            for (i, obs) in page.observations.enumerated() {
                let key = ObservationKey(pageIndex: page.pageIndex, observationIndex: i)
                let fate: String
                if let reason = classification.reasons[key] {
                    fate = "DROP \(reason.rawValue)"
                } else if classification.dropSet.contains(key) {
                    fate = "DROP unknown"
                } else {
                    fate = "KEEP"
                }
                let b = obs.box
                let src: String
                switch obs.source {
                case .vision:    src = "v"
                case .tesseract: src = "t"
                case .surya:     src = "s"
                case .embedded:  src = "e"
                case .claude:    src = "c"
                }
                let regionInfo: String
                if let attr = RegionAwareReflow.lastAttributions[key] {
                    regionInfo = " region=\(attr.regionReadingOrder):\(attr.regionKind)"
                } else if pages.contains(where: { ($0.layoutRegions?.isEmpty == false) }) {
                    regionInfo = " region=UNASSIGNED"
                } else {
                    regionInfo = ""
                }
                out += String(
                    format: "[%@] %d/%-3d %@ (%.3f, %.3f, %.3f, %.3f) conf=%.2f%@ | %@\n",
                    fate, page.pageIndex, i, src,
                    b.minX, b.minY, b.width, b.height,
                    obs.confidence,
                    regionInfo,
                    obs.text.replacingOccurrences(of: "\n", with: " ⏎ ")
                )
            }
            out += "\n"
        }

        out += "BLOCKS (post-reflow + bridging)\n\n"
        for (i, block) in blocks.enumerated() {
            switch block {
            case .heading(let level, let runs):
                out += "[\(i)] H\(level): \(runs.map(\.text).joined())\n"
            case .paragraph(let runs):
                out += "[\(i)] P: \(runs.map(\.text).joined())\n"
            case .anchor(let id, let label):
                out += "[\(i)] ANCHOR id=\(id) label=\(label)\n"
            case .figure(let assetId, let alt, let caption):
                let captionText = caption.map(\.text).joined()
                out += "[\(i)] FIGURE asset=\(assetId) alt=\"\(alt)\""
                if !captionText.isEmpty {
                    out += " caption=\"\(captionText)\""
                }
                out += "\n"
            case .table(let rows, let caption):
                let captionText = caption.map(\.text).joined()
                let colCount = rows.first?.count ?? 0
                out += "[\(i)] TABLE rows=\(rows.count) cols=\(colCount)"
                if !captionText.isEmpty {
                    out += " caption=\"\(captionText)\""
                }
                out += "\n"
            }
            out += "\n"
        }

        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Merge adjacent paragraphs that should not have been split. Two
    /// cases handled:
    ///
    ///   1. **Soft hyphen across boundaries** — first paragraph ends in
    ///      `letter-`, second starts with a lowercase letter
    ///      → join with the hyphen dropped (the "Mendelssohn" case).
    ///   2. **Mid-sentence break across boundaries** — first paragraph
    ///      doesn't end with a sentence terminator AND the second starts
    ///      with a lowercase letter → join with a space.
    ///
    /// Both fire across column transitions within a page and across page
    /// transitions. They're geometric blind spots — the per-column reflow
    /// can't see that the next column's first paragraph is actually a
    /// continuation of the previous column's last paragraph.
    ///
    /// Length guard on case 2 prevents accidentally swallowing short
    /// headings or labels into the previous paragraph.
    static func bridgeBoundaries(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        out.reserveCapacity(blocks.count)
        for block in blocks {
            // Anchors and figures aren't paragraphs and never bridge —
            // pass them through. Real cross-page bridging happens in
            // the lookback below, which steps past any trailing
            // anchors / figures to find the previous paragraph.
            if case .anchor = block {
                out.append(block)
                continue
            }
            if case .figure = block {
                out.append(block)
                continue
            }

            // Walk back over anchors and figures that landed at the
            // end of `out` (page-boundary markers / figures that
            // landed between two paragraphs that really should be
            // merged into one sentence).
            var prevIndex = out.count - 1
            while prevIndex >= 0, isBridgePassthrough(out[prevIndex]) {
                prevIndex -= 1
            }
            let prev: Block? = prevIndex >= 0 ? out[prevIndex] : nil

            guard case let .paragraph(runs) = block,
                  case let .paragraph(prevRuns) = prev,
                  let lastPrevText = prevRuns.last?.text,
                  let firstNewText = runs.first?.text,
                  let bridgeKind = bridgeKind(prev: prevRuns, prevTail: lastPrevText, nextHead: firstNewText)
            else {
                out.append(block)
                continue
            }

            let mergedTail: String
            switch bridgeKind {
            case .softHyphen:
                mergedTail = Dehyphenation.join(lastPrevText, firstNewText)
            case .midSentence:
                mergedTail = lastPrevText.trimmingCharacters(in: .whitespaces)
                    + " " + firstNewText.trimmingCharacters(in: .whitespaces)
            }

            var combinedRuns = prevRuns
            combinedRuns[combinedRuns.count - 1] = InlineRun(
                mergedTail, language: combinedRuns.last?.language
            )
            combinedRuns.append(contentsOf: runs.dropFirst())

            // Replace the previous paragraph in-place; anchors that
            // sat between it and the current paragraph stay where
            // they are (now positioned right after the merged text,
            // marking where the next page's distinct content starts).
            out[prevIndex] = .paragraph(runs: combinedRuns)
        }
        return out
    }

    /// Blocks the cross-paragraph bridging lookback walks past when
    /// finding the previous paragraph. Anchors are invisible
    /// page-boundary markers; figures and tables are visual / tabular
    /// content that don't participate in textual bridging. All three
    /// can sit between two paragraphs that legitimately want to
    /// merge into one sentence.
    private static func isBridgePassthrough(_ block: Block) -> Bool {
        switch block {
        case .anchor, .figure, .table: return true
        case .heading, .paragraph: return false
        }
    }

    private enum BridgeKind { case softHyphen, midSentence }

    private static func bridgeKind(
        prev: [InlineRun], prevTail: String, nextHead: String
    ) -> BridgeKind? {
        if Dehyphenation.shouldDehyphenate(lhs: prevTail, rhs: nextHead) {
            return .softHyphen
        }
        // Mid-sentence join: prev didn't end with a terminator, next
        // begins with a lowercase letter, prev paragraph is long enough
        // to plausibly be prose (not a heading or short label).
        let prevWhole = prev.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prevWhole.count >= 20 else { return nil }
        guard !endsWithSentenceTerminator(prevWhole) else { return nil }
        let nextHeadTrimmed = nextHead.trimmingCharacters(in: .whitespaces)
        guard let firstChar = nextHeadTrimmed.first,
              firstChar.isLetter, firstChar.isLowercase
        else { return nil }
        return .midSentence
    }

    /// Treat `.`, `?`, `!`, `…`, `;`, `:` (optionally followed by closing
    /// quotes/brackets) as sentence-ish terminators.
    private static func endsWithSentenceTerminator(_ s: String) -> Bool {
        var t = Substring(s)
        while let last = t.last, "\")]}”’»".contains(last) {
            t = t.dropLast()
        }
        guard let last = t.last else { return false }
        return ".?!;:\u{2026}".contains(last)
    }
}
