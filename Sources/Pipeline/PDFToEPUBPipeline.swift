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
        /// DPI used when `documentProfile.isLikelyScan == true`.
        /// Higher than the default `dpi` because scanned pages
        /// benefit from sharper raster input — Vision picks up
        /// thin diacritics and small footnote type that 400 DPI
        /// renders too aliased for.
        public var dpiForScans: CGFloat
        /// Pre-flight document profile, when one's available.
        /// Drives the adaptive DPI choice and whether the
        /// `PageImagePreprocessor` runs on rendered pages. Nil →
        /// defaults are used (no preprocessing, default DPI).
        public var documentProfile: DocumentProfile?
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
        /// Cloud-enhanced OCR mode: Vision is the primary engine,
        /// regions whose quality score falls below the cascade
        /// threshold escalate **straight to Sonnet** — Surya OCR
        /// and Tesseract are pulled out of the OCR role. Surya
        /// **layout** still runs (cheap pre-pass; load-bearing for
        /// the structural extractors — figures, tables, footnotes).
        /// Only fires when `processingMode == .cloud` and an API
        /// key is configured; in any other configuration the flag
        /// is inert and the cascade falls back to the standard
        /// shape.
        public var useCloudEnhancedOCR: Bool
        /// When true, bypass `EmbeddedTextQualityScorer` entirely and
        /// route every page through render + OCR + cascade. Use when
        /// a PDF carries a low-quality embedded text layer (typically
        /// the output of a previous bad OCR pass) that the scorer
        /// can mistake for legitimate prose. Slower but guaranteed
        /// to actually OCR. Driven by `AISettings.forceOCR`.
        public var forceOCR: Bool
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
        /// **Phase 2 hidden flag.** When true (and the gating below
        /// in `makeClaudePageOCREngine` is satisfied), every page is
        /// rendered, sent to Sonnet, and parsed back into structured
        /// blocks via `ClaudePageOCREngine` — bypassing Vision /
        /// Surya OCR / Tesseract / RegionAwareReflow. Surya layout +
        /// figure extraction + downstream chapter-splitting still
        /// run normally. Off by default; toggled by reading the
        /// `humanist.useClaudePageOCR` UserDefault in `JobRunner` so
        /// we can flip it via `defaults write` without rebuilding.
        /// Phase 3 will wire it into the user-visible "Claude OCR"
        /// toggle as the new default behavior.
        public var useClaudePageOCR: Bool

        public init(
            dpi: CGFloat = 400,
            dpiForScans: CGFloat = 600,
            documentProfile: DocumentProfile? = nil,
            languages: [BCP47] = [.en],
            ocrQuality: OCRHints.Quality = .accurate,
            emitDebugLog: Bool = false,
            useHighAccuracyOCR: Bool = false,
            useCloudEnhancedOCR: Bool = false,
            forceOCR: Bool = false,
            processingMode: ProcessingMode = .privateLocal,
            cloudFeatures: AISettings.CloudFeatures = AISettings.CloudFeatures(),
            perBookCallCap: Int = 200,
            anthropicAPIKeyProvider: @escaping @Sendable () -> String? = { nil },
            disableLocalCascadeEscalation: Bool = false,
            useClaudePageOCR: Bool = false
        ) {
            self.dpi = dpi
            self.dpiForScans = dpiForScans
            self.documentProfile = documentProfile
            self.languages = languages
            self.ocrQuality = ocrQuality
            self.emitDebugLog = emitDebugLog
            self.useHighAccuracyOCR = useHighAccuracyOCR
            self.useCloudEnhancedOCR = useCloudEnhancedOCR
            self.forceOCR = forceOCR
            self.processingMode = processingMode
            self.cloudFeatures = cloudFeatures
            self.perBookCallCap = perBookCallCap
            self.anthropicAPIKeyProvider = anthropicAPIKeyProvider
            self.disableLocalCascadeEscalation = disableLocalCascadeEscalation
            self.useClaudePageOCR = useClaudePageOCR
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

    /// Build the Cloud-mode post-OCR cleanup processor for one
    /// conversion. Same gating shape as `makeClaudeOCREngine` —
    /// `.cloud` mode + `postOCRCleanup` feature toggle + an API key
    /// must all be present, otherwise `nil` and the pipeline skips
    /// the cleanup pass entirely.
    static func makeClaudePostProcessor(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudePostProcessor? {
        guard options.processingMode == .cloud else { return nil }
        guard options.cloudFeatures.postOCRCleanup else { return nil }
        guard let key = options.anthropicAPIKeyProvider(),
              !key.isEmpty else { return nil }
        let client = AnthropicAPIClient(apiKeyProvider: { key })
        return ClaudePostProcessor(client: client, budget: budget)
    }

    /// Build the Cloud-mode TOC parser for one conversion.
    /// Same gating shape as the OCR engine and post-processor.
    static func makeClaudeTOCParser(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeTOCParser? {
        guard options.processingMode == .cloud else { return nil }
        guard options.cloudFeatures.tocParsing else { return nil }
        guard let key = options.anthropicAPIKeyProvider(),
              !key.isEmpty else { return nil }
        let client = AnthropicAPIClient(apiKeyProvider: { key })
        return ClaudeTOCParser(client: client, budget: budget)
    }

    /// Build the Cloud-mode chapter classifier for one conversion.
    /// Same gating shape as the other Cloud helpers.
    static func makeClaudeChapterClassifier(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeChapterClassifier? {
        guard options.processingMode == .cloud else { return nil }
        guard options.cloudFeatures.semanticClassification else { return nil }
        guard let key = options.anthropicAPIKeyProvider(),
              !key.isEmpty else { return nil }
        let client = AnthropicAPIClient(apiKeyProvider: { key })
        return ClaudeChapterClassifier(client: client, budget: budget)
    }

    /// Build the Cloud-mode table extractor for one conversion.
    /// Same gating shape as the other Cloud helpers — `.cloud` mode
    /// + `tableExtraction` feature toggle + an API key. When non-nil,
    /// the per-page loop tries Claude first on each `.table` region
    /// and falls back to the Surya path on nil (degenerate output,
    /// network or budget failure).
    static func makeClaudeTableExtractor(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeTableExtractor? {
        guard options.processingMode == .cloud else { return nil }
        guard options.cloudFeatures.tableExtraction else { return nil }
        guard let key = options.anthropicAPIKeyProvider(),
              !key.isEmpty else { return nil }
        let client = AnthropicAPIClient(apiKeyProvider: { key })
        return ClaudeTableExtractor(client: client, budget: budget)
    }

    /// Build the experimental "Claude does the page" engine. Returns
    /// nil unless the user opted in via `useClaudePageOCR`, the
    /// cascade's hard-region-OCR Cloud feature is enabled, the run is
    /// in Cloud mode, and an API key is configured. When non-nil, the
    /// per-page loop below skips Vision / cascade / region-aware
    /// reflow and uses Sonnet to produce structured XHTML directly.
    static func makeClaudePageOCREngine(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudePageOCREngine? {
        guard options.useClaudePageOCR else { return nil }
        guard options.processingMode == .cloud else { return nil }
        // Reuse the hard-region-OCR feature gate — same billing
        // surface, same per-book budget. We don't add a new
        // CloudFeatures bit until Phase 3 promotes this path to the
        // user-visible toggle.
        guard options.cloudFeatures.hardRegionOCR else { return nil }
        guard let key = options.anthropicAPIKeyProvider(),
              !key.isEmpty else { return nil }
        let client = AnthropicAPIClient(apiKeyProvider: { key })
        return ClaudePageOCREngine(client: client, budget: budget)
    }

    /// Output of `applyPostOCRCleanup`: the (possibly-rewritten)
    /// observations plus a trail of every correction the pass
    /// considered (accepted *and* rejected). The trail feeds
    /// `CorrectionTrail` so the editor can surface what Haiku changed.
    struct PostOCRCleanupOutcome {
        var observations: [TextObservation]
        var trailEntries: [CorrectionTrail.Entry]
    }

    /// Walk text-bearing layout regions, score the joined OCR text in
    /// each, and ask the post-processor to fix character-level errors
    /// where the score is low. Accepted corrections replace the
    /// region's observations with a single `.claude`-source
    /// observation spanning the region — same shape `ClaudeOCREngine`
    /// produces for the cascade. Rejected corrections (guardrail trip,
    /// budget exhausted, processor declined) leave the region intact.
    ///
    /// In `.vision` mode the page image is cropped per region and
    /// sent alongside the OCR text. A region whose crop comes back
    /// nil falls through silently (nothing to send) — the processor's
    /// own gate also catches this case.
    ///
    /// The returned `trailEntries` capture every region that **made
    /// it past the trigger gate** (i.e. Haiku actually saw it).
    /// Skipped regions (clean text, too short, budget exhausted, no
    /// network response) produce no trail entry — there's nothing
    /// for the editor to show on those.
    static func applyPostOCRCleanup(
        observations: [TextObservation],
        regions: [LayoutRegion],
        pageImage: CGImage,
        pageIndex: Int,
        hints: OCRHints,
        mode: ClaudePostProcessor.Mode,
        postProcessor: ClaudePostProcessor
    ) async -> PostOCRCleanupOutcome {
        var working = observations
        var trail: [CorrectionTrail.Entry] = []
        let modeKey = (mode == .vision) ? "vision" : "passages"
        let pageAnchor = RegionAwareReflow.anchorId(forPageIndex: pageIndex)

        for (regionIdx, region) in regions.enumerated() {
            // Only text-bearing regions. Captions, page numbers,
            // headers / footers fall under the post-processor's own
            // length floor, but skipping them up here is cheaper than
            // joining their text just to throw it out.
            guard Self.isCleanupCandidate(region: region) else { continue }
            let inRegion = RegionCascade.filter(
                observations: working, inRegion: region
            )
            guard !inRegion.isEmpty else { continue }
            // Join with newlines — same convention OCRResult.text
            // uses. Keeps multi-line regions human-readable for the
            // model and matches what the cascade itself produces
            // when Claude re-OCRs a region.
            let joined = inRegion.map(\.text)
                .joined(separator: "\n")

            // Crop only when we actually need the image — passages
            // mode skips this work entirely.
            let regionImage: CGImage? = mode == .vision
                ? RegionCascade.cropImage(pageImage, to: region.box)
                : nil

            guard let result = await postProcessor.correct(
                text: joined,
                languages: hints.languages,
                mode: mode,
                regionImage: regionImage
            ) else {
                continue
            }

            // Record the trail entry whether accepted or rejected.
            // `modelOutput` carries Haiku's raw suggestion (pre-
            // guardrail), so rejected entries surface the rejected
            // text in the editor panel. Users can manually apply if
            // they disagree with the guardrail's call.
            trail.append(CorrectionTrail.Entry(
                pageIndex: pageIndex,
                regionIndex: regionIdx,
                anchorId: pageAnchor,
                original: joined,
                suggested: result.modelOutput,
                accepted: result.accepted,
                rejectionReason: result.rejectionReason?.rawValue,
                mode: modeKey
            ))

            guard result.accepted else { continue }

            // Replace the region's observations with a single Claude-
            // sourced observation that covers the full region bbox.
            // Mirrors how `ClaudeOCREngine` packages its output.
            let replacement = TextObservation(
                text: result.corrected,
                confidence: 0.95,
                box: region.box,
                source: .claude
            )
            working = RegionCascade.replace(
                observations: working,
                inRegion: region,
                with: [replacement]
            )
        }
        return PostOCRCleanupOutcome(observations: working, trailEntries: trail)
    }

    /// Region kinds eligible for post-OCR cleanup. Body text is the
    /// primary case; `.footnote` is also worth correcting (footnotes
    /// often have the worst OCR because the type is small). Other
    /// kinds either don't carry prose worth correcting (`.picture`,
    /// `.table`, `.formula`) or are short enough that the processor's
    /// own length floor would skip them anyway (`.caption`,
    /// `.header`, `.footer`, `.pageNumber`, `.title`).
    static func isCleanupCandidate(region: LayoutRegion) -> Bool {
        switch region.kind {
        case .text, .footnote: return true
        default:               return false
        }
    }

    /// Apply `DictionaryCorrector` to the reflowed block stream.
    /// Walks each `.paragraph` / `.heading` block, joins its
    /// `InlineRun` text, runs the corrector, and writes the result
    /// back when the text actually changed.
    ///
    /// Multi-run blocks (paragraphs with explicit per-run language
    /// switches — Greek quotation in an English paragraph, etc.)
    /// are skipped to preserve their structure. Single-run blocks
    /// are the common case for OCR'd output.
    ///
    /// Runs **post-reflow** (after `RegionAwareReflow.reflow`
    /// returned its `[Block]` stream) so hyphenated line-breaks
    /// and cross-page paragraph continuations are already resolved
    /// — the corrector sees full words, not fragments. Putting
    /// this earlier in the pipeline (per-region, pre-reflow)
    /// produced fragment-correction bugs (`approxi-` → `approve`
    /// before reflow could join with `mation` from the next line).
    static func applyDictionaryToBlocks(
        _ blocks: [Block],
        corrector: DictionaryCorrector
    ) -> [Block] {
        return blocks.map { block in applyDictionaryToBlock(block, corrector: corrector) }
    }

    /// Per-block dispatch. Heading + paragraph go through the
    /// corrector; figure / table / anchor pass through unchanged.
    static func applyDictionaryToBlock(
        _ block: Block,
        corrector: DictionaryCorrector
    ) -> Block {
        switch block {
        case .paragraph(let runs):
            guard let corrected = correctedRun(runs, corrector: corrector)
            else { return block }
            return .paragraph(runs: [corrected])
        case .heading(let level, let runs):
            guard let corrected = correctedRun(runs, corrector: corrector)
            else { return block }
            return .heading(level: level, runs: [corrected])
        case .anchor, .figure, .table:
            return block
        }
    }

    /// Return a single corrected run when the input `runs` is a
    /// single-run block and the corrector changed something.
    /// Returns nil for multi-run blocks (preserve their structure)
    /// and for single-run blocks where no correction was needed.
    static func correctedRun(
        _ runs: [InlineRun],
        corrector: DictionaryCorrector
    ) -> InlineRun? {
        guard runs.count == 1 else { return nil }
        let original = runs[0].text
        let corrected = corrector.correct(original)
        guard corrected != original else { return nil }
        var newRun = runs[0]
        newRun.text = corrected
        return newRun
    }

    /// Run the chapter classifier across `chapters`, with a small
    /// concurrency cap so a 30-chapter book doesn't issue 30
    /// simultaneous Haiku requests. Each `classify` call internally
    /// gates on `ClaudeCallBudget`, so the cap is also a backstop.
    /// Returns a chapter list in the same order with `epubType`
    /// populated where Haiku produced a valid label.
    static func classifyChapters(
        chapters: [Chapter],
        classifier: ClaudeChapterClassifier
    ) async -> [Chapter] {
        let concurrency = 3
        // Indexed labels so the eventual array stays in input order
        // regardless of the order TaskGroup yields results.
        var labels: [Int: String?] = [:]
        await withTaskGroup(of: (Int, String?).self) { group in
            var nextIndex = 0
            var inFlight = 0
            // Seed the first batch.
            while nextIndex < chapters.count, inFlight < concurrency {
                let i = nextIndex
                let chapter = chapters[i]
                group.addTask {
                    (i, await classifier.classify(chapter: chapter))
                }
                nextIndex += 1
                inFlight += 1
            }
            // Drain + refill. As each classify task finishes, queue
            // up the next chapter to keep `concurrency` in flight.
            while let (i, label) = await group.next() {
                labels[i] = label
                inFlight -= 1
                if nextIndex < chapters.count {
                    let j = nextIndex
                    let chapter = chapters[j]
                    group.addTask {
                        (j, await classifier.classify(chapter: chapter))
                    }
                    nextIndex += 1
                    inFlight += 1
                }
            }
        }
        return chapters.enumerated().map { (i, chapter) in
            var c = chapter
            if let label = labels[i] ?? nil {
                c.epubType = label
            }
            return c
        }
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

    @discardableResult
    public func convert(
        pdfURL: URL,
        outputURL: URL,
        options: Options = Options(),
        progress: ProgressHandler? = nil
    ) async throws -> ConversionStats {
        let conversionStart = Date()
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
        // Adaptive DPI: scans get a higher render resolution because
        // Vision picks up thin diacritics and small footnote glyphs
        // that 400 DPI flattens. Born-digital pages use the default
        // since their internal vector data renders crisp at any DPI
        // and 600 just inflates the image without helping OCR.
        let useScansDPI = options.documentProfile?.isLikelyScan == true
        let effectiveDPI = useScansDPI ? options.dpiForScans : options.dpi
        let renderer = PDFRenderer(dpi: effectiveDPI)
        // Image preprocessing pipeline — only invoked on scan-likely
        // documents (born-digital text gets harmed by contrast /
        // sharpening; only scans benefit). Filter stack: levels
        // stretch, mild denoise, gentle unsharp mask.
        let pagePreprocessor = useScansDPI ? PageImagePreprocessor() : nil
        let hints = OCRHints(languages: options.languages, quality: options.ocrQuality)

        let title = pdf.title ?? pdfURL.deletingPathExtension().lastPathComponent
        let language = options.languages.first ?? .en

        // Per-page artifacts (PNGs, JSON checkpoints, debug log)
        // live alongside the source PDF in
        // `<basename>.humanist-staging/`. The directory persists
        // across crashes / cancels — that's load-bearing for
        // resume: the next conversion of the same source PDF
        // checks the staging dir for per-page checkpoints and
        // skips pages that already finished. Cleaned up on
        // **successful** completion only.
        //
        // When debug logging is on, the directory's name shifts to
        // `<basename>.humanist-debug/` so the user can locate the
        // logs more easily; both shapes work identically as
        // resume-staging dirs.
        let stagingDir: URL = options.emitDebugLog
            ? outputURL.deletingPathExtension()
                .appendingPathExtension("humanist-debug")
            : pdfURL.deletingPathExtension()
                .appendingPathExtension("humanist-staging")
        try? FileManager.default.createDirectory(
            at: stagingDir, withIntermediateDirectories: true
        )

        // Resume manager: validate the staging dir's manifest
        // matches the source PDF; if it doesn't (different file),
        // wipe the dir and start fresh. Otherwise the per-page
        // loop below skips pages with existing checkpoints.
        let resumeManager = ResumeManager(stagingDir: stagingDir)
        let sourceFingerprint = ResumeManager.fingerprint(of: pdfURL) ?? ""
        let existingManifest = resumeManager.readManifest()
        // Compute the *current* run's mode so we can compare against
        // the manifest. Mode mismatch invalidates the staging dir —
        // mixing cascade-shaped checkpoints (observations) with
        // page-ocr-shaped ones (blocks) would produce a chimera EPUB.
        let currentMode: String = options.useClaudePageOCR
            ? StagingManifest.Mode.pageOCR
            : StagingManifest.Mode.cascade
        let resumeAvailable: Bool
        if let m = existingManifest,
           m.sourceFingerprint == sourceFingerprint,
           m.totalPages == pdf.pageCount,
           m.schemaVersion == 1,
           m.effectiveMode == currentMode {
            resumeAvailable = true
        } else {
            // Mismatch (or no prior manifest) → start fresh.
            // Rebuild the staging dir from scratch so stale
            // checkpoints don't leak in.
            if existingManifest != nil {
                try? FileManager.default.removeItem(at: stagingDir)
                try? FileManager.default.createDirectory(
                    at: stagingDir, withIntermediateDirectories: true
                )
            }
            try? resumeManager.writeManifest(StagingManifest(
                sourceFingerprint: sourceFingerprint,
                totalPages: pdf.pageCount,
                mode: currentMode
            ))
            resumeAvailable = false
        }
        let alreadyDonePages = resumeAvailable
            ? resumeManager.completedPages() : Set<Int>()

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
        let claudePostProcessor: ClaudePostProcessor? = Self.makeClaudePostProcessor(
            options: options, budget: claudeBudget
        )
        let claudeTOCParser: ClaudeTOCParser? = Self.makeClaudeTOCParser(
            options: options, budget: claudeBudget
        )
        // Cloud Phase 5: Sonnet table-structure extractor. When
        // non-nil, the `.table` dispatch below tries Claude first
        // and falls back to the Surya path on nil (declined,
        // budget exhausted, parse failure).
        let claudeTableExtractor: ClaudeTableExtractor? = Self.makeClaudeTableExtractor(
            options: options, budget: claudeBudget
        )
        // Phase 2 hidden flag: end-to-end "Claude does the page".
        // When non-nil, the per-page loop below skips Vision / cascade
        // / region-aware reflow and uses Sonnet to produce structured
        // XHTML directly — see `makeClaudePageOCREngine` for gating.
        let claudePageEngine: ClaudePageOCREngine? = Self.makeClaudePageOCREngine(
            options: options, budget: claudeBudget
        )

        // Dictionary-match cleanup runs unconditionally — it's
        // free, fast, and gated on language-supported tokens
        // internally. Constructed once per conversion with the
        // document's primary language; per-region language hints
        // from NLR override that when available.
        let dictionaryCorrector = DictionaryCorrector(
            documentLanguage: options.documentProfile?.primaryLanguage
        )

        // Cloud Phase 6e: parse the printed table of contents up
        // front (one Haiku call, embedded text only). The result
        // is consumed after `ChapterSplitter` to override the
        // heuristic chapter titles. Runs in parallel with the
        // page-OCR loop — the result isn't needed until book
        // assembly. Returns nil on any failure path so the
        // pipeline degrades to heuristic titles unchanged.
        let parsedTOCTask: Task<ParsedTOC?, Never>? = claudeTOCParser.map { parser in
            Task.detached { await parser.parse(pdfURL: pdfURL) }
        }

        // Per-page record of which branch fired (trust vs reocr,
        // post-`forceOCR` override). Surfaced in the conversion
        // stats so the user can see "OCR ran on N of M pages."
        var verdictsByPage: [Int: EmbeddedTextQualityScorer.Verdict] = [:]

        // Accumulator for the post-OCR cleanup correction trail.
        // Empty when the cleanup feature is off or no regions
        // tripped the trigger gate. Written as a META-INF sidecar
        // when non-empty so the editor can surface what Haiku did.
        var correctionTrailEntries: [CorrectionTrail.Entry] = []

        // Phase 2 hidden flag accumulators. Populated only when
        // `claudePageEngine` is non-nil; consumed at the reflow step
        // below to bypass `RegionAwareReflow`. Page anchors mirror
        // the IDs `RegionAwareReflow` would have produced so the
        // editor's linked-navigation feature works identically.
        var claudePageBlocks: [Block] = []
        var claudePageFootnotes: [Footnote] = []
        var claudePageAnchors: [PageAnchor] = []
        // Phase 4b figure assets for the page-OCR path. Each
        // `.picture` / `.formula` region Surya finds is cropped from
        // the page image, registered with a sequential global asset
        // id, and a `Block.figure` is appended at the end of the
        // page's blocks. End-of-page placement is a known wart —
        // figures lose their reading-order context inside text. A
        // future pass could ask Sonnet to emit `<figure>` placeholders
        // and substitute by Y position. For now, "figures present
        // but at the end of the page" is the achievable improvement.
        var claudePageFigureAssets: [FigureAsset] = []
        var claudePageNextAssetIndex = 0

        for i in 0..<totalPages {
            try Task.checkCancellation()

            // Resume fast path: this page has a checkpoint on disk
            // from a prior (interrupted) run. Load it, restore the
            // accumulators, skip all the expensive per-page work.
            if alreadyDonePages.contains(i),
               let checkpoint = resumeManager.readCheckpoint(forPage: i) {
                // Page-OCR resume path: checkpoint stores the parsed
                // [Block] / [Footnote] slice from a prior Sonnet
                // call. Restore directly into the page-OCR
                // accumulators and skip the cascade-shaped
                // PageObservations append below. Figure assets get
                // fresh IDs (asset IDs aren't checkpointed because
                // they depend on document-order accumulation).
                if let blocks = checkpoint.pageBlocks {
                    let anchor = RegionAwareReflow.anchorId(forPageIndex: i)
                    claudePageBlocks.append(.anchor(
                        id: anchor, label: "Page \(i + 1)"
                    ))
                    claudePageAnchors.append(PageAnchor(
                        pdfPage: i, anchorId: anchor
                    ))
                    claudePageBlocks.append(contentsOf: blocks)
                    for fig in checkpoint.figures {
                        let (assetId, asset, figureBlock) =
                            buildPageOCRFigureAsset(
                                fig: fig,
                                index: claudePageNextAssetIndex
                            )
                        claudePageNextAssetIndex += 1
                        claudePageFigureAssets.append(asset)
                        claudePageBlocks.append(figureBlock)
                        _ = assetId
                    }
                    claudePageFootnotes.append(
                        contentsOf: checkpoint.pageFootnotes ?? []
                    )
                    progress?(Progress(
                        totalPages: totalPages,
                        completedPages: i + 1,
                        currentPageMeanConfidence: 1.0
                    ))
                    continue
                }
                let bounds = CGSize(
                    width: checkpoint.pageBoundsWidth,
                    height: checkpoint.pageBoundsHeight
                )
                pageResults.append(PageObservations(
                    pageIndex: i,
                    pageBounds: bounds,
                    observations: checkpoint.observations,
                    layoutRegions: checkpoint.layoutRegions
                ))
                // `regionsByPage` is derived from pageResults *after*
                // this loop completes — appending the PageObservations
                // above with `layoutRegions` set is enough; no
                // explicit per-page write needed here.
                if !checkpoint.figures.isEmpty {
                    figureExtractionsByPage[i] = checkpoint.figures
                }
                for (regionIdx, rows) in checkpoint.tableExtractionsByRegionIndex {
                    let key = CaptionAssociator.PageRegionKey(
                        pageIndex: i, regionIndex: regionIdx
                    )
                    tableExtractionsByKey[key] = rows
                }
                if let v = checkpoint.verdict.flatMap({
                    EmbeddedTextQualityScorer.Verdict(rawValue: $0)
                }) {
                    verdictsByPage[i] = v
                }
                correctionTrailEntries.append(
                    contentsOf: checkpoint.correctionTrailEntries
                )
                progress?(Progress(
                    totalPages: totalPages,
                    completedPages: i + 1,
                    currentPageMeanConfidence: 1.0
                ))
                continue
            }

            // Periodic reload to drain PDFKit's per-page cache. The
            // old document deallocates here, taking its accumulated
            // rendered-page representations with it. Skip i==0 so we
            // don't re-load on the first iteration.
            if i > 0 && i % pdfReloadInterval == 0 {
                pdf = try loader.load(pdfURL)
            }

            // Phase 2 hidden flag: end-to-end Claude page OCR. When
            // the engine is configured we skip the entire local
            // pipeline for this page (embedded text scoring, Vision,
            // Surya layout, cascade, post-OCR cleanup) and feed the
            // rendered page image straight to Sonnet. The result is
            // already a `[Block]` slice — appended to per-document
            // accumulators that bypass `RegionAwareReflow` after the
            // loop completes. Per-page failures are logged and the
            // page contributes only its anchor (so chapter splits
            // and page navigation still work).
            if let pageEngine = claudePageEngine {
                let renderer = PDFRenderer(dpi: options.dpi)
                let image = try renderer.renderPage(at: i, of: pdf)
                let pageBoundsCG = CGSize(
                    width: image.width, height: image.height
                )
                // Save PNG for the layout analyzer (Surya needs an
                // imageURL). Lives under the staging dir so it gets
                // cleaned up when the run completes successfully.
                let pngURL = stagingDir.appendingPathComponent(
                    String(format: "page-%05d.png", i)
                )
                Self.savePNG(image, to: pngURL)

                // Run Surya layout in parallel with the Sonnet call
                // so figure extraction doesn't add round-trip
                // latency. Surya is cheap (~1-2s/page); the Sonnet
                // call is the long pole, so we want them concurrent.
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

                let anchor = RegionAwareReflow.anchorId(forPageIndex: i)
                claudePageBlocks.append(.anchor(
                    id: anchor, label: "Page \(i + 1)"
                ))
                claudePageAnchors.append(PageAnchor(
                    pdfPage: i, anchorId: anchor
                ))
                var pageBlocks: [Block] = []
                var pageFootnotes: [Footnote] = []
                do {
                    let pageResult = try await pageEngine.recognize(
                        pageImage: image,
                        pageIndex: i,
                        languages: options.languages
                    )
                    pageBlocks = pageResult.blocks
                    pageFootnotes = pageResult.footnotes
                    claudePageBlocks.append(contentsOf: pageResult.blocks)
                    claudePageFootnotes.append(contentsOf: pageResult.footnotes)
                } catch {
                    // Refusal / network / parse failure on one page
                    // shouldn't fail the whole conversion. The
                    // anchor + missing body manifests as an empty
                    // page in the EPUB. We *don't* write a
                    // checkpoint for failed pages so a re-run
                    // retries them.
                }

                // Layout completes in parallel; consume its result
                // for figure extraction. If Surya failed (no
                // layoutAnalyzer or all retries errored), no figures
                // are extracted for this page — text-only output.
                let layoutRegions = await layoutTask.value
                var pageFigureExtractions: [FigureExtractor.ExtractedFigure] = []
                if let regions = layoutRegions, !regions.isEmpty {
                    pageFigureExtractions = figureExtractor.extract(
                        pageIndex: i,
                        regions: regions,
                        pageImage: image
                    )
                    for fig in pageFigureExtractions {
                        let (_, asset, figureBlock) =
                            buildPageOCRFigureAsset(
                                fig: fig,
                                index: claudePageNextAssetIndex
                            )
                        claudePageNextAssetIndex += 1
                        claudePageFigureAssets.append(asset)
                        claudePageBlocks.append(figureBlock)
                    }
                }

                // Persist a per-page checkpoint so a hang / crash /
                // cancel past this point lets the next conversion of
                // the same source PDF skip page i. Cascade-shape
                // fields are zeroed out (observations: [],
                // layoutRegions: nil); the `pageBlocks` /
                // `pageFootnotes` / `figures` fields carry the
                // actual content. Skip writing if Sonnet failed —
                // the empty page would otherwise mark this index as
                // "done" on resume.
                if !pageBlocks.isEmpty || !pageFootnotes.isEmpty {
                    let checkpoint = PageCheckpoint(
                        pageIndex: i,
                        pageBoundsWidth: pageBoundsCG.width,
                        pageBoundsHeight: pageBoundsCG.height,
                        observations: [],
                        layoutRegions: nil,
                        figures: pageFigureExtractions,
                        tableExtractionsByRegionIndex: [:],
                        verdict: nil,
                        correctionTrailEntries: [],
                        pageBlocks: pageBlocks,
                        pageFootnotes: pageFootnotes
                    )
                    try? resumeManager.writeCheckpoint(checkpoint)
                }
                progress?(Progress(
                    totalPages: totalPages,
                    completedPages: i + 1,
                    currentPageMeanConfidence: 1.0
                ))
                await Task.yield()
                continue
            }

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
            extractorDiagnostics[i] = extracted.diagnostics
            qualityScores[i] = quality

            var observations: [TextObservation]
            let pageBounds: CGSize
            let confidenceForProgress: Double
            var layoutForPage: [LayoutRegion]? = nil

            // `forceOCR` overrides the scorer's `.trust` verdict for
            // every page. The scorer's score/diagnostics are still
            // recorded (`qualityScores` already populated above) so
            // the debug log shows what *would* have happened — but
            // the dispatch always takes the `.reocr` branch.
            let effectiveVerdict: EmbeddedTextQualityScorer.Verdict =
                options.forceOCR ? .reocr : quality.verdict
            verdictsByPage[i] = effectiveVerdict

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
                        // Two ways to alter the cascade shape from
                        // its default Vision → Surya → Tesseract →
                        // Claude:
                        //
                        //   * `useCloudEnhancedOCR` (user-facing
                        //     "Cloud-enhanced OCR (Sonnet)" toggle)
                        //     pulls Surya OCR and Tesseract out of
                        //     the OCR escalation chain so problematic
                        //     regions go straight from Vision to
                        //     Sonnet. Surya **layout** still runs at
                        //     the page-prep stage so the structural
                        //     extractors keep working. Quality wins
                        //     for hard scripts (Phase 4 spike: 11.3%
                        //     CER vs 15.1% for the local cascade).
                        //
                        //   * `disableLocalCascadeEscalation` (spike
                        //     only): same engine removal *plus* feeds
                        //     every text-bearing region to Claude
                        //     unconditionally — used by SpikeRunner
                        //     for head-to-head CER measurements.
                        //     Production never sets this.
                        let suppressLocalEngines =
                            options.useCloudEnhancedOCR
                            || options.disableLocalCascadeEscalation
                        let cascadeSurya = suppressLocalEngines
                            ? nil : suryaEngine
                        let cascadeTess = suppressLocalEngines
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

                // Cloud Phase 6: post-OCR Haiku cleanup. After the
                // (Dictionary-match cleanup moved out of the
                //  per-page loop and into the post-reflow stage —
                //  see `applyDictionaryToBlocks` after reflow runs.
                //  Running per-region missed the cross-region and
                //  cross-page word joins, leading to truncated
                //  fragments getting "corrected" before the reflow
                //  pass had a chance to see them as halves of a
                //  hyphenated word.)

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
                    correctionTrailEntries.append(contentsOf: outcome.trailEntries)
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
                // table-rec model. Cloud Phase 5 (`.cloud`) tries
                // `ClaudeTableExtractor` first and falls back to the
                // Surya path on nil — same call signature, same
                // 2×2-floor gate, just a different backend. The
                // heuristic in `RegionAwareReflow` is the final
                // fallback when both extractors return nil.
                if let regions = layoutForPage {
                    let extractors: [any TableExtractor] = {
                        switch options.processingMode {
                        case .privateLocal:
                            return [tableExtractor].compactMap { $0 }
                        case .cloud:
                            // Cloud first, Surya as offline fallback
                            // for declines / refusals / parse failures.
                            return [
                                claudeTableExtractor as (any TableExtractor)?,
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
                                    let key = CaptionAssociator.PageRegionKey(
                                        pageIndex: i, regionIndex: regionIdx
                                    )
                                    tableExtractionsByKey[key] = rows
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

            pageResults.append(PageObservations(
                pageIndex: i,
                pageBounds: pageBounds,
                observations: observations,
                layoutRegions: layoutForPage
            ))

            // Persist a per-page checkpoint so a crash / cancel /
            // hang past this point lets the next conversion of the
            // same source PDF skip page i. Trail entries written by
            // post-OCR cleanup *for this page* are sliced off the
            // accumulated list (cheap — entries carry pageIndex).
            let pageTrail = correctionTrailEntries.filter {
                $0.pageIndex == i
            }
            let pageFigures = figureExtractionsByPage[i] ?? []
            let pageTables: [Int: [[TableCell]]] = tableExtractionsByKey
                .filter { $0.key.pageIndex == i }
                .reduce(into: [:]) { $0[$1.key.regionIndex] = $1.value }
            let checkpoint = PageCheckpoint(
                pageIndex: i,
                pageBoundsWidth: pageBounds.width,
                pageBoundsHeight: pageBounds.height,
                observations: observations,
                layoutRegions: layoutForPage,
                figures: pageFigures,
                tableExtractionsByRegionIndex: pageTables,
                verdict: verdictsByPage[i]?.rawValue,
                correctionTrailEntries: pageTrail
            )
            try? resumeManager.writeCheckpoint(checkpoint)

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
        if claudePageEngine != nil {
            // Phase 2/4: blocks came from Sonnet per page; figures
            // were extracted via Surya layout + FigureExtractor and
            // appended at the end of each page (Phase 4b end-of-page
            // placement; in-text placement is future work). Skip
            // RegionAwareReflow entirely.
            reflowed = ReflowOutput(
                blocks: claudePageBlocks,
                footnotes: claudePageFootnotes,
                pageAnchors: claudePageAnchors,
                figureAssets: claudePageFigureAssets
            )
        } else if options.emitDebugLog {
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

        // Dictionary-match cleanup. Runs **after** reflow so the
        // corrector sees fully-joined paragraphs — line-end
        // hyphenation (`approxi-\nmation` → `approximation`) and
        // cross-page paragraph continuations are already resolved
        // by the time we tokenize. Running before reflow caused
        // the corrector to "fix" word fragments like `approxi`
        // into plausible-but-wrong neighbors before the reflow
        // could see them as halves of a single word.
        //
        // Conservative policy stays the same: Latin-script only,
        // Levenshtein-1 candidates only, casing preserved, skip
        // anything that looks like a proper noun.
        let dehyphenatedBlocks = Self.applyDictionaryToBlocks(
            reflowed.blocks,
            corrector: dictionaryCorrector
        )

        // Phase 1 of structured-document detection: split the flat
        // block stream into chapters at every level-1 heading.
        // Footnotes, page anchors, and figure assets are distributed
        // to the chapter they belong to so EPUB readers see a real
        // multi-chapter navigation tree.
        let rawChapters = ChapterSplitter.split(
            blocks: dehyphenatedBlocks,
            footnotes: reflowed.footnotes,
            pageAnchors: reflowed.pageAnchors,
            figureAssets: reflowed.figureAssets,
            bookFallbackTitle: title
        )
        // If TOC parsing was enabled and Haiku produced a result,
        // override chapter titles where the TOC entry's display
        // page maps to the chapter's first PDF page (after
        // learning the offset). Falls through to the heuristic
        // titles when the parser returned nil or no offset
        // matched.
        let parsedTOC: ParsedTOC? = await parsedTOCTask?.value
        let chapters: [Chapter]
        let appliedTOC: ParsedTOC?
        if let toc = parsedTOC {
            let outcome = TOCTitleApplier.apply(toc: toc, chapters: rawChapters)
            chapters = outcome.chapters
            appliedTOC = ParsedTOC(
                entries: toc.entries,
                inferredOffset: outcome.inferredOffset
            )
        } else {
            chapters = rawChapters
            appliedTOC = nil
        }
        // Cloud Phase 6d: semantic chapter classification. Per
        // chapter, ask Haiku for one EPUB Structural Semantics
        // Vocabulary token. Runs in parallel via TaskGroup with a
        // small concurrency cap so we don't hammer the API on
        // 30-chapter books. Failures (refusal, network, unknown
        // label) leave the chapter unlabeled — `chapter` is the
        // safe default but we'd rather emit nothing.
        let classifier = Self.makeClaudeChapterClassifier(
            options: options, budget: claudeBudget
        )
        let classifiedChapters: [Chapter]
        if let classifier {
            classifiedChapters = await Self.classifyChapters(
                chapters: chapters, classifier: classifier
            )
        } else {
            classifiedChapters = chapters
        }

        let book = Book(
            title: title,
            language: language,
            chapters: classifiedChapters
        )

        let trail = correctionTrailEntries.isEmpty
            ? nil
            : CorrectionTrail(entries: correctionTrailEntries)
        try EPUBBuilder().write(
            book: book,
            correctionTrail: trail,
            parsedTOC: appliedTOC,
            to: outputURL
        )

        // Conversion succeeded — staging dir's purpose is served.
        // Skip cleanup when debug logging is on so the user can
        // still inspect the artifacts; otherwise reclaim the disk.
        if !options.emitDebugLog {
            resumeManager.deleteAll()
        }

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
        return ConversionStats.make(
            elapsed: Date().timeIntervalSince(conversionStart),
            observationsBySource: bySource,
            pagesTrustedEmbeddedText: trusted,
            pagesReOCRd: reocrd,
            claudeCallCount: claudeCallCount,
            claudeUsageByModel: claudeUsage
        )
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

    /// Phase 4b helper: build a `FigureAsset` + matching
    /// `Block.figure` for one extracted figure, using the supplied
    /// document-order index for the asset id. Used by both the fresh
    /// page-OCR path (after Surya extraction) and the resume
    /// fast-path (re-walking checkpointed `figures`).
    ///
    /// Cover detection is intentionally absent — the cascade path's
    /// `RegionAwareReflow.detectCoverFigure` runs on `pageResults`,
    /// which we don't populate here. EPUBs from the page-OCR path
    /// currently have no cover image; future work can reapply the
    /// "page-0 single dominant figure ≥ 50% of page area" rule here.
    private func buildPageOCRFigureAsset(
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
