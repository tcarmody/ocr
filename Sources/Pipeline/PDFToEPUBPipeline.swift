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
        /// Per-feature toggles for on-device features (Apple
        /// Foundation Models). Consulted only when `processingMode ==
        /// .privateLocal` *and* runtime availability of the model
        /// confirms — see `AppleFoundationModelClient.availability`.
        public var localFeatures: AISettings.LocalFeatures
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
        /// Google AI Studio key resolver (Gemini generative models).
        /// Powers `GeminiPageOCREngine` when `pageOCRProvider ==
        /// .gemini25Flash`. Nil/empty → falls back to Claude page OCR.
        public var geminiAPIKeyProvider: @Sendable () -> String?
        /// Google Cloud Vision API key resolver (Cloud Vision API for
        /// `DOCUMENT_TEXT_DETECTION`). Powers the Stage 2.5
        /// `GoogleDocumentOCREngine` in `RegionCascade`. Distinct from
        /// the Gemini key — Cloud Vision uses a Cloud Console key, not
        /// an AI Studio key. Nil/empty → Stage 2.5 is skipped.
        public var googleCloudVisionAPIKeyProvider: @Sendable () -> String?
        /// Which provider runs end-to-end page OCR. Mirrors
        /// `AISettings.pageOCRProvider`. Manuscript mode ignores this
        /// (Opus only).
        public var pageOCRProvider: PageOCRProvider
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
        /// E-Vision-Modes / Manuscript track. When true (and Cloud
        /// mode + an API key are configured), every page routes
        /// through `ClaudePageOCREngine` in manuscript mode
        /// (Claude Opus 4.7) instead of the typeset Sonnet path.
        /// Per-job; the launcher's "Manuscript mode" toggle is
        /// the only surface that flips this. Mutually exclusive
        /// with `useClaudePageOCR` at the launcher layer — both
        /// drive the same engine; manuscript wins when both are on.
        public var useManuscriptMode: Bool
        /// Hand-family selector for manuscript mode. Effective
        /// only when `useManuscriptMode` is true. `.auto` is the
        /// generic prompt; the four specific cases bundle a
        /// script style + transcription policy.
        public var manuscriptHand: ManuscriptHand
        /// E-Vision-Modes / Early Print track. When true (Cloud
        /// mode + API key required), page OCR routes through
        /// `ClaudePageOCREngine` in early-print mode (Sonnet 4.6
        /// with normalizing-posture prompt for 15th–18th c.
        /// printed books). Mutually exclusive with
        /// `useClaudePageOCR` and `useManuscriptMode` at the
        /// launcher layer; the engine factory falls back to
        /// `.typeset` when nothing is set.
        public var useEarlyPrintMode: Bool
        /// Typeface selector for early-print mode (auto / roman /
        /// blackletter / italic). Effective only when
        /// `useEarlyPrintMode` is true.
        public var earlyPrintTypeface: EarlyPrintTypeface
        /// Tier 9 / V-Outputs. When true, the conversion writes
        /// Write `.txt` and `.md` siblings next to the EPUB.
        /// Cheap (text files are small). Default true.
        public var emitSiblingTextOutputs: Bool
        /// Write `.html` and `.docx` siblings next to the EPUB.
        /// Heavier than the text outputs (DOCX is a binary zip,
        /// HTML inlines all CSS). Default false.
        public var emitSiblingDocuments: Bool
        /// Tier 9 / V-Trust-PerPage. Per-page force-OCR override.
        /// Empty array = no per-page force; the global `forceOCR`
        /// flag still applies if set. Each range is a 0-indexed
        /// inclusive range; pages inside any range bypass the
        /// embedded-text-trust path and run OCR. Use cases:
        /// born-digital front matter (pages 1-20) + scanned
        /// appendix (pages 200-end), or any mix of trust-quality.
        public var forceOCRPageRanges: [ClosedRange<Int>]
        /// Optional override for the plain-text sibling output URL.
        /// When non-nil, the txt is written here instead of next to
        /// the EPUB. The launcher uses this to route outputs into
        /// the user's configured per-format subfolders (e.g.
        /// `<root>/Text Files/<basename>.txt`); pipeline itself
        /// doesn't know about the layout convention.
        public var siblingTextURLOverride: URL?
        /// Same as `siblingTextURLOverride`, for the markdown
        /// sibling output.
        public var siblingMarkdownURLOverride: URL?
        /// Output path override for the HTML sibling
        /// (`<basename>.html`). Controlled by `emitSiblingDocuments`.
        public var siblingHTMLURLOverride: URL?
        /// Output path override for the DOCX sibling
        /// (`<basename>.docx`). Controlled by `emitSiblingDocuments`.
        public var siblingDOCXURLOverride: URL?
        /// Tier 9 / V-PDF-Searchable. When true, the conversion
        /// also emits a searchable-PDF copy of the source PDF
        /// alongside the EPUB — same visual content as the input,
        /// with invisible OCR text per page so the result is
        /// searchable / selectable in any PDF viewer. Off by
        /// default: searchable PDFs are several MB per book and
        /// most users only need the EPUB.
        public var emitSearchablePDF: Bool
        /// Optional override for the searchable-PDF output URL.
        /// When non-nil, the searchable PDF lands here; otherwise
        /// it goes next to the EPUB as `<basename>.searchable.pdf`.
        public var searchablePDFURLOverride: URL?
        /// Optional override for the debug-mode staging directory.
        /// The pipeline default puts the staging dir next to the
        /// EPUB (when `emitDebugLog` is on) or next to the source
        /// PDF (otherwise). When this override is set + emitDebugLog
        /// is on, the staging dir lives at this exact URL — used
        /// by the configured-output-folder feature to centralize
        /// debug logs under `<root>/Logs/`. Nil keeps default
        /// behavior.
        public var debugStagingURLOverride: URL?

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
            localFeatures: AISettings.LocalFeatures = AISettings.LocalFeatures(),
            perBookCallCap: Int = 200,
            anthropicAPIKeyProvider: @escaping @Sendable () -> String? = { nil },
            geminiAPIKeyProvider: @escaping @Sendable () -> String? = { nil },
            googleCloudVisionAPIKeyProvider: @escaping @Sendable () -> String? = { nil },
            pageOCRProvider: PageOCRProvider = .claude,
            disableLocalCascadeEscalation: Bool = false,
            useClaudePageOCR: Bool = false,
            useManuscriptMode: Bool = false,
            manuscriptHand: ManuscriptHand = .auto,
            useEarlyPrintMode: Bool = false,
            earlyPrintTypeface: EarlyPrintTypeface = .auto,
            emitSiblingTextOutputs: Bool = true,
            emitSiblingDocuments: Bool = false,
            forceOCRPageRanges: [ClosedRange<Int>] = [],
            siblingTextURLOverride: URL? = nil,
            siblingMarkdownURLOverride: URL? = nil,
            siblingHTMLURLOverride: URL? = nil,
            siblingDOCXURLOverride: URL? = nil,
            emitSearchablePDF: Bool = false,
            searchablePDFURLOverride: URL? = nil,
            debugStagingURLOverride: URL? = nil
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
            self.localFeatures = localFeatures
            self.perBookCallCap = perBookCallCap
            self.anthropicAPIKeyProvider = anthropicAPIKeyProvider
            self.geminiAPIKeyProvider = geminiAPIKeyProvider
            self.googleCloudVisionAPIKeyProvider = googleCloudVisionAPIKeyProvider
            self.pageOCRProvider = pageOCRProvider
            self.disableLocalCascadeEscalation = disableLocalCascadeEscalation
            self.useClaudePageOCR = useClaudePageOCR
            self.useManuscriptMode = useManuscriptMode
            self.manuscriptHand = manuscriptHand
            self.useEarlyPrintMode = useEarlyPrintMode
            self.earlyPrintTypeface = earlyPrintTypeface
            self.emitSiblingTextOutputs = emitSiblingTextOutputs
            self.emitSiblingDocuments = emitSiblingDocuments
            self.forceOCRPageRanges = forceOCRPageRanges
            self.siblingTextURLOverride = siblingTextURLOverride
            self.siblingMarkdownURLOverride = siblingMarkdownURLOverride
            self.siblingHTMLURLOverride = siblingHTMLURLOverride
            self.siblingDOCXURLOverride = siblingDOCXURLOverride
            self.emitSearchablePDF = emitSearchablePDF
            self.searchablePDFURLOverride = searchablePDFURLOverride
            self.debugStagingURLOverride = debugStagingURLOverride
        }

        /// True when `pageIndex` should bypass the embedded-text
        /// trust path and force OCR. The global `forceOCR` flag
        /// applies to all pages; per-page `forceOCRPageRanges`
        /// override individual pages or ranges. Either matching is
        /// sufficient — both controls compose additively.
        public func shouldForceOCR(forPageIndex i: Int) -> Bool {
            if forceOCR { return true }
            return forceOCRPageRanges.contains { $0.contains(i) }
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
    /// Born-digital figure detection — walks each PDF page's content
    /// stream for image XObject placements. Preferred over Surya for
    /// `.picture` regions when present because PDF XObjects give us
    /// pixel-perfect bboxes from the source, not heuristic guesses
    /// from a rasterized page. Returns empty for fully-scanned PDFs;
    /// the pipeline falls through to Surya / Vision saliency.
    private nonisolated let pdfImageXObjectDetector = PDFImageXObjectDetector()
    /// Vision saliency-based figure fallback. Consulted only when
    /// the PDF carries no image XObjects AND Surya isn't installed,
    /// so scanned books without Surya at least get *some* figure
    /// regions extracted (lower quality than Surya, but non-zero).
    private nonisolated let visionFigureDetector = VisionFigureDetector()
    // `nonisolated` so `runPageOCRPage` / `preparePageForBatch` (also
    // nonisolated; called from sending TaskGroup closures) can read
    // them without an actor hop. Both types are Sendable value types
    // with no shared mutable state.
    private nonisolated let embeddedExtractor = EmbeddedTextExtractor()
    private let gapFiller = EmbeddedTextGapFiller()
    private nonisolated let qualityScorer = EmbeddedTextQualityScorer()

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

    /// Build a Cloud-mode engine when (1) `processingMode == .cloud`,
    /// (2) the named feature flag is on, and (3) an API key is
    /// configured. Returns nil otherwise — the pipeline degrades to
    /// local-only silently, which is the right "fail open" posture
    /// for `.cloud` mode without a key. The key is captured once per
    /// conversion via `anthropicAPIKeyProvider`; a rotation mid-run
    /// lands on the next call to `convert`.
    static func makeClaudeEngine<Engine>(
        options: Options, budget: ClaudeCallBudget,
        feature: KeyPath<AISettings.CloudFeatures, Bool>,
        construct: (AnthropicAPIClient, ClaudeCallBudget) -> Engine
    ) -> Engine? {
        guard options.processingMode == .cloud,
              options.cloudFeatures[keyPath: feature],
              let key = options.anthropicAPIKeyProvider(),
              !key.isEmpty else { return nil }
        return construct(AnthropicAPIClient(apiKeyProvider: { key }), budget)
    }

    static func makeClaudeOCREngine(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeOCREngine? {
        makeClaudeEngine(
            options: options, budget: budget, feature: \.hardRegionOCR
        ) { ClaudeOCREngine(client: $0, budget: $1) }
    }

    /// Build the Google Cloud Vision Stage-2.5 cascade engine. Gates
    /// on `processingMode == .cloud`, the `googleDocumentOCRInCascade`
    /// feature flag, and a configured Cloud Vision key. Returns nil
    /// otherwise — the cascade then jumps from Tesseract straight to
    /// Claude as before.
    static func makeGoogleDocumentOCREngine(
        options: Options, budget: ClaudeCallBudget
    ) -> GoogleDocumentOCREngine? {
        guard options.processingMode == .cloud,
              options.cloudFeatures.googleDocumentOCRInCascade,
              let key = options.googleCloudVisionAPIKeyProvider(),
              !key.isEmpty else { return nil }
        return GoogleDocumentOCREngine(
            apiKeyProvider: { key }, budget: budget
        )
    }

    static func makeClaudePostProcessor(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudePostProcessor? {
        makeClaudeEngine(
            options: options, budget: budget, feature: \.postOCRCleanup
        ) { ClaudePostProcessor(client: $0, budget: $1) }
    }

    static func makeClaudeTOCParser(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeTOCParser? {
        makeClaudeEngine(
            options: options, budget: budget, feature: \.tocParsing
        ) { ClaudeTOCParser(client: $0, budget: $1) }
    }

    static func makeClaudeCoherenceAnalyzer(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeCoherenceAnalyzer? {
        makeClaudeEngine(
            options: options, budget: budget, feature: \.coherencePass
        ) { ClaudeCoherenceAnalyzer(client: $0, budget: $1) }
    }

    static func makeClaudeChapterStructureAnalyzer(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeChapterStructureAnalyzer? {
        makeClaudeEngine(
            options: options, budget: budget, feature: \.chapterStructurePass
        ) { ClaudeChapterStructureAnalyzer(client: $0, budget: $1) }
    }

    static func makeClaudeChapterBreakDetector(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeChapterBreakDetector? {
        makeClaudeEngine(
            options: options, budget: budget,
            feature: \.chapterMissedBreakDetection
        ) { ClaudeChapterBreakDetector(client: $0, budget: $1) }
    }

    static func makeClaudeFrontBackMatterSplitter(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeFrontBackMatterSplitter? {
        makeClaudeEngine(
            options: options, budget: budget,
            feature: \.frontBackMatterSplitting
        ) { ClaudeFrontBackMatterSplitter(client: $0, budget: $1) }
    }

    static func makeClaudeMetadataExtractor(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeMetadataExtractor? {
        makeClaudeEngine(
            options: options, budget: budget, feature: \.metadataExtraction
        ) { ClaudeMetadataExtractor(client: $0, budget: $1) }
    }

    static func makeClaudeChapterClassifier(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeChapterClassifier? {
        makeClaudeEngine(
            options: options, budget: budget, feature: \.semanticClassification
        ) { ClaudeChapterClassifier(client: $0, budget: $1) }
    }

    /// Gating policy shared by all four `makeXxx` factories below:
    ///
    ///  1. Cloud wins when configured + keyed + per-feature toggle on.
    ///  2. Otherwise, AFM picks up as a **fallback** whenever its
    ///     per-feature toggle is on and Apple Intelligence is
    ///     available — regardless of `processingMode`. This covers
    ///     the gap where a user is on `.cloud` mode but hasn't
    ///     supplied a key (or the key is invalid, or the per-feature
    ///     Cloud toggle is off): AFM still runs on-device for free
    ///     instead of the feature silently no-op'ing.
    ///  3. Returns nil only when both Cloud and AFM are unavailable
    ///     or both toggles are off — the cascade falls back to its
    ///     pre-AI behavior in that case (no classification, no
    ///     metadata extraction, no cleanup, no coherence pass).
    ///
    /// To opt out of AFM entirely on a Cloud-configured Mac, flip
    /// the corresponding `localFeatures.localXxx` toggle off. The
    /// processingMode setting no longer artificially blocks AFM
    /// when Cloud is selected.

    /// Pick a metadata extractor. See gating note above.
    static func makeMetadataExtractor(
        options: Options, budget: ClaudeCallBudget
    ) -> (any BookMetadataExtractor)? {
        if let cloud = makeClaudeMetadataExtractor(
            options: options, budget: budget
        ) {
            return cloud
        }
        guard options.localFeatures.localMetadataExtraction
        else { return nil }
        if case .available = AppleFoundationModelClient.availability {
            return AppleFoundationModelMetadataExtractor()
        }
        return nil
    }

    /// Pick a post-OCR cleanup processor. See gating note above.
    /// The AFM impl is text-only: vision-mode regions still need
    /// Cloud Haiku, but the AFM path covers the much larger
    /// passages-mode population.
    static func makePostProcessor(
        options: Options, budget: ClaudeCallBudget
    ) -> (any PostOCRProcessor)? {
        if let cloud = makeClaudePostProcessor(
            options: options, budget: budget
        ) {
            return cloud
        }
        guard options.localFeatures.localPostOCRCleanup
        else { return nil }
        if case .available = AppleFoundationModelClient.availability {
            return AppleFoundationModelPostProcessor()
        }
        return nil
    }

    /// Pick a coherence analyzer. See gating note above.
    static func makeCoherenceAnalyzer(
        options: Options, budget: ClaudeCallBudget
    ) -> (any BookCoherenceAnalyzer)? {
        if let cloud = makeClaudeCoherenceAnalyzer(
            options: options, budget: budget
        ) {
            return cloud
        }
        guard options.localFeatures.localCoherencePass
        else { return nil }
        if case .available = AppleFoundationModelClient.availability {
            return AppleFoundationModelCoherenceAnalyzer()
        }
        return nil
    }

    /// Pick a chapter classifier. See gating note above. Returns
    /// the protocol type so the per-chapter `classifyChapters`
    /// pass doesn't branch on which impl is active.
    static func makeChapterClassifier(
        options: Options, budget: ClaudeCallBudget
    ) -> (any SemanticChapterClassifier)? {
        if let cloud = makeClaudeChapterClassifier(
            options: options, budget: budget
        ) {
            return cloud
        }
        guard options.localFeatures.localChapterClassification
        else { return nil }
        if case .available = AppleFoundationModelClient.availability {
            return AppleFoundationModelClassifier()
        }
        return nil
    }

    static func makeClaudeTableExtractor(
        options: Options, budget: ClaudeCallBudget
    ) -> ClaudeTableExtractor? {
        makeClaudeEngine(
            options: options, budget: budget, feature: \.tableExtraction
        ) { ClaudeTableExtractor(client: $0, budget: $1) }
    }

    /// Build the "Claude does the page" engine. Layered on top of the
    /// generic factory: same `.cloud` + key + `hardRegionOCR` gates
    /// (reusing that feature flag for billing/budget purposes), plus
    /// the user's explicit `useClaudePageOCR` or `useManuscriptMode`
    /// opt-in. When non-nil the per-page loop skips Vision / cascade
    /// / region-aware reflow and uses the configured Claude model to
    /// produce structured XHTML directly. `captureSink` receives the
    /// raw response per page (or sentinel marker for refusal / empty
    /// / API error) when the caller wants to dump them in the
    /// conversion's debug log; nil disables capture.
    ///
    /// Manuscript wins when both flags are on at the launcher layer
    /// — the two settings drive the same engine; routing to Opus
    /// (handwriting) is the more specific intent than routing to
    /// Sonnet (printed cascade-bypass).
    static func makeClaudePageOCREngine(
        options: Options, budget: ClaudeCallBudget,
        captureSink: ClaudePageOCREngine.CaptureSink? = nil
    ) -> ClaudePageOCREngine? {
        guard options.useClaudePageOCR
            || options.useManuscriptMode
            || options.useEarlyPrintMode
        else { return nil }
        let mode: ClaudePageOCREngine.Mode
        if options.useManuscriptMode {
            // Manuscript is the most specific intent (handwritten
            // material needs Opus); wins over earlyPrint/typeset.
            mode = .manuscript(hand: options.manuscriptHand)
        } else if options.useEarlyPrintMode {
            // Early print stays on Sonnet but with the
            // normalizing-posture prompt.
            mode = .earlyPrint(typeface: options.earlyPrintTypeface)
        } else {
            mode = .typeset
        }
        return makeClaudeEngine(
            options: options, budget: budget, feature: \.hardRegionOCR
        ) { ClaudePageOCREngine(
            client: $0, budget: $1, mode: mode, captureSink: captureSink
        ) }
    }

    /// Build the active page-OCR engine based on the user's provider
    /// pick. Returns the Claude engine for `.claude` (or when the
    /// user is in manuscript mode — handwriting requires Opus
    /// regardless of provider preference). Returns the Gemini engine
    /// for `.gemini25Flash` when the Gemini key is configured; falls
    /// back to Claude when Gemini is selected but its key is missing.
    /// Returns nil when no page-OCR mode flag is set OR when neither
    /// provider has a usable key.
    static func makeActivePageOCREngine(
        options: Options, budget: ClaudeCallBudget,
        captureSink: ClaudePageOCREngine.CaptureSink? = nil
    ) -> (any PageOCREngine)? {
        guard options.useClaudePageOCR
            || options.useManuscriptMode
            || options.useEarlyPrintMode
        else { return nil }
        // Manuscript mode hard-pins Claude (Opus). Provider pick is
        // ignored — Gemini doesn't handle handwriting reliably.
        if options.useManuscriptMode {
            return makeClaudePageOCREngine(
                options: options, budget: budget, captureSink: captureSink
            )
        }
        switch options.pageOCRProvider {
        case .claude:
            return makeClaudePageOCREngine(
                options: options, budget: budget, captureSink: captureSink
            )
        case .gemini25Flash, .gemini3FlashPreview:
            guard options.processingMode == .cloud,
                  let key = options.geminiAPIKeyProvider(),
                  !key.isEmpty
            else {
                // Gemini selected but no key configured. Try Claude as
                // a fallback so the user gets *some* page OCR rather
                // than silent no-op.
                return makeClaudePageOCREngine(
                    options: options, budget: budget, captureSink: captureSink
                )
            }
            // Pin `thinking_level: minimal` for 3 Flash since OCR
            // doesn't benefit from reasoning and any thinking inflates
            // output tokens. 2.5 Flash has no thinking config; leave nil.
            let modelId: String
            let thinking: String?
            switch options.pageOCRProvider {
            case .gemini3FlashPreview:
                modelId = "gemini-3-flash-preview"
                thinking = "minimal"
            default:
                modelId = "gemini-2.5-flash"
                thinking = nil
            }
            return GeminiPageOCREngine(
                apiKeyProvider: { key },
                budget: budget,
                model: modelId,
                captureSink: captureSink,
                thinkingLevel: thinking
            )
        }
    }

    /// Per-conversion capture store for `ClaudePageOCREngine` debug
    /// dumps. Created in `convert(...)` only when `emitDebugLog` is
    /// on; passed to the engine factory via its `captureSink`. Pages
    /// run concurrently (TaskGroup or batch dispatch), so writes are
    /// serialized by an `NSLock` — same shape the static accumulator
    /// it replaces used.
    final class CapturedResponseStore: @unchecked Sendable {
        private var entries: [ClaudePageOCREngine.CapturedResponse] = []
        private let lock = NSLock()

        func record(_ entry: ClaudePageOCREngine.CapturedResponse) {
            lock.lock(); defer { lock.unlock() }
            entries.append(entry)
        }

        func snapshot() -> [ClaudePageOCREngine.CapturedResponse] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }

    /// Bundle of every Cloud-mode engine a conversion might need,
    /// each independently nil when its gate fails. Built once per
    /// `convert(...)` and shared across pages + post-loop stages.
    struct ClaudeEngines {
        let budget: ClaudeCallBudget
        let ocr: ClaudeOCREngine?
        /// Cascade Stage 2.5 — Google Cloud Vision DOCUMENT_TEXT_DETECTION.
        /// Sits between Tesseract and `ocr` (Claude) in `RegionCascade`.
        /// Nil when not in `.cloud` mode or no Cloud Vision key.
        let googleDocumentOCR: GoogleDocumentOCREngine?
        /// Post-OCR cleanup processor — Cloud (Haiku) or AFM
        /// depending on processingMode + feature toggles +
        /// runtime availability. Held as the protocol type so
        /// the cascade's `applyPostOCRCleanup` doesn't branch
        /// on which impl is active.
        let postProcessor: (any PostOCRProcessor)?
        let tocParser: ClaudeTOCParser?
        let tableExtractor: ClaudeTableExtractor?
        /// Active page-OCR engine. Either `ClaudePageOCREngine` or
        /// `GeminiPageOCREngine` depending on the user's provider
        /// pick. Manuscript mode forces Claude.
        let pageEngine: (any PageOCREngine)?
        /// Concrete Claude page engine for the batch dispatch path.
        /// Non-nil only when `pageEngine` is the Claude variant —
        /// batch / prompt-cache features are Anthropic-only, so
        /// Gemini-selected runs silently fall back to serial.
        let claudeBatchPageEngine: ClaudePageOCREngine?

        static func make(
            options: Options,
            captures: CapturedResponseStore?
        ) -> ClaudeEngines {
            let budget = ClaudeCallBudget(cap: options.perBookCallCap)
            let captureSink: ClaudePageOCREngine.CaptureSink? = captures.map { store in
                { @Sendable entry in store.record(entry) }
            }
            let pageEngine = makeActivePageOCREngine(
                options: options, budget: budget, captureSink: captureSink
            )
            let claudeBatch = pageEngine as? ClaudePageOCREngine
            return ClaudeEngines(
                budget: budget,
                ocr: makeClaudeOCREngine(options: options, budget: budget),
                googleDocumentOCR: makeGoogleDocumentOCREngine(
                    options: options, budget: budget
                ),
                postProcessor: makePostProcessor(options: options, budget: budget),
                tocParser: makeClaudeTOCParser(options: options, budget: budget),
                tableExtractor: makeClaudeTableExtractor(options: options, budget: budget),
                pageEngine: pageEngine,
                claudeBatchPageEngine: claudeBatch
            )
        }
    }

    /// Resolved staging directory for one conversion + the
    /// `ResumeManager` that owns its checkpoints. Encapsulates the
    /// debug-vs-resume-vs-override directory choice and the manifest
    /// validation that decides whether prior checkpoints carry over.
    struct StagingPlan {
        let directory: URL
        let manager: ResumeManager
        let alreadyDonePages: Set<Int>

        /// Resolve the staging dir + initialize the resume manager.
        /// Wipes the dir if its manifest doesn't match the current
        /// run (different source file, page count, schema, or mode);
        /// returns the page indices whose checkpoints from a prior
        /// run can be skipped on this one.
        static func resolve(
            pdfURL: URL, outputURL: URL,
            options: Options, totalPages: Int
        ) throws -> StagingPlan {
            let directory: URL
            if options.emitDebugLog,
               let override = options.debugStagingURLOverride {
                directory = override
            } else if options.emitDebugLog {
                directory = outputURL.deletingPathExtension()
                    .appendingPathExtension("humanist-debug")
            } else {
                directory = pdfURL.deletingPathExtension()
                    .appendingPathExtension("humanist-staging")
            }
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let manager = ResumeManager(stagingDir: directory)
            let sourceFingerprint = ResumeManager.fingerprint(of: pdfURL) ?? ""
            let existing = manager.readManifest()
            let currentMode: String = options.useClaudePageOCR
                ? StagingManifest.Mode.pageOCR
                : StagingManifest.Mode.cascade
            let resumeAvailable: Bool
            if let m = existing,
               m.sourceFingerprint == sourceFingerprint,
               m.totalPages == totalPages,
               m.schemaVersion == 1,
               m.effectiveMode == currentMode {
                resumeAvailable = true
            } else {
                if existing != nil {
                    try? FileManager.default.removeItem(at: directory)
                    try? FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true
                    )
                }
                try? manager.writeManifest(StagingManifest(
                    sourceFingerprint: sourceFingerprint,
                    totalPages: totalPages,
                    mode: currentMode
                ))
                resumeAvailable = false
            }
            return StagingPlan(
                directory: directory,
                manager: manager,
                alreadyDonePages: resumeAvailable ? manager.completedPages() : []
            )
        }
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
        postProcessor: any PostOCRProcessor
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
    ///
    /// Q-Italic-Skip (2026-05-12): skip italic single-run blocks
    /// outright. Academic prose italicizes foreign terms
    /// specifically so the reader knows they're not native;
    /// applying English spell-check to a fully-italic
    /// paragraph (e.g. a Latin epigraph, a Greek citation
    /// transliterated whole) is exactly wrong. Multi-run blocks
    /// were already protected (the run-count == 1 guard) since
    /// italic spans inside otherwise-English prose come through
    /// as separate runs in the Claude-OCR'd path. Vision/Tesseract
    /// paths often don't emit italics as separate runs at all —
    /// the cross-language guard inside `correctionFor` is the
    /// second half of the fix that covers those.
    static func correctedRun(
        _ runs: [InlineRun],
        corrector: DictionaryCorrector
    ) -> InlineRun? {
        guard runs.count == 1 else { return nil }
        if runs[0].isItalic { return nil }
        let original = runs[0].text
        let corrected = corrector.correct(original)
        guard corrected != original else { return nil }
        var newRun = runs[0]
        newRun.text = corrected
        return newRun
    }

    /// Run the chapter classifier across `chapters`, with a small
    /// concurrency cap so a 30-chapter book doesn't issue 30
    /// simultaneous calls. Each `classify` call internally gates
    /// on its own runtime budget (`ClaudeCallBudget` for Cloud;
    /// implicit per-call session for AFM), so the cap is also a
    /// backstop. Returns a chapter list in the same order with
    /// `epubType` populated where the classifier produced a valid
    /// label.
    ///
    /// Takes the protocol type rather than the concrete Claude
    /// classifier so the on-device `AppleFoundationModelClassifier`
    /// (Phase 1 of L-Foundation-Models) shares the same
    /// fan-out / drain-and-refill plumbing without code duplication.
    static func classifyChapters(
        chapters: [Chapter],
        classifier: any SemanticChapterClassifier
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
    /// Run the layout pipeline for one page. Three-source merge:
    ///
    ///   1. **PDFKit image XObject walk** — pixel-perfect picture
    ///      bboxes for born-digital pages. Always runs (cheap, no
    ///      external deps); preferred over Surya's `.picture`
    ///      regions when both detect a figure at the same place.
    ///   2. **Surya layout analyzer** — full region classification
    ///      (text/heading/footnote/table/etc.) when installed. Skipped
    ///      when `layoutAnalyzer == nil`.
    ///   3. **Vision saliency** — last-resort `.picture` detection
    ///      when neither XObject nor Surya found any figure regions.
    ///      Lower quality than Surya but better than no figures on
    ///      scanned books.
    private func analyzeLayoutWithRetry(
        pdf: LoadedPDF,
        pageIndex: Int,
        initialDPI: CGFloat,
        initialPNGURL: URL,
        initialPageBounds: CGSize,
        stagingDir: URL
    ) async -> (layout: [LayoutRegion]?, error: String?) {
        // Step 1: born-digital image XObjects (always runs).
        let xobjectFigures = pdfImageXObjectDetector.detect(
            in: pdf, pageIndex: pageIndex
        )

        // Step 2: Surya layout when available. The retry-at-lower-DPI
        // path stays — Surya occasionally OOMs on very-high-DPI pages.
        var suryaRegions: [LayoutRegion]? = nil
        var suryaError: String? = nil
        if let analyzer = layoutAnalyzer {
            do {
                suryaRegions = try await analyzer.analyze(
                    imageURL: initialPNGURL, pageBounds: initialPageBounds
                )
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
                    suryaRegions = try await analyzer.analyze(
                        imageURL: retryURL, pageBounds: retryBounds
                    )
                } catch let retryError {
                    suryaError = "primary@\(Int(initialDPI))dpi: \(primaryError); "
                        + "retry@\(Int(retryDPI))dpi: \(retryError)"
                }
            }
        }

        // Step 3 (deferred to caller-trigger): Vision saliency. We
        // can't run it here without the page CGImage; the existing
        // call sites already have the image in scope so they invoke
        // `visionFigureDetector` themselves when our return is empty.

        let merged = Self.mergeLayoutSources(
            xobjectFigures: xobjectFigures,
            suryaRegions: suryaRegions
        )
        // `merged` is nil when Surya wasn't installed. Surya errors
        // (when the analyzer ran and crashed) surface independently
        // so the debug log captures them either way.
        return (merged, suryaError)
    }

    /// Figure-detection fallback for the no-Surya case. Returns
    /// `ExtractedFigure`s that feed `figureExtractionsByPage`
    /// directly, *bypassing* the layout-regions array — so the
    /// reflow's non-region-aware path still processes body text.
    /// Tries PDFKit image XObjects first (born-digital, pixel-
    /// perfect), then Vision saliency (scanned, lower quality).
    /// Returns empty when both come back empty or Surya is
    /// installed (caller should be using the layout-regions path
    /// in that case).
    private func extractFallbackFigures(
        pdf: LoadedPDF,
        pageIndex: Int,
        pageImage: CGImage,
        textObservations: [TextObservation],
        layoutAvailable: Bool
    ) async -> [FigureExtractor.ExtractedFigure] {
        // No fallback needed when Surya provided a layout — figure
        // extraction already ran against those regions.
        guard !layoutAvailable else { return [] }

        // Step A: PDFKit image XObject placements (born-digital).
        let xobjects = pdfImageXObjectDetector.detect(
            in: pdf, pageIndex: pageIndex
        )
        if !xobjects.isEmpty {
            let syntheticRegions = xobjects.enumerated().map { idx, x in
                LayoutRegion(
                    kind: .picture, box: x.box,
                    readingOrder: idx, confidence: 1.0
                )
            }
            return FigureExtractor().extract(
                pageIndex: pageIndex,
                regions: syntheticRegions,
                pageImage: pageImage
            )
        }

        // Step B: Vision saliency (scanned books). Conservative —
        // only fires when the page has text observations to filter
        // against, so a fully-blank page can't produce false
        // positives. Page-OCR mode (textObservations empty) skips
        // this on purpose; without text to anchor against, the
        // false-positive rate on prose pages is too high.
        guard !textObservations.isEmpty else { return [] }
        let saliencyRegions = await visionFigureDetector.detect(
            pageImage: pageImage,
            textObservations: textObservations
        )
        guard !saliencyRegions.isEmpty else { return [] }
        return FigureExtractor().extract(
            pageIndex: pageIndex,
            regions: saliencyRegions,
            pageImage: pageImage
        )
    }

    /// Combine PDFKit image-XObject detections with Surya layout
    /// regions. Only applies when Surya is installed (suryaRegions
    /// non-nil) — without Surya, the layout array would contain only
    /// picture regions and the reflow's region-aware path would
    /// emit just those figures, dropping all body text. The
    /// no-Surya case is handled by a separate figure-only path
    /// (`extractFallbackFigures`) that feeds `figureExtractionsByPage`
    /// directly without polluting the layout.
    ///
    /// Strategy when Surya is present:
    ///   * Override Surya's `.picture` regions with XObject bboxes
    ///     (pixel-perfect from the PDF beats Surya's rasterized
    ///     guesses). Drop any Surya `.picture` that overlaps an
    ///     XObject by ≥50%.
    ///   * Keep Surya's `.formula`, `.table`, `.text`, `.caption`,
    ///     `.sectionHeader`, etc. intact (XObjects can't classify).
    ///   * Append the XObject bboxes as additional `.picture`
    ///     regions at the tail of the layout.
    static func mergeLayoutSources(
        xobjectFigures: [PDFImageXObjectDetector.DetectedImage],
        suryaRegions: [LayoutRegion]?
    ) -> [LayoutRegion]? {
        guard let surya = suryaRegions else {
            // No Surya — leave layout nil. The caller routes
            // XObjects + saliency through `extractFallbackFigures`
            // so the reflow's non-region-aware path still
            // processes body text.
            return nil
        }
        let xobjectBoxes = xobjectFigures.map(\.box)
        var out: [LayoutRegion] = []
        for region in surya {
            if region.kind == .picture {
                let overlapsXObject = xobjectBoxes.contains { xbox in
                    Self.overlapFraction(of: region.box, with: xbox) >= 0.5
                }
                if overlapsXObject { continue }
            }
            out.append(region)
        }
        let baseOrder = out.map(\.readingOrder).max() ?? -1
        for (idx, box) in xobjectBoxes.enumerated() {
            out.append(LayoutRegion(
                kind: .picture, box: box,
                readingOrder: baseOrder + 1 + idx, confidence: 1.0
            ))
        }
        return out
    }

    /// Fraction of `a`'s area covered by its intersection with `b`.
    /// Symmetric replacement for `CGRect.intersects` when we care
    /// "how much of the smaller region is inside the other."
    static func overlapFraction(of a: CGRect, with b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, a.width > 0, a.height > 0 else { return 0 }
        return (intersection.width * intersection.height)
            / (a.width * a.height)
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
        // Per-conversion capture store. Only allocated when
        // `emitDebugLog` is on so production conversions don't pay
        // the (admittedly trivial) per-page lock+append cost.
        let claudePageCaptures: CapturedResponseStore? =
            options.emitDebugLog ? CapturedResponseStore() : nil
        // Mutable so we can periodically reload to drain PDFKit's
        // internal page cache. PDFKit `PDFDocument` lazily caches
        // rendered page representations; on a 600-page book that
        // cache pushes resident memory into the GB range. Dropping
        // and re-loading from URL is the only public way to flush.
        var pdf = try loader.load(pdfURL)
        let totalPages = pdf.pageCount
        // Pull the PDF's outline (publisher-set bookmarks) once, up
        // front. Used by `PDFOutlineSplitter` as the highest-
        // confidence chapter-boundary source. Empty array when the
        // PDF carries no outline — common for scanned books — and
        // the splitter chain falls through to the parsed-TOC /
        // heuristic paths in that case.
        let pdfOutline = PDFOutlineExtractor.extract(from: pdf.document)
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
        // Staging-dir resolution + resume-manifest validation.
        //  * emitDebugLog + debugStagingURLOverride → use the override
        //    (configured-output-folder feature routes here so logs
        //    land in <root>/Logs/<basename>.humanist-debug/).
        //  * emitDebugLog only → next to the EPUB output, named
        //    `<basename>.humanist-debug` (inspect-friendly).
        //  * default → next to the source PDF, named
        //    `<basename>.humanist-staging` (resume-friendly: re-runs
        //    of the same source find the same checkpoints).
        // Manifest mismatch (different source, page count, schema, or
        // mode) wipes the dir and starts fresh — mixing cascade- and
        // page-ocr-shaped checkpoints would produce a chimera EPUB.
        let stagingPlan = try StagingPlan.resolve(
            pdfURL: pdfURL, outputURL: outputURL,
            options: options, totalPages: pdf.pageCount
        )
        let stagingDir = stagingPlan.directory
        let resumeManager = stagingPlan.manager
        let alreadyDonePages = stagingPlan.alreadyDonePages

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
        // shared across pages. Each one is independently nil unless
        // `processingMode == .cloud`, its feature flag is on, and an
        // API key is configured. The cascade + post-loop stages fall
        // back to local-only when any of those conditions fail.
        let claudeEngines = ClaudeEngines.make(
            options: options, captures: claudePageCaptures
        )
        let claudeBudget = claudeEngines.budget
        let claudeOCREngine = claudeEngines.ocr
        let googleDocumentOCREngine = claudeEngines.googleDocumentOCR
        let claudePostProcessor = claudeEngines.postProcessor
        let claudeTOCParser = claudeEngines.tocParser
        let claudeTableExtractor = claudeEngines.tableExtractor
        let activePageEngine = claudeEngines.pageEngine
        let claudeBatchPageEngine = claudeEngines.claudeBatchPageEngine

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
        // `activePageEngine` is non-nil; consumed at the reflow step
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
        // Tier 9 / E-Parallel deferred-append: page-OCR pages get
        // collected during the for-loop and dispatched concurrently
        // after, then assembled in document order. Empty when not
        // in page-OCR mode.
        var pageOCRPageIndices: [Int] = []
        var pageOCRPendingByIndex: [Int: PendingPageOCR] = [:]

        for i in 0..<totalPages {
            try Task.checkCancellation()

            // Resume fast path: this page has a checkpoint on disk
            // from a prior (interrupted) run. Load it, restore the
            // accumulators, skip all the expensive per-page work.
            // Tier 9 / V-Trust-PerPage: force-OCR pages skip
            // checkpoint resume so a re-run with new force ranges
            // actually re-processes the affected pages instead of
            // silently using the previous run's verdict.
            if alreadyDonePages.contains(i),
               !options.shouldForceOCR(forPageIndex: i),
               let checkpoint = resumeManager.readCheckpoint(forPage: i) {
                // Page-OCR resume path: checkpoint stores the parsed
                // [Block] / [Footnote] slice from a prior Sonnet
                // call. Build a `PendingPageOCR` from the
                // checkpoint and route through the same
                // post-loop assembly the dispatch path uses, so
                // sparse checkpoints (pages 0, 2, 4 done; 1, 3
                // need fresh processing) still emit in document
                // order. Asset IDs are assigned during assembly
                // — they're not checkpointed because they depend
                // on document-order accumulation.
                if let blocks = checkpoint.pageBlocks {
                    let anchorId = RegionAwareReflow.anchorId(forPageIndex: i)
                    let bounds = CGSize(
                        width: checkpoint.pageBoundsWidth,
                        height: checkpoint.pageBoundsHeight
                    )
                    let pending = PendingPageOCR(
                        pageIndex: i,
                        anchorId: anchorId,
                        pageBoundsCG: bounds,
                        blocks: blocks,
                        footnotes: checkpoint.pageFootnotes ?? [],
                        figures: checkpoint.figures,
                        verdict: checkpoint.verdict.flatMap {
                            EmbeddedTextQualityScorer.Verdict(rawValue: $0)
                        } ?? .reocr,
                        qualityScore: nil,
                        extractorDiagnostics: nil,
                        // Resumed from disk — the original call's
                        // status isn't checkpointed. Treat as
                        // `.succeeded` since the page made it to
                        // checkpoint (we only checkpoint successful
                        // pages); refusal-rate stats ignore resumed
                        // pages.
                        pageOCRStatus: .succeeded,
                        providerId: "",
                        usedLocalFallback: false
                    )
                    pageOCRPendingByIndex[i] = pending
                    pageOCRPageIndices.append(i)
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

            // Phase 2 hidden flag: end-to-end Claude page OCR.
            // Defers per-page work to the post-loop dispatch so
            // pages can run via a bounded TaskGroup with the
            // `parallelPageOCRConcurrency` setting (Tier 9 /
            // E-Parallel). Concurrency=1 preserves the original
            // serial rhythm.
            if activePageEngine != nil {
                pageOCRPageIndices.append(i)
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

            // `forceOCR` (and per-page `forceOCRPageRanges`)
            // override the scorer's `.trust` verdict. The scorer's
            // score/diagnostics are still recorded (`qualityScores`
            // already populated above) so the debug log shows what
            // *would* have happened — but the dispatch always takes
            // the `.reocr` branch.
            let effectiveVerdict: EmbeddedTextQualityScorer.Verdict =
                options.shouldForceOCR(forPageIndex: i) ? .reocr : quality.verdict
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
                //
                // Snapshot `pdf` to an immutable local: it's a `var`
                // outside the loop because of the periodic-reload
                // pattern, and `async let` can't capture mutable
                // bindings. `LoadedPDF` is a class, so the snapshot
                // and the original reference the same instance.
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
                    ocrErrors[i] = trail
                }
                observations = gapFiller.fill(
                    visionObservations: result.observations,
                    embeddedLines: extracted.lines
                )
                pageBounds = initialPageBounds
                confidenceForProgress = result.meanConfidence

                layoutForPage = layoutOutcome.layout
                if let err = layoutOutcome.error {
                    layoutErrors[i] = err
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
                    figureExtractionsByPage[i, default: []]
                        .append(contentsOf: fallbackFigures)
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
                            documentAIEngine: googleDocumentOCREngine,
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

        // Tier 9 / E-Parallel: dispatch page-OCR pages collected
        // during the for-loop. Bounded TaskGroup driven by the
        // `parallelPageOCRConcurrency` setting; concurrency=1 keeps
        // the original serial rhythm. Each task returns a
        // `PendingPageOCR` we slot into the dict by index.
        if let pageEngine = activePageEngine, !pageOCRPageIndices.isEmpty {
            let concurrency = max(
                1, options.cloudFeatures.parallelPageOCRConcurrency
            )
            // Pages already populated from a checkpoint restore
            // (during the for-loop above) skip dispatch — their
            // PendingPageOCR is already in the dict. Fresh pages
            // get dispatched concurrently.
            let freshIndices = pageOCRPageIndices.filter {
                pageOCRPendingByIndex[$0] == nil
            }
            // Tier 9 / E-Batches step 2: when the toggle is on AND
            // Claude is the active page-OCR provider, dispatch all
            // fresh Sonnet calls as a single Anthropic Messages
            // Batches API request — 50% input/output token discount
            // in exchange for async wall time. Gemini has no equivalent
            // batch path, so a Gemini-selected run silently falls back
            // to the synchronous TaskGroup dispatch even when
            // useBatchAPI is on. Trust-routed pages still skip the
            // network entirely; figure extraction runs per page in
            // parallel.
            if options.cloudFeatures.useBatchAPI && !freshIndices.isEmpty,
               let claudeBatchEngine = claudeBatchPageEngine,
               let key = options.anthropicAPIKeyProvider(),
               !key.isEmpty {
                try await dispatchPageOCRViaBatch(
                    freshIndices: freshIndices,
                    pdf: pdf,
                    options: options,
                    stagingDir: stagingDir,
                    pageEngine: claudeBatchEngine,
                    figureExtractor: figureExtractor,
                    apiKey: key,
                    progress: progress,
                    totalPages: totalPages,
                    pendingByIndex: &pageOCRPendingByIndex
                )
            } else {
            try await withThrowingTaskGroup(of: PendingPageOCR.self) { group in
                var nextSubmit = 0
                var inflight = 0
                while nextSubmit < freshIndices.count || inflight > 0 {
                    while inflight < concurrency
                        && nextSubmit < freshIndices.count {
                        let pageIndex = freshIndices[nextSubmit]
                        nextSubmit += 1
                        // Bind everything the task needs into local
                        // values so the addTask closure captures no
                        // self-isolated state. `runPageOCRPage` is
                        // `nonisolated`, so the bound method reference
                        // is safe to send across the boundary.
                        // `pdf` snapshotted to a `let` because the
                        // outer binding is `var` (periodic-reload
                        // pattern); LoadedPDF is a class so this is
                        // a reference copy.
                        let perform = self.runPageOCRPage
                        let pdfRef = pdf
                        group.addTask { @Sendable in
                            try await perform(
                                pageIndex,
                                pdfRef,
                                options,
                                stagingDir,
                                pageEngine,
                                figureExtractor
                            )
                        }
                        inflight += 1
                    }
                    if let p = try await group.next() {
                        inflight -= 1
                        pageOCRPendingByIndex[p.pageIndex] = p
                        // Progress: report how many of the page-OCR
                        // pages have completed. Mixed with cascade
                        // progress in the main loop above this would
                        // double-count, so this is a separate phase.
                        progress?(Progress(
                            totalPages: totalPages,
                            completedPages: pageOCRPendingByIndex.count,
                            currentPageMeanConfidence: 1.0
                        ))
                    }
                }
            }
            }
            // Document-ordered assembly: walk page-OCR indices in
            // ascending order (the for-loop above appended them in
            // order, but sort defensively in case future code adds
            // skips), append anchor + blocks + footnotes + figures
            // (assigning sequential asset IDs), update verdict /
            // quality / diagnostics dicts, write checkpoint.
            for i in pageOCRPageIndices.sorted() {
                guard let pending = pageOCRPendingByIndex[i] else { continue }
                claudePageBlocks.append(.anchor(
                    id: pending.anchorId, label: "Page \(i + 1)"
                ))
                claudePageAnchors.append(PageAnchor(
                    pdfPage: i, anchorId: pending.anchorId
                ))
                claudePageBlocks.append(contentsOf: pending.blocks)
                claudePageFootnotes.append(contentsOf: pending.footnotes)
                for fig in pending.figures {
                    let (_, asset, figureBlock) =
                        buildPageOCRFigureAsset(
                            fig: fig,
                            index: claudePageNextAssetIndex
                        )
                    claudePageNextAssetIndex += 1
                    claudePageFigureAssets.append(asset)
                    claudePageBlocks.append(figureBlock)
                }
                verdictsByPage[i] = pending.verdict
                if let q = pending.qualityScore { qualityScores[i] = q }
                if let d = pending.extractorDiagnostics {
                    extractorDiagnostics[i] = d
                }
                // Skip checkpoint for failed Sonnet pages — re-runs
                // should retry them. Trust-routed pages always
                // checkpoint (they have content even though Sonnet
                // didn't run).
                if pending.sonnetSucceeded
                    && (!pending.blocks.isEmpty || !pending.footnotes.isEmpty) {
                    let checkpoint = PageCheckpoint(
                        pageIndex: i,
                        pageBoundsWidth: pending.pageBoundsCG.width,
                        pageBoundsHeight: pending.pageBoundsCG.height,
                        observations: [],
                        layoutRegions: nil,
                        figures: pending.figures,
                        tableExtractionsByRegionIndex: [:],
                        verdict: pending.verdict.rawValue,
                        correctionTrailEntries: [],
                        pageBlocks: pending.blocks,
                        pageFootnotes: pending.footnotes
                    )
                    try? resumeManager.writeCheckpoint(checkpoint)
                }
            }
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

        // Bilingual facing-page detection (Loeb Classical Library
        // style). Runs after OCR is complete so we score the actual
        // page text — DocumentProfiler's pre-flight result only
        // sees embedded text and would miss scanned bilinguals.
        // Returns nil for the common monolingual case, in which
        // case the EPUB builder falls through to its normal path.
        let bilingualLayout = BilingualLayoutDetector.detect(
            pageResults: pageResults
        )

        // Pass 2 — reflow (and optionally a debug log of every observation's fate).
        let reflowed: ReflowOutput
        if activePageEngine != nil {
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
            // Cloud Page-OCR bypasses the reflow path's debug-log
            // emission; dump the captured Sonnet responses here so
            // the user can inspect what the model returned per page
            // even when the assembly never touches RegionAwareReflow.
            // ALWAYS write the file when emitDebugLog is on, even
            // when the captures array is empty — an empty file with
            // a "no responses captured" banner is itself a
            // diagnostic (tells the user the engine never ran or
            // every page short-circuited before recording).
            if options.emitDebugLog {
                let pageResponses = claudePageCaptures?.snapshot() ?? []
                let dumpURL = stagingDir.appendingPathComponent(
                    "claude-pages.txt"
                )
                try? Self.writeClaudePageResponses(
                    pageResponses, to: dumpURL
                )
            }
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

        let assembled = await Self.assembleBook(
            reflowed: reflowed,
            parsedTOC: await parsedTOCTask?.value,
            pdfOutline: pdfOutline,
            dictionaryCorrector: dictionaryCorrector,
            options: options,
            budget: claudeBudget,
            title: title,
            language: language,
            sourceURL: pdfURL,
            bilingualLayout: bilingualLayout
        )
        var book = assembled.book
        let appliedTOC = assembled.appliedTOC

        // P-Sonnet-Structure (missed-break pass). Optional Sonnet
        // pass that reads the full text of each existing chapter
        // and proposes NEW chapter breaks the local splitter missed
        // — front-matter to body transitions, body to back-matter
        // transitions, titles set in regular type. Runs BEFORE the
        // validator below so the validator sees the augmented
        // chapter list and can still reject false adds. Same
        // Cloud-feature gating as the other Sonnet passes.
        if let detector = Self.makeClaudeChapterBreakDetector(
            options: options, budget: claudeBudget
        ) {
            book.chapters = await detector.analyzeAndApply(
                chapters: book.chapters
            )
        }

        // P-Sonnet-Structure (chapter pass). Optional Sonnet pass
        // that validates the local splitter's chapter list and
        // refines titles / `epub:type`. Rejected breaks merge
        // backwards into the previous chapter; the breaking content
        // becomes a section heading inside the merged chapter.
        // Same factory gate as the other Cloud features — opted in
        // via `cloudFeatures.chapterStructurePass`, no-op when the
        // toggle is off / no API key / not in Cloud mode.
        if let analyzer = Self.makeClaudeChapterStructureAnalyzer(
            options: options, budget: claudeBudget
        ) {
            book.chapters = await analyzer.analyzeAndApply(
                chapters: book.chapters
            )
        }

        // P-Sonnet-Structure (bundled front/back-matter pass).
        // Runs AFTER the validator so candidate selection sees
        // refined `epub:type` values. Targeted: only scans chapters
        // whose epub:type marks them as front-matter / back-matter
        // and proposes splits when one chapter bundles multiple
        // distinct sections (Dedication + Epigraph + Preface, etc).
        // Cheap (~$0.05–$0.10/book) because the candidate set is
        // small.
        if let splitter = Self.makeClaudeFrontBackMatterSplitter(
            options: options, budget: claudeBudget
        ) {
            book.chapters = await splitter.analyzeAndApply(
                chapters: book.chapters
            )
        }

        // Dump the chapter-shape decision summary alongside the
        // reflow log. The two together explain why the EPUB has the
        // chapter structure it does — `log.txt` shows per-block
        // classification, `chapters.txt` shows the
        // promoter/splitter decisions that turned blocks into the
        // chapter break list.
        if options.emitDebugLog {
            let chaptersURL = stagingDir.appendingPathComponent("chapters.txt")
            try? Self.writeChapterDecisionLog(
                promoter: assembled.chapterPromoterDiagnostics,
                splitter: assembled.chapterSplitterDiagnostics,
                tocDriven: assembled.tocDrivenSplitterDiagnostics,
                outline: assembled.outlineSplitterDiagnostics,
                chapters: book.chapters,
                to: chaptersURL
            )
        }

        // Cover-from-page-0. Render the first PDF page as a JPEG
        // raster and attach it to chapter[0] as the dedicated
        // cover-image asset. The EPUB writer stamps
        // `properties="cover-image"` on this manifest item via
        // FigureAsset.isCover, and because no Block.figure
        // references its id, the cover doesn't render inline —
        // it shows in library views, on first-open, etc.
        //
        // Unconditional: works for text-first-pages too (book
        // title typography, ToC, etc.) — those still make a
        // recognizable cover when rasterized. Replaces the prior
        // conservative "page-0 dominant picture region ≥ 50%"
        // heuristic which rarely fired.
        if let coverAsset = Self.renderPDFPage0AsCover(pdf: pdf),
           !book.chapters.isEmpty {
            book.chapters[0].figureAssets.insert(coverAsset, at: 0)
        }

        let trail = correctionTrailEntries.isEmpty
            ? nil
            : CorrectionTrail(entries: correctionTrailEntries)
        try Self.writeOutputs(
            book: book,
            correctionTrail: trail,
            appliedTOC: appliedTOC,
            pageResults: pageResults,
            pdfURL: pdfURL,
            outputURL: outputURL,
            options: options,
            bilingualLayout: assembled.bilingualLayout
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
        // Q-Refused-Fallback-Surface (2026-05-12): count pages
        // where the Claude page-OCR path declined or errored and
        // the pipeline fell back to local Vision OCR. Lets the
        // user see "8 pages fell back to Vision" in the
        // post-conversion summary instead of silently absorbing
        // the quality degradation.
        let visionFallback = pageOCRPendingByIndex.values.filter {
            $0.usedLocalFallback
        }.count
        // Q-Refusal-Rate (2026-05-14): split the fallback bucket by
        // cause so the user can see refusal rate (the headline) vs
        // empty responses vs API errors. Page-OCR only; cascade
        // refusals aren't tracked yet.
        var refused = 0
        var emptyResp = 0
        var apiError = 0
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
            pagesRefused: refused,
            pagesEmpty: emptyResp,
            pagesAPIError: apiError,
            refusedPageIndices: refusedIndicesCapped,
            pageOCRProviderId: providerId,
            claudeCallCount: claudeCallCount,
            claudeUsageByModel: claudeUsage
        )
    }

    /// Assembled book ready for the output stage: the `Book` itself
    /// plus the TOC that survived the title-applier (with its
    /// inferred PDF-page offset stamped in, when one was learned).
    struct AssembledBook {
        let book: Book
        let appliedTOC: ParsedTOC?
        /// Decision summary from `ChapterSplitter` — heading counts
        /// per level, eligible-break count, per-filter reasons. Used
        /// by the debug log to explain why splitting produced the
        /// chapter shape it did. Empty when the TOC-driven splitter
        /// ran instead (check `tocDrivenSplitterDiagnostics` first).
        let chapterSplitterDiagnostics: ChapterSplitter.Diagnostics
        /// Promotion summary from `ChapterHeadingPromoter` — every
        /// paragraph block that got upgraded to an H2 heading, with
        /// the fused-title text when applicable.
        let chapterPromoterDiagnostics: ChapterHeadingPromoter.Diagnostics
        /// Decision summary from `TOCDrivenSplitter` when it ran
        /// in lieu of the heuristic splitter. Nil when the
        /// heuristic path won (no parsed TOC, or TOC alignment
        /// confidence below threshold).
        let tocDrivenSplitterDiagnostics: TOCDrivenSplitter.Diagnostics?
        /// Decision summary from `PDFOutlineSplitter` when the
        /// outline path won. Non-nil iff the source PDF carried
        /// usable bookmarks; trumps both TOCDriven and the
        /// heuristic splitter's diagnostics in the debug log.
        let outlineSplitterDiagnostics: PDFOutlineSplitter.Diagnostics?
        /// Facing-page bilingual layout detected post-OCR (Loeb
        /// Classical Library style). Nil for the common
        /// monolingual case; non-nil triggers cross-link
        /// `data-facing-page` attributes on the emitted page
        /// anchors. Phase (b) — parallel chapter-tree
        /// reorganization — also keys off this value.
        let bilingualLayout: BilingualLayoutDetector.Layout?
    }

    /// Take a reflowed block stream and produce a `Book` ready to
    /// hand to `writeOutputs`. Runs (in order):
    ///   1. dictionary-match cleanup
    ///   2. typography normalization (ligatures, soft hyphens,
    ///      em/en-dash collapse)
    ///   3. `ChapterSplitter` → multi-chapter Book IR
    ///   4. printed-TOC title override (when Haiku parsed one)
    ///   5. semantic chapter classification (`epub:type`)
    ///   6. Q-Coherence pass (recurring OCR-error rewrites)
    ///   7. front-matter metadata extraction (title / author /
    ///      year / publisher / ISBN)
    ///
    /// Each Cloud-mode step short-circuits to the local-only
    /// fallback when its engine is nil (mode/feature/key gate).
    static func assembleBook(
        reflowed: ReflowOutput,
        parsedTOC: ParsedTOC?,
        pdfOutline: [OutlineEntry] = [],
        dictionaryCorrector: DictionaryCorrector,
        options: Options,
        budget: ClaudeCallBudget,
        title: String,
        language: BCP47,
        sourceURL: URL? = nil,
        bilingualLayout: BilingualLayoutDetector.Layout? = nil
    ) async -> AssembledBook {
        // 1 + 2: dictionary cleanup, then typography pass.
        // Dictionary runs first so it sees pre-normalized forms
        // (some dictionary entries match ligature characters as-is);
        // both run **after** reflow so cross-line / cross-page word
        // joins are already resolved before either touches a token.
        let dehyphenated = applyDictionaryToBlocks(
            reflowed.blocks, corrector: dictionaryCorrector
        )
        let cleanBlocks = TypographyNormalizer.normalize(dehyphenated)

        // 2.5: pattern-based chapter-marker promotion. Surya's
        // layout model misses chapter starts when they're set in
        // body-size or small-caps type (common in mid-century
        // academic editions). This pass scans the flat block stream
        // for paragraphs matching `CHAPTER 1`, `PART ONE`, `I.
        // INTRODUCTION`, etc. and upgrades them to H2 headings so
        // ChapterSplitter has something to break on. Conservative
        // by design: a missed promotion preserves today's "one
        // chapter" output, but a false-positive creates a bogus
        // chapter the user has to fix manually.
        let promotion = ChapterHeadingPromoter.promote(blocks: cleanBlocks)
        let promotedBlocks = promotion.blocks

        // 3: split into chapters. Strategy dispatch in order of
        // confidence:
        //   * **PDF outline** (when the source PDF carries
        //     publisher-set bookmarks — ~73% of professionally-
        //     published books). Authoritative: real PDF page
        //     indices, no offset learning needed.
        //   * **TOC-driven** (when a parsed printed TOC is
        //     available): title-matching against OCR'd headings
        //     first; page-offset learning as the fallback. Catches
        //     scanned books that have a printed contents page but
        //     no PDF outline.
        //   * **Heuristic `ChapterSplitter`** (fallback): dominant-
        //     heading-level detection. Used when no outline and
        //     no parseable TOC, or when the TOC has too few
        //     entries to drive a confident split.
        // Footnotes, page anchors, and figure assets get
        // distributed to whichever chapter they fall inside.
        let chapters: [Chapter]
        let appliedTOC: ParsedTOC?
        let splitDiagnostics: ChapterSplitter.Diagnostics
        let tocDrivenDiagnostics: TOCDrivenSplitter.Diagnostics?
        let outlineDiagnostics: PDFOutlineSplitter.Diagnostics?

        if let outlineSplit = PDFOutlineSplitter.split(
            blocks: promotedBlocks,
            footnotes: reflowed.footnotes,
            pageAnchors: reflowed.pageAnchors,
            figureAssets: reflowed.figureAssets,
            outline: pdfOutline
        ) {
            // Outline path won. Boundaries + titles came straight
            // from the PDF's bookmarks. The parsed TOC, if any,
            // still rides on `appliedTOC` so the editor's TOC
            // sidecar carries the printed-TOC entries for cross-
            // reference — they just didn't drive splits.
            chapters = outlineSplit.chapters
            appliedTOC = parsedTOC
            splitDiagnostics = ChapterSplitter.Diagnostics()
            tocDrivenDiagnostics = nil
            outlineDiagnostics = outlineSplit.diagnostics
        } else if let toc = parsedTOC,
           let tocSplit = TOCDrivenSplitter.split(
               blocks: promotedBlocks,
               footnotes: reflowed.footnotes,
               pageAnchors: reflowed.pageAnchors,
               figureAssets: reflowed.figureAssets,
               toc: toc,
               bookFallbackTitle: title
           ) {
            // TOC-driven path won. Titles are already applied (the
            // splitter consumed the TOC for both boundaries and
            // titles). Stamp the inferred offset on `appliedTOC`
            // for the editor sidecar.
            chapters = tocSplit.chapters
            appliedTOC = ParsedTOC(
                entries: toc.entries,
                inferredOffset: tocSplit.diagnostics.inferredOffset
            )
            splitDiagnostics = ChapterSplitter.Diagnostics()  // unused
            tocDrivenDiagnostics = tocSplit.diagnostics
            outlineDiagnostics = nil
        } else {
            // Heuristic path. Run the splitter, then apply the TOC
            // for title polish if one was parsed.
            let splitResult = ChapterSplitter.splitWithDiagnostics(
                blocks: promotedBlocks,
                footnotes: reflowed.footnotes,
                pageAnchors: reflowed.pageAnchors,
                figureAssets: reflowed.figureAssets,
                bookFallbackTitle: title
            )
            let rawChapters = splitResult.chapters
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
            splitDiagnostics = splitResult.diagnostics
            tocDrivenDiagnostics = nil
            outlineDiagnostics = nil
        }

        // 5: semantic classification (capped concurrency so a
        // 30-chapter book doesn't fan out 30 simultaneous calls).
        // Cloud Claude wins when configured + available; AFM
        // (on-device) is the Private-mode fallback under
        // L-Foundation-Models Phase 1.
        let classifiedChapters: [Chapter]
        if let classifier = Self.makeChapterClassifier(
            options: options, budget: budget
        ) {
            classifiedChapters = await classifyChapters(
                chapters: chapters, classifier: classifier
            )
        } else {
            classifiedChapters = chapters
        }

        // 6: Q-Coherence pass — one model call over a digest of
        // every chapter, returning guarded global rewrites. Runs
        // before metadata extraction so the extractor sees the
        // corrected text. Cloud Haiku wins when configured; AFM
        // is the Private-mode fallback under L-Foundation-Models
        // Phase 2.
        let coherenceCleaned: [Chapter]
        if let analyzer = Self.makeCoherenceAnalyzer(
            options: options, budget: budget
        ) {
            coherenceCleaned = await analyzer.analyzeAndApply(
                chapters: classifiedChapters
            )
        } else {
            coherenceCleaned = classifiedChapters
        }

        // 7: front-matter metadata. Updates the corresponding
        // `Book` fields when the extractor returns values. Cloud
        // Haiku wins when configured; AFM is the Private-mode
        // fallback under L-Foundation-Models Phase 2.
        let extracted: ClaudeMetadataExtractor.Result?
        if let extractor = Self.makeMetadataExtractor(
            options: options, budget: budget
        ) {
            let frontMatter = ClaudeMetadataExtractor.sampleFrontMatter(
                from: coherenceCleaned
            )
            extracted = await extractor.extract(frontMatterText: frontMatter)
        } else {
            extracted = nil
        }

        let book = Book(
            title: extracted?.title ?? title,
            author: extracted?.author,
            language: language,
            chapters: coherenceCleaned,
            year: extracted?.year,
            publisher: extracted?.publisher,
            isbn: extracted?.isbn,
            sourceURL: sourceURL
        )
        return AssembledBook(
            book: book,
            appliedTOC: appliedTOC,
            chapterSplitterDiagnostics: splitDiagnostics,
            chapterPromoterDiagnostics: promotion.diagnostics,
            tocDrivenSplitterDiagnostics: tocDrivenDiagnostics,
            outlineSplitterDiagnostics: outlineDiagnostics,
            bilingualLayout: bilingualLayout
        )
    }

    /// Write the conversion's three on-disk artifacts: the EPUB
    /// (canonical output), the optional `.txt` / `.md` / `.html`
    /// siblings, and the optional searchable-PDF copy. The EPUB
    /// write is the only one that throws; sibling + searchable-PDF
    /// failures are swallowed (they're convenience outputs and the
    /// canonical EPUB is already on disk).
    static func writeOutputs(
        book: Book,
        correctionTrail: CorrectionTrail?,
        appliedTOC: ParsedTOC?,
        pageResults: [PageObservations],
        pdfURL: URL,
        outputURL: URL,
        options: Options,
        bilingualLayout: BilingualLayoutDetector.Layout? = nil
    ) throws {
        // Translate the layout's (pdfPage → partner pdfPage) map
        // into the (anchorId → partner anchorId) form the EPUB
        // writer needs. Keeps the EPUB module free of Pipeline
        // types so the dependency direction stays one-way.
        let facingPageMap: [String: String]
        if let layout = bilingualLayout {
            var m: [String: String] = [:]
            for (page, partner) in layout.pagePartners {
                let anchor = RegionAwareReflow.anchorId(forPageIndex: page)
                let partnerAnchor = RegionAwareReflow.anchorId(forPageIndex: partner)
                m[anchor] = partnerAnchor
            }
            facingPageMap = m
        } else {
            facingPageMap = [:]
        }
        try EPUBBuilder().write(
            book: book,
            correctionTrail: correctionTrail,
            parsedTOC: appliedTOC,
            sourcePDFURL: pdfURL,
            facingPageMap: facingPageMap,
            to: outputURL
        )

        // Tier 9 / V-Outputs: emit `.txt` + `.md` + `.html` siblings
        // next to the EPUB. Best-effort. Sibling URLs default to
        // next-to-EPUB; the configured-output-folder feature routes
        // them into per-format subfolders by setting the overrides.
        // mkdir -p the parents either way since the user could pick
        // a fresh root with no subfolders yet.
        if options.emitSiblingTextOutputs {
            let txtURL = options.siblingTextURLOverride
                ?? outputURL.deletingPathExtension().appendingPathExtension("txt")
            let mdURL = options.siblingMarkdownURLOverride
                ?? outputURL.deletingPathExtension().appendingPathExtension("md")
            for url in [txtURL, mdURL] {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
            }
            try? PlainTextWriter.render(book).write(
                to: txtURL, atomically: true, encoding: .utf8
            )
            try? MarkdownWriter.render(book).write(
                to: mdURL, atomically: true, encoding: .utf8
            )
        }
        if options.emitSiblingDocuments {
            let htmlURL = options.siblingHTMLURLOverride
                ?? outputURL.deletingPathExtension().appendingPathExtension("html")
            let docxURL = options.siblingDOCXURLOverride
                ?? outputURL.deletingPathExtension().appendingPathExtension("docx")
            for url in [htmlURL, docxURL] {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
            }
            try? HTMLWriter.render(book).write(
                to: htmlURL, atomically: true, encoding: .utf8
            )
            try? DOCXWriter.write(book, to: docxURL)
        }

        // Tier 9 / V-PDF-Searchable: write a searchable copy of the
        // source PDF using the OCR observations the pipeline already
        // computed. Failures are non-fatal.
        if options.emitSearchablePDF {
            let pdfURLOut = options.searchablePDFURLOverride
                ?? outputURL.deletingPathExtension()
                    .appendingPathExtension("searchable.pdf")
            let pages = pageResults.map {
                SearchablePDFWriter.PageData(
                    pageIndex: $0.pageIndex,
                    observations: $0.observations
                )
            }
            try? SearchablePDFWriter().write(
                sourcePDFURL: pdfURL,
                pages: pages,
                to: pdfURLOut
            )
        }
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
        // Reflow diagnostics for the debug log. Empty (defaulted) on
        // the heuristic-only path, populated with per-page audit
        // trails on the layout path. Was previously read as a set of
        // static vars on RegionAwareReflow; now flows through the
        // Result struct.
        var reflowDiagnostics = RegionAwareReflow.Diagnostics()

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
            reflowDiagnostics = result.diagnostics
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
                reflowDiagnostics: reflowDiagnostics,
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
    /// Tier 9 / E-Parallel: per-page outcome from one trip through
    /// the page-OCR (Sonnet) path. Captures everything the
    /// post-loop assembly pass needs to populate `claudePage*`
    /// accumulators in document order, regardless of whether the
    /// pages were processed serially or via a concurrent TaskGroup.
    ///
    /// `sonnetSucceeded` tracks whether the Sonnet call returned
    /// usable content. Trust-routed pages (`verdict == .trust`)
    /// always set this to true since they emit reflowed embedded
    /// text. Sonnet failures (refusal / network / parse) set it to
    /// false and leave `blocks` / `footnotes` empty; the assembly
    /// pass uses this flag to decide whether to write a checkpoint
    /// (we don't checkpoint failed pages — re-runs should retry
    /// them).
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
        /// What the page-OCR provider did. `.succeeded` means blocks
        /// came from the provider directly; `.refused` / `.empty` /
        /// `.apiError` mean the provider failed and (possibly)
        /// Vision filled in (`usedLocalFallback`).
        let pageOCRStatus: ProviderStatus
        /// Which provider was invoked. Empty for trust-routed pages
        /// (no provider call). "claude" / "gemini-2.5-flash" etc.
        let providerId: String
        /// True when the provider failed for this page and the local
        /// Vision-OCR fallback produced blocks instead. Surfaced in
        /// the debug log so the user can see which pages didn't get
        /// the full provider treatment (typical causes: refusal,
        /// content-filter false positives, transient API overload).
        let usedLocalFallback: Bool

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
    private nonisolated func runPageOCRPage(
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
            // it, then fall back to local Vision OCR so the page
            // contributes *something* to the EPUB instead of going
            // blank. Quality is lower than provider output but beats
            // an empty page; the user can always Re-OCR a single page
            // from the editor if they want to retry the provider later.
            pageOCRStatus = pageEngine.classify(error: error)
            let hints = OCRHints(
                languages: options.languages,
                quality: options.ocrQuality
            )
            do {
                let visionResult = try await visionEngine.recognize(
                    image: image, hints: hints
                )
                let blocks = ParagraphReflow().reflow(
                    visionResult.observations
                )
                if !blocks.isEmpty {
                    sonnetBlocks = blocks
                    usedLocalFallback = true
                }
            } catch {
                // Vision also failed — leave the page empty. The
                // claude-pages.txt dump still records the original
                // provider error so the user can diagnose.
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
            usedLocalFallback: usedLocalFallback
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
    /// Trades wall time (~1-5 minutes typical, capped at 24h)
    /// for a 50% input + output token discount on the Sonnet
    /// calls. Figure extraction happens in Phase A so the page
    /// images don't need to stay alive across the batch wait.
    ///
    /// Falls back silently to the synchronous TaskGroup path on
    /// batch submission / poll / fetch failure — the caller
    /// observes empty `pendingByIndex` entries for affected
    /// pages and the assembly emits empty pages, same as
    /// per-page Sonnet failures.
    private func dispatchPageOCRViaBatch(
        freshIndices: [Int],
        pdf: LoadedPDF,
        options: Options,
        stagingDir: URL,
        pageEngine: ClaudePageOCREngine,
        figureExtractor: FigureExtractor,
        apiKey: String,
        progress: ProgressHandler?,
        totalPages: Int,
        pendingByIndex: inout [Int: PendingPageOCR]
    ) async throws {
        // Phase A: per-page prep. Trust-routed pages emit final
        // PendingPageOCR; Sonnet pages emit a partial pending +
        // a request-builder. Run in parallel since prep is I/O-
        // and-CPU bound (render + Surya + base64 encode).
        let concurrency = max(
            1, options.cloudFeatures.parallelPageOCRConcurrency
        )
        var prepared: [Int: BatchPrepared] = [:]
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
                }
            }
        }

        // Trust-routed pages are already fully populated;
        // settle them now so the assembly walk doesn't see them
        // as fresh-but-missing.
        for (i, p) in prepared where p.request == nil {
            pendingByIndex[i] = p.partial
        }

        // Phase B: build + submit batch from Sonnet pages.
        let sonnetEntries = freshIndices.compactMap { i -> (Int, AnthropicMessageRequest)? in
            guard let p = prepared[i], let req = p.request else { return nil }
            return (i, req)
        }
        guard !sonnetEntries.isEmpty else { return }

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
            apiKeyProvider: { apiKey }
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
            for (i, _) in sonnetEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            return
        }

        // Phase B continued: poll until done.
        let final: AnthropicBatchStatusResponse
        do {
            final = try await batchClient.awaitCompletion(
                batchId: submitted.id
            )
        } catch {
            for (i, _) in sonnetEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            return
        }
        guard let resultsURL = final.resultsUrl else {
            for (i, _) in sonnetEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            return
        }
        let results: [AnthropicBatchResultLine]
        do {
            results = try await batchClient.fetchResults(from: resultsURL)
        } catch {
            for (i, _) in sonnetEntries where pendingByIndex[i] == nil {
                if let p = prepared[i] { pendingByIndex[i] = p.partial }
            }
            return
        }

        // Phase C: walk results, parse each, fill in the
        // matching pending slot. Result order is unspecified;
        // we look up by custom_id.
        for line in results {
            guard let pageIndex = Self.pageIndexFromCustomId(line.customId)
            else { continue }
            guard let prep = prepared[pageIndex] else { continue }
            let parsedBlocks: [Block]
            let parsedFootnotes: [Footnote]
            let status: ProviderStatus
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
            case .errored, .canceled, .expired:
                parsedBlocks = []
                parsedFootnotes = []
                status = .apiError
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
            progress?(Progress(
                totalPages: totalPages,
                completedPages: pendingByIndex.count,
                currentPageMeanConfidence: 1.0
            ))
        }

        // Any Sonnet pages whose result didn't show up in the
        // JSONL (corrupt line, unknown custom_id) get their
        // partial as final so the page emits empty.
        for (i, _) in sonnetEntries where pendingByIndex[i] == nil {
            if let p = prepared[i] { pendingByIndex[i] = p.partial }
        }

        // Q-Vision-Backfill-Batch (2026-05-12): pages whose batch
        // result didn't produce usable blocks (refused, errored,
        // canceled, expired, or empty parse) get a Vision-OCR pass
        // so they contribute *something* to the EPUB instead of
        // going blank. Mirrors the sync path's per-page fallback
        // (see `runPageOCRPage`); the batches dispatch had this
        // TODO'd until now.
        let needsFallback = sonnetEntries
            .map(\.0)
            .filter { i in
                guard let pending = pendingByIndex[i] else { return true }
                return !pending.sonnetSucceeded && pending.blocks.isEmpty
            }
        guard !needsFallback.isEmpty else { return }
        let visionRenderer = PDFRenderer(dpi: options.dpi)
        let hints = OCRHints(
            languages: options.languages,
            quality: options.ocrQuality
        )
        for i in needsFallback {
            try Task.checkCancellation()
            guard let prep = prepared[i] else { continue }
            do {
                let image = try visionRenderer.renderPage(
                    at: i, of: pdf
                )
                let visionResult = try await visionEngine.recognize(
                    image: image, hints: hints
                )
                let blocks = ParagraphReflow().reflow(
                    visionResult.observations
                )
                guard !blocks.isEmpty else { continue }
                // Preserve the original failure status so refusal-rate
                // stats count this page correctly even though Vision
                // filled in the body.
                let priorStatus = pendingByIndex[i]?.pageOCRStatus
                    ?? .apiError
                pendingByIndex[i] = PendingPageOCR(
                    pageIndex: prep.partial.pageIndex,
                    anchorId: prep.partial.anchorId,
                    pageBoundsCG: prep.partial.pageBoundsCG,
                    blocks: blocks,
                    footnotes: prep.partial.footnotes,
                    figures: prep.partial.figures,
                    verdict: prep.partial.verdict,
                    qualityScore: prep.partial.qualityScore,
                    extractorDiagnostics: prep.partial.extractorDiagnostics,
                    pageOCRStatus: priorStatus,
                    providerId: pageEngine.providerId,
                    usedLocalFallback: true
                )
            } catch {
                // Vision also failed — leave the page empty.
                // Same posture as the sync path's nested catch.
            }
        }
    }

    /// Helper for `dispatchPageOCRViaBatch`. Does Phase A for
    /// one page: trust check (returns final pending if trust),
    /// else render + Surya layout + figure extraction + build
    /// Sonnet request (returns partial pending + request).
    /// `nonisolated` for the same reason as `runPageOCRPage` — called
    /// from a TaskGroup in the batch-API dispatch path; needs to be
    /// safely sendable as a closure.
    private nonisolated func preparePageForBatch(
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
    private static func pageIndexFromCustomId(_ customId: String) -> Int? {
        guard customId.hasPrefix("page-") else { return nil }
        return Int(customId.dropFirst("page-".count))
    }

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

    /// Rasterize PDF page 0 as a JPEG and wrap it in a
    /// FigureAsset stamped as the EPUB cover. The result lands
    /// in `book.chapters[0].figureAssets[0]` and the EPUB writer
    /// stamps `properties="cover-image"` on its manifest item.
    /// No `Block.figure` references the id, so the cover doesn't
    /// render inline — it surfaces only as the OPF cover-image.
    ///
    /// Renders at 150 dpi: on a typical 6×9" book page that's
    /// ~900×1350 px, under the EPUB 1600×2400 cover-size guidance
    /// while keeping per-book file size to ~100 KB. JPEG quality
    /// 0.85 — good enough for thumbnail / first-open use, far
    /// smaller than PNG for scanned/photographic content.
    ///
    /// Returns nil on any failure (load, encode); the EPUB writer
    /// proceeds without a cover, which is still valid.
    private static func renderPDFPage0AsCover(
        pdf: LoadedPDF
    ) -> FigureAsset? {
        guard pdf.pageCount > 0 else { return nil }
        let renderer = PDFRenderer(dpi: 150)
        guard let image = try? renderer.renderPage(at: 0, of: pdf)
        else { return nil }
        guard let data = encodeCoverJPEG(image, quality: 0.85)
        else { return nil }
        return FigureAsset(
            id: "cover-page-0",
            data: data,
            mediaType: "image/jpeg",
            intrinsicSize: CGSize(
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            ),
            isCover: true
        )
    }

    /// JPEG-encode a CGImage with the given quality (0...1).
    /// Returns nil on encoder failure. Used by the cover-from-
    /// page-0 path; could be reused for other figure assets if
    /// the pipeline ever wants JPEG output for scanned figures.
    private static func encodeCoverJPEG(
        _ image: CGImage, quality: CGFloat
    ) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1, nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
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
    private static func writeChapterDecisionLog(
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

    private static func writeClaudePageResponses(
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

    private static func writeDebugLog(
        pages: [PageObservations],
        classification: HeaderFooterClassifier.Result,
        blocks: [Block],
        extractorDiagnostics: [Int: EmbeddedTextExtractor.Diagnostics],
        qualityScores: [Int: EmbeddedTextQualityScorer.Score],
        layoutErrors: [Int: String],
        ocrErrors: [Int: String],
        footnotes: [Footnote],
        reflowDiagnostics: RegionAwareReflow.Diagnostics,
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

        let parsedByPage = reflowDiagnostics.footnotesPerPage
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
        let reclasByPage = reflowDiagnostics.reclassificationsPerPage
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
        let hfByPage = reflowDiagnostics.hfReclassificationsPerPage
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
        let crossPageByPage = reflowDiagnostics.crossPageDecisionsPerPage
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
        let splitsByPage = reflowDiagnostics.regionSplitsPerPage
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
        let promotionsByPage = reflowDiagnostics.headingPromotionsPerPage
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
                if let attr = reflowDiagnostics.attributions[key] {
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
            let lastRun = combinedRuns.last
            combinedRuns[combinedRuns.count - 1] = InlineRun(
                mergedTail,
                language: lastRun?.language,
                noterefId: lastRun?.noterefId,
                isItalic: lastRun?.isItalic ?? false,
                isBold: lastRun?.isBold ?? false
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
