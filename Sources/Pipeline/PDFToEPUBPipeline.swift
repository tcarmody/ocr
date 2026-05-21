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
        /// LandingAI ADE API key resolver (Agentic Document Extraction,
        /// `/v1/ade/parse`). Powers the optional `LandingAIDocumentEngine`
        /// (Stage 2.5 alternative to Google) and `LandingAITableExtractor`
        /// (prepended to the Cloud table-extractor chain). The Python SDK
        /// reads this key from `VISION_AGENT_API_KEY`; this provider
        /// returns the same string in Swift contexts. Nil/empty → both
        /// LandingAI features are skipped.
        public var landingAIAPIKeyProvider: @Sendable () -> String?
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
        /// User-asserted "this is a facing-page bilingual book"
        /// override. When true, `BilingualLayoutDetector` runs in
        /// forced mode: its alternation-rate, minimum-body-page,
        /// and classical-L1 gates are relaxed, and pages are
        /// paired by the dominant verso-recto orientation found
        /// even when the auto-detector would have given up. Use
        /// when auto-detection misses an edge case (heavy footnote
        /// pages breaking the alternation pattern, modern-language
        /// bilingual editions outside the classical L1 set, etc.).
        /// Default false — auto-detection still fires.
        public var forceBilingualFacingPage: Bool

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
            landingAIAPIKeyProvider: @escaping @Sendable () -> String? = { nil },
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
            debugStagingURLOverride: URL? = nil,
            forceBilingualFacingPage: Bool = false
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
            self.landingAIAPIKeyProvider = landingAIAPIKeyProvider
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
            self.forceBilingualFacingPage = forceBilingualFacingPage
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
        /// What the pipeline is doing while this progress was
        /// emitted. Defaults to `.processing` so every existing
        /// call site continues to work. The Batch API dispatch
        /// flips this to `.batchWaiting` after submitting so the
        /// queue UI can swap its bar for an indeterminate
        /// spinner during the poll wait (Anthropic documents
        /// most batches under an hour, hard cap 24 h).
        public var phase: Phase = .processing

        public enum Phase: Sendable, Equatable {
            /// Normal forward motion — bar fills with completed
            /// / total pages.
            case processing
            /// Anthropic Batch API submitted and we're polling
            /// for completion. `completedPages` is the Phase A
            /// high-water mark; the UI should treat that as
            /// "everything queued, waiting" rather than a
            /// partial percentage.
            case batchWaiting
        }
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void

    private let loader = PDFLoader()
    let visionEngine: any OCREngine
    let tesseractEngine: (any OCREngine)?
    let suryaEngine: (any OCREngine)?
    let layoutAnalyzer: SuryaLayoutAnalyzer?
    let tableExtractor: SuryaTableExtractor?
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
    nonisolated let embeddedExtractor = EmbeddedTextExtractor()
    let gapFiller = EmbeddedTextGapFiller()
    nonisolated let qualityScorer = EmbeddedTextQualityScorer()

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
        case .verse:
            // P-Verse-Layout: dictionary corrector skips verse
            // outright. Poetry routinely uses archaic spellings,
            // dialect, coined words, and foreign-language
            // fragments that the English wordlist would treat as
            // garblings. Same posture as the italic-skip guard
            // for prose: don't "correct" what isn't broken.
            return block
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
    func selectEngine(for languages: [BCP47], preferSurya: Bool) -> any OCREngine {
        if preferSurya, let suryaEngine { return suryaEngine }
        if let tesseractEngine, Self.shouldPreferTesseract(for: languages) {
            return tesseractEngine
        }
        return visionEngine
    }

    /// Pick the local engine to use when a Cloud page-OCR call
    /// (Sonnet / Gemini) refuses or errors and we need to backfill
    /// the page so it isn't blank in the EPUB. Tesseract wins for
    /// the languages where it outperforms Vision (polytonic Greek,
    /// classical Latin, vocalized Hebrew, Arabic with diacritics,
    /// Syriac / Coptic / Old Church Slavonic, CJK, Cyrillic — same
    /// set `selectEngine` uses for the primary cascade route).
    /// Vision is the default for everything else.
    ///
    /// Returns `nil` when neither engine is available — the caller
    /// drops the page (rare; Vision is always present on macOS).
    /// `nonisolated` so the page-OCR TaskGroup can call it without
    /// hopping isolation.
    nonisolated func selectLocalFallbackEngine(
        for languages: [BCP47]
    ) -> (engine: any OCREngine, id: String)? {
        if let tesseractEngine,
           Self.shouldPreferTesseract(for: languages) {
            return (tesseractEngine, "tesseract")
        }
        return (visionEngine, "vision")
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
    func ocrPageWithFallback(
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
    func analyzeLayoutWithRetry(
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
    func extractFallbackFigures(
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
        let landingAIDocumentEngine = claudeEngines.landingAIDocument
        let claudePostProcessor = claudeEngines.postProcessor
        let claudeTOCParser = claudeEngines.tocParser
        let claudeTableExtractor = claudeEngines.tableExtractor
        let landingAITableExtractor = claudeEngines.landingAITableExtractor
        let activePageEngine = claudeEngines.pageEngine
        let claudeBatchPageEngine = claudeEngines.claudeBatchPageEngine
        let geminiBatchPageEngine = claudeEngines.geminiBatchPageEngine

        // Dictionary-match cleanup. Built unconditionally so we
        // can hand it to `assembleBook`, but the assembly step
        // decides whether to actually apply it based on whether
        // an LM-based post-OCR cleanup (Cloud Haiku or AFM) will
        // run — when one will, that pass handles the same
        // garblings with full-sentence context and the dictionary
        // pass's foreign-cognate false-positive risk isn't worth
        // running. The check happens in `assembleBook` so
        // ConversionStats sees an accurate "ran / skipped"
        // accounting if we add one later.
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

        // P-Cascade-Parallel Phase B. When concurrency > 1 AND we're
        // on the cascade path (no `activePageEngine`), defer per-
        // page cascade work to a post-loop bounded TaskGroup so 2–8
        // cascade pages can render+OCR concurrently. Concurrency=1
        // preserves the original serial inline path bit-for-bit.
        let cascadeConcurrency = max(
            1, options.cloudFeatures.parallelPageOCRConcurrency
        )
        let useParallelCascade =
            activePageEngine == nil && cascadeConcurrency > 1
        var cascadeFreshIndices: [Int] = []

        // Get the queue UI off "Starting…" as soon as we know the
        // page count. Without this, the page-OCR batch path (which
        // only emits progress in Phase C after results return) and
        // the page-OCR sync path on a fresh book with slow first-
        // page Surya warmup can both leave the row showing
        // "Starting…" for minutes — indistinguishable from a hang.
        progress?(Progress(
            totalPages: totalPages,
            completedPages: 0,
            currentPageMeanConfidence: 0
        ))

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

            // P-Cascade-Parallel Phase B: at concurrency > 1, defer
            // cascade-bound fresh pages to the post-loop bounded
            // TaskGroup below. The serial concurrency=1 path keeps
            // calling `processCascadePage` inline, preserving the
            // original rhythm + PDFKit-cache-drain reload pattern
            // for the default case.
            if useParallelCascade {
                cascadeFreshIndices.append(i)
                continue
            }

            // P-Cascade-Parallel Phase A: cascade body extracted
            // into `processCascadePage`. Serial for-loop path.
            // Unpacking re-writes the outcome bundle into the same
            // outer accumulators the inline body used to mutate
            // directly.
            let outcome = try await processCascadePage(
                pageIndex: i,
                pdf: pdf,
                options: options,
                stagingDir: stagingDir,
                renderer: renderer,
                pagePreprocessor: pagePreprocessor,
                hints: hints,
                figureExtractor: figureExtractor,
                googleDocumentOCREngine: googleDocumentOCREngine,
                landingAIDocumentEngine: landingAIDocumentEngine,
                claudeOCREngine: claudeOCREngine,
                claudePostProcessor: claudePostProcessor,
                claudeTableExtractor: claudeTableExtractor,
                landingAITableExtractor: landingAITableExtractor
            )
            extractorDiagnostics[i] = outcome.extractorDiagnostics
            qualityScores[i] = outcome.qualityScore
            verdictsByPage[i] = outcome.verdict
            if !outcome.figures.isEmpty {
                figureExtractionsByPage[i] = outcome.figures
            }
            for entry in outcome.tableEntries {
                let key = CaptionAssociator.PageRegionKey(
                    pageIndex: i, regionIndex: entry.regionIndex
                )
                tableExtractionsByKey[key] = entry.rows
            }
            correctionTrailEntries.append(
                contentsOf: outcome.correctionTrailEntries
            )
            if let err = outcome.layoutError {
                layoutErrors[i] = err
            }
            if let err = outcome.ocrError {
                ocrErrors[i] = err
            }

            pageResults.append(outcome.pageObservations)

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
                pageBoundsWidth: outcome.pageObservations.pageBounds.width,
                pageBoundsHeight: outcome.pageObservations.pageBounds.height,
                observations: outcome.pageObservations.observations,
                layoutRegions: outcome.pageObservations.layoutRegions,
                figures: pageFigures,
                tableExtractionsByRegionIndex: pageTables,
                verdict: verdictsByPage[i]?.rawValue,
                correctionTrailEntries: pageTrail
            )
            try? resumeManager.writeCheckpoint(checkpoint)

            progress?(Progress(
                totalPages: totalPages,
                completedPages: i + 1,
                currentPageMeanConfidence: outcome.confidenceForProgress
            ))

            // Yield gives the runtime a chance to drain any pool
            // accumulated by the awaited Vision/Surya work above and
            // lets cancellation/UI updates propagate. Without this,
            // long-running convert tasks hold autoreleased temporaries
            // (Vision NSObject results, dispatch-bridged NSData) for
            // the entire conversion.
            await Task.yield()
        }

        // P-Cascade-Parallel Phase B: bounded TaskGroup dispatch of
        // cascade-bound fresh pages. Active only when concurrency
        // > 1 and we're on the cascade path. Tasks share the
        // existing `pdf` reference (same posture as the page-OCR
        // dispatch); unpack + checkpoint + progress emit happen on
        // the convert task as each `group.next()` returns so the
        // write side stays serialized.
        if useParallelCascade && !cascadeFreshIndices.isEmpty {
            // Progress baseline = pages already settled by the
            // for-loop's resume path (those emitted their own
            // progress with `completedPages: i + 1`). Without
            // capturing this, parallel completions would reset
            // the bar back to 0.
            let cascadeBaseline = alreadyDonePages.count
            var cascadeCompleted = 0
            try await withThrowingTaskGroup(
                of: (Int, CascadePageOutcome).self
            ) { group in
                var nextSubmit = 0
                var inflight = 0
                while nextSubmit < cascadeFreshIndices.count
                    || inflight > 0 {
                    while inflight < cascadeConcurrency
                        && nextSubmit < cascadeFreshIndices.count {
                        let pageIndex = cascadeFreshIndices[nextSubmit]
                        nextSubmit += 1
                        // Bind everything the closure needs into
                        // locals. `processCascadePage` is
                        // nonisolated; the bound method reference
                        // is safe to send across the boundary.
                        let perform = self.processCascadePage
                        let pdfRef = pdf
                        group.addTask { @Sendable in
                            try Task.checkCancellation()
                            let outcome = try await perform(
                                pageIndex,
                                pdfRef,
                                options,
                                stagingDir,
                                renderer,
                                pagePreprocessor,
                                hints,
                                figureExtractor,
                                googleDocumentOCREngine,
                                landingAIDocumentEngine,
                                claudeOCREngine,
                                claudePostProcessor,
                                claudeTableExtractor,
                                landingAITableExtractor
                            )
                            return (pageIndex, outcome)
                        }
                        inflight += 1
                    }
                    if let (i, outcome) = try await group.next() {
                        inflight -= 1
                        // Unpack — same writes the serial for-loop
                        // performed inline. All targets are dicts
                        // keyed by page index (or arrays whose
                        // consumers don't depend on order), so
                        // out-of-order completion is safe.
                        extractorDiagnostics[i] =
                            outcome.extractorDiagnostics
                        qualityScores[i] = outcome.qualityScore
                        verdictsByPage[i] = outcome.verdict
                        if !outcome.figures.isEmpty {
                            figureExtractionsByPage[i] = outcome.figures
                        }
                        for entry in outcome.tableEntries {
                            let key = CaptionAssociator.PageRegionKey(
                                pageIndex: i,
                                regionIndex: entry.regionIndex
                            )
                            tableExtractionsByKey[key] = entry.rows
                        }
                        correctionTrailEntries.append(
                            contentsOf: outcome.correctionTrailEntries
                        )
                        if let err = outcome.layoutError {
                            layoutErrors[i] = err
                        }
                        if let err = outcome.ocrError {
                            ocrErrors[i] = err
                        }
                        pageResults.append(outcome.pageObservations)

                        // Checkpoint right after unpack — matches
                        // the serial path so a crash mid-batch
                        // doesn't lose work.
                        let pageTrail = correctionTrailEntries
                            .filter { $0.pageIndex == i }
                        let pageFigures = figureExtractionsByPage[i]
                            ?? []
                        let pageTables: [Int: [[TableCell]]] =
                            tableExtractionsByKey
                                .filter { $0.key.pageIndex == i }
                                .reduce(into: [:]) {
                                    $0[$1.key.regionIndex] = $1.value
                                }
                        let checkpoint = PageCheckpoint(
                            pageIndex: i,
                            pageBoundsWidth:
                                outcome.pageObservations.pageBounds.width,
                            pageBoundsHeight:
                                outcome.pageObservations.pageBounds.height,
                            observations:
                                outcome.pageObservations.observations,
                            layoutRegions:
                                outcome.pageObservations.layoutRegions,
                            figures: pageFigures,
                            tableExtractionsByRegionIndex: pageTables,
                            verdict: verdictsByPage[i]?.rawValue,
                            correctionTrailEntries: pageTrail
                        )
                        try? resumeManager.writeCheckpoint(checkpoint)

                        cascadeCompleted += 1
                        progress?(Progress(
                            totalPages: totalPages,
                            completedPages:
                                cascadeBaseline + cascadeCompleted,
                            currentPageMeanConfidence:
                                outcome.confidenceForProgress
                        ))
                    }
                }
            }
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
            // Tier 9 / E-Batches step 2 + P-Gemini-Batch: when the
            // toggle is on, dispatch all fresh page-OCR calls as a
            // single batch — 50% input/output token discount in
            // exchange for async wall time. Provider-specific
            // dispatcher picked from `claudeBatchPageEngine` /
            // `geminiBatchPageEngine` (only one is non-nil per
            // run). When neither has a usable key, falls through
            // to the synchronous TaskGroup. Trust-routed pages
            // still skip the network entirely; figure extraction
            // runs per page in parallel within Phase A.
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
            } else if options.cloudFeatures.useBatchAPI && !freshIndices.isEmpty,
                      let geminiBatchEngine = geminiBatchPageEngine,
                      let key = options.geminiAPIKeyProvider(),
                      !key.isEmpty {
                try await dispatchGeminiPageOCRViaBatch(
                    freshIndices: freshIndices,
                    pdf: pdf,
                    options: options,
                    stagingDir: stagingDir,
                    pageEngine: geminiBatchEngine,
                    figureExtractor: figureExtractor,
                    apiKey: key,
                    modelId: geminiBatchEngine.model,
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
        // `forced` relaxes the alternation/L1 gates so user-asserted
        // bilingual books still get paired when the auto detector
        // would have given up.
        let bilingualLayout = BilingualLayoutDetector.detect(
            pageResults: pageResults,
            forced: options.forceBilingualFacingPage
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

        // C-Pipeline-File-Split: stats tally extracted into
        // `aggregateConversionStats` (PipelineStatsAggregation.swift).
        return await aggregateConversionStats(
            pageResults: pageResults,
            verdictsByPage: verdictsByPage,
            pageOCRPendingByIndex: pageOCRPendingByIndex,
            claudeBudget: claudeBudget,
            conversionStart: conversionStart
        )
    }



    /// Result of `reflow` — body block stream + chapter-level
    /// footnotes that body runs reference via `InlineRun.noterefId`,
    /// + page-boundary anchors emitted into the block stream so the
    /// editor can sync preview scroll with PDF page (Phase 7.D),
    /// + figure assets referenced by `Block.figure` blocks (Phase 6).

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

    static func writeDebugLog(
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
            case .verse(let lines):
                out += "[\(i)] VERSE lines=\(lines.count)\n"
                for (j, line) in lines.enumerated() {
                    let text = line.runs.map(\.text).joined()
                    out += "      [\(j)] indent=\(line.indent): \(text)\n"
                }
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
        // P-Verse-Layout: bridging is a prose-only concern. A
        // verse block sitting between two prose paragraphs
        // shouldn't be silently skipped over for sentence merging
        // — that would mash the surrounding prose together
        // *across* a stanza. Return false so the verse block
        // becomes a hard boundary.
        case .verse: return false
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
