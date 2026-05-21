import Foundation
import AI
import Document
import EPUB
import Layout
import OCR
import PDFIngest

// MARK: - C-Pipeline-File-Split Stage 2 (engine factories)
//
// Extracted from `PDFToEPUBPipeline.swift` 2026-05-18. Holds the
// Cloud-mode engine factory family (`makeClaudeEngine` + every
// `makeXxx` variant), the AFM-fallback factories
// (`makeMetadataExtractor` / `makePostProcessor` /
// `makeCoherenceAnalyzer` / `makeChapterClassifier`), the
// `CapturedResponseStore` debug-dump sink, and the `ClaudeEngines`
// bundle. Behavior-equivalent to the prior inline shape.
extension PDFToEPUBPipeline {

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

    /// Build the LandingAI ADE Stage-2.5 cascade engine — an
    /// alternative to `GoogleDocumentOCREngine` at the same slot.
    /// Gates on `processingMode == .cloud`, the `landingAIInCascade`
    /// feature flag, and a configured LandingAI key. When both this
    /// and the Google engine end up non-nil, the cascade prefers
    /// LandingAI (explicit opt-in beats the default).
    static func makeLandingAIDocumentEngine(
        options: Options, budget: ClaudeCallBudget
    ) -> LandingAIDocumentEngine? {
        guard options.processingMode == .cloud,
              options.cloudFeatures.landingAIInCascade,
              let key = options.landingAIAPIKeyProvider(),
              !key.isEmpty else { return nil }
        return LandingAIDocumentEngine(
            apiKeyProvider: { key }, budget: budget
        )
    }

    /// Build the LandingAI ADE table extractor. Gates on
    /// `processingMode == .cloud`, the `landingAITableExtraction`
    /// flag, and a configured LandingAI key. When non-nil it's
    /// prepended to the Cloud-mode extractor chain so it runs before
    /// Claude — ADE is purpose-built for tables.
    static func makeLandingAITableExtractor(
        options: Options, budget: ClaudeCallBudget
    ) -> LandingAITableExtractor? {
        guard options.processingMode == .cloud,
              options.cloudFeatures.landingAITableExtraction,
              let key = options.landingAIAPIKeyProvider(),
              !key.isEmpty else { return nil }
        return LandingAITableExtractor(
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
        /// Cascade Stage 2.5 — LandingAI ADE parse. Alternative to
        /// `googleDocumentOCR` at the same slot; when both happen to
        /// be non-nil (user enabled both toggles + supplied both keys)
        /// the cascade prefers this one. Nil when the toggle is off
        /// or no LandingAI key is configured.
        let landingAIDocument: LandingAIDocumentEngine?
        /// Post-OCR cleanup processor — Cloud (Haiku) or AFM
        /// depending on processingMode + feature toggles +
        /// runtime availability. Held as the protocol type so
        /// the cascade's `applyPostOCRCleanup` doesn't branch
        /// on which impl is active.
        let postProcessor: (any PostOCRProcessor)?
        let tocParser: ClaudeTOCParser?
        let tableExtractor: ClaudeTableExtractor?
        /// LandingAI ADE table extractor, prepended to the Cloud-mode
        /// table extractor chain when configured. Nil when the toggle
        /// is off or no LandingAI key is available.
        let landingAITableExtractor: LandingAITableExtractor?
        /// Active page-OCR engine. Either `ClaudePageOCREngine` or
        /// `GeminiPageOCREngine` depending on the user's provider
        /// pick. Manuscript mode forces Claude.
        let pageEngine: (any PageOCREngine)?
        /// Concrete Claude page engine for the batch dispatch path.
        /// Non-nil only when `pageEngine` is the Claude variant —
        /// prompt caching is Anthropic-only, so Gemini-selected
        /// runs use `geminiBatchPageEngine` below instead.
        let claudeBatchPageEngine: ClaudePageOCREngine?
        /// Concrete Gemini page engine for the batch dispatch path
        /// (P-Gemini-Batch). Non-nil only when `pageEngine` is the
        /// Gemini variant. Manuscript mode hard-pins Claude, so
        /// this is nil there even when the user has Gemini
        /// selected globally.
        let geminiBatchPageEngine: GeminiPageOCREngine?

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
            let geminiBatch = pageEngine as? GeminiPageOCREngine
            return ClaudeEngines(
                budget: budget,
                ocr: makeClaudeOCREngine(options: options, budget: budget),
                googleDocumentOCR: makeGoogleDocumentOCREngine(
                    options: options, budget: budget
                ),
                landingAIDocument: makeLandingAIDocumentEngine(
                    options: options, budget: budget
                ),
                postProcessor: makePostProcessor(options: options, budget: budget),
                tocParser: makeClaudeTOCParser(options: options, budget: budget),
                tableExtractor: makeClaudeTableExtractor(options: options, budget: budget),
                landingAITableExtractor: makeLandingAITableExtractor(
                    options: options, budget: budget
                ),
                pageEngine: pageEngine,
                claudeBatchPageEngine: claudeBatch,
                geminiBatchPageEngine: geminiBatch
            )
        }
    }
}
