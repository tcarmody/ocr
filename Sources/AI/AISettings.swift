import Foundation

/// User-facing AI configuration, persisted to `UserDefaults`.
///
/// The processing-mode toggle and per-feature switches live here.
/// API keys are *not* in this struct — they live in the keychain
/// via `AnthropicAPIKeyStore`. Phase 1 only builds the storage
/// layer + the Settings UI; the pipeline reads `processingMode`
/// in Phase 2 onward.
/// Which provider runs end-to-end page OCR when the user has Cloud
/// mode + page-OCR (Claude OCR / Manuscript / Early-print) enabled.
/// Claude was the only option through Phase 2; Gemini 2.5 Flash was
/// added as a much-cheaper alternative — same XHTML output schema,
/// ~7-10× lower per-page cost, comparable quality on typeset prose.
/// Stored at the top level of `AISettings` (not inside `CloudFeatures`)
/// because it picks the engine, not a feature toggle.
public enum PageOCRProvider: String, Sendable, Codable, Equatable, CaseIterable {
    case claude
    case gemini25Flash
    /// Gemini 3 Flash preview — newer than 2.5 Flash, but **preview**
    /// status (API id `gemini-3-flash-preview`). Adds Pro-tier
    /// reasoning at Flash latency, ~25% more expensive on input and
    /// ~20% more on output than 2.5 Flash. `thinking_level` is pinned
    /// to `minimal` for OCR — transcription doesn't benefit from
    /// reasoning and would otherwise inflate output token count.
    /// Opt-in: 2.5 Flash stays default until 3 Flash hits GA.
    case gemini3FlashPreview
}

public struct AISettings: Sendable, Codable, Equatable {
    public var processingMode: ProcessingMode
    public var cloudFeatures: CloudFeatures
    /// Active page-OCR provider when `processingMode == .cloud` AND
    /// the user has page-OCR mode on (Claude OCR / Manuscript /
    /// Early-print). Manuscript mode forces `.claude` regardless of
    /// this setting — handwriting needs Opus.
    public var pageOCRProvider: PageOCRProvider
    /// On-device feature toggles, gated by `processingMode ==
    /// .privateLocal` and runtime availability (Apple Intelligence
    /// must be enabled in System Settings). Lets Private-mode users
    /// pick up classification-shaped Cloud features via Apple's
    /// Foundation Models framework — `L-Foundation-Models`.
    public var localFeatures: LocalFeatures
    /// Hard ceiling on Claude calls per book. Defaults to 200 —
    /// catches runaway documents (every region triggering Claude)
    /// without throttling normal use. Settable from 0 (disable
    /// Cloud features for this book) up to a few thousand.
    public var perBookCallCap: Int
    /// When true, bypass the embedded-text trust path entirely —
    /// every page goes through render + OCR + cascade regardless
    /// of how well-formed the PDF's embedded text layer looks.
    /// Use when a PDF carries a low-quality embedded text layer
    /// (typically the output of a previous bad OCR pass) that the
    /// quality scorer mistakes for legitimate prose. Slower but
    /// guaranteed to actually OCR.
    public var forceOCR: Bool

    public init(
        processingMode: ProcessingMode = .privateLocal,
        cloudFeatures: CloudFeatures = CloudFeatures(),
        localFeatures: LocalFeatures = LocalFeatures(),
        perBookCallCap: Int = 200,
        forceOCR: Bool = false,
        pageOCRProvider: PageOCRProvider = .claude
    ) {
        self.processingMode = processingMode
        self.cloudFeatures = cloudFeatures
        self.localFeatures = localFeatures
        self.perBookCallCap = perBookCallCap
        self.forceOCR = forceOCR
        self.pageOCRProvider = pageOCRProvider
    }

    private enum CodingKeys: String, CodingKey {
        case processingMode, cloudFeatures, localFeatures
        case perBookCallCap, forceOCR
        case pageOCRProvider
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.processingMode = try c.decode(ProcessingMode.self, forKey: .processingMode)
        self.cloudFeatures = try c.decode(CloudFeatures.self, forKey: .cloudFeatures)
        self.perBookCallCap = try c.decode(Int.self, forKey: .perBookCallCap)
        // Decode optionally so settings persisted before this field
        // existed don't fail to round-trip.
        self.forceOCR = try c.decodeIfPresent(Bool.self, forKey: .forceOCR) ?? false
        self.localFeatures = try c.decodeIfPresent(
            LocalFeatures.self, forKey: .localFeatures
        ) ?? LocalFeatures()
        // Default to Claude so existing users see no behavior change
        // until they explicitly pick Gemini in Settings.
        self.pageOCRProvider = try c.decodeIfPresent(
            PageOCRProvider.self, forKey: .pageOCRProvider
        ) ?? .claude
    }

    /// On-device feature toggles backed by Apple's Foundation Models
    /// framework. Phase 1 of `L-Foundation-Models` ships chapter
    /// classification; later phases add metadata extraction, post-
    /// OCR cleanup, and coherence pass.
    public struct LocalFeatures: Sendable, Codable, Equatable {
        /// Run on-device chapter classification (`epub:type`) when
        /// processing mode is `.privateLocal` and Apple Intelligence
        /// is available. Mirrors `cloudFeatures.semanticClassification`
        /// but without the API-key / cost gate.
        public var localChapterClassification: Bool
        /// Run on-device front-matter metadata extraction (title,
        /// author, year, publisher, ISBN). Mirrors
        /// `cloudFeatures.metadataExtraction`. Phase 2 of
        /// `L-Foundation-Models`.
        public var localMetadataExtraction: Bool
        /// Run the on-device coherence pass — recurring OCR-error
        /// detection across the whole book, returning guarded
        /// global rewrites. Mirrors `cloudFeatures.coherencePass`.
        /// Phase 2 of `L-Foundation-Models`.
        public var localCoherencePass: Bool
        /// Run on-device per-region post-OCR cleanup (character-
        /// level fixes for ligatures, missing diacritics, dropped
        /// spaces, long-s, homoglyphs). Passages-mode only; vision-
        /// mode regions still need Cloud Haiku because AFM is
        /// text-only. Mirrors `cloudFeatures.postOCRCleanup`.
        /// Phase 2.5 of `L-Foundation-Models`.
        public var localPostOCRCleanup: Bool

        public init(
            localChapterClassification: Bool = true,
            localMetadataExtraction: Bool = true,
            localCoherencePass: Bool = true,
            localPostOCRCleanup: Bool = true
        ) {
            self.localChapterClassification = localChapterClassification
            self.localMetadataExtraction = localMetadataExtraction
            self.localCoherencePass = localCoherencePass
            self.localPostOCRCleanup = localPostOCRCleanup
        }

        private enum CodingKeys: String, CodingKey {
            case localChapterClassification
            case localMetadataExtraction
            case localCoherencePass
            case localPostOCRCleanup
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Default-on so Private-mode users get classification
            // / metadata / coherence / cleanup automatically;
            // flipping off restores the no-op behavior they had
            // before each feature shipped.
            self.localChapterClassification = try c.decodeIfPresent(
                Bool.self, forKey: .localChapterClassification
            ) ?? true
            self.localMetadataExtraction = try c.decodeIfPresent(
                Bool.self, forKey: .localMetadataExtraction
            ) ?? true
            self.localCoherencePass = try c.decodeIfPresent(
                Bool.self, forKey: .localCoherencePass
            ) ?? true
            self.localPostOCRCleanup = try c.decodeIfPresent(
                Bool.self, forKey: .localPostOCRCleanup
            ) ?? true
        }
    }

    /// Per-feature toggles. Each is independently switchable, but
    /// none of them activate unless `processingMode == .cloud`. The
    /// model selection per feature follows our recommendation:
    /// Sonnet 4.6 for vision-heavy tasks, Haiku 4.5 for text.
    public struct CloudFeatures: Sendable, Codable, Equatable {
        /// Vision OCR for hard regions where Vision + Tesseract both
        /// scored below the quality floor (Sonnet 4.6).
        public var hardRegionOCR: Bool
        /// Google Cloud Document OCR (Vision API DOCUMENT_TEXT_DETECTION)
        /// added to the per-region cascade as Stage 2.5, sitting between
        /// Tesseract and Claude. ~$1.50 per 1000 images vs Claude's
        /// ~$1.50 per 100 calls; absorbs most of the hard-region tail
        /// before falling through to Claude. Independently keyed
        /// (Google Cloud Vision API key, not the AI Studio Gemini key).
        public var googleDocumentOCRInCascade: Bool
        /// Table-structure extraction from cropped table region
        /// images (Sonnet 4.6).
        public var tableExtraction: Bool
        /// Character-level cleanup pass on OCR output that's already
        /// "good enough" but has known mojibake / diacritic issues
        /// (Haiku 4.5).
        public var postOCRCleanup: Bool
        /// When true, post-OCR cleanup runs in **vision mode** — the
        /// rendered region image is sent alongside the OCR text so
        /// Haiku can verify against the actual glyphs. Higher cost
        /// (~5-10× the tokens per call) but better quality on the
        /// hardest regions (worn type, faded scans, polytonic Greek).
        /// Off by default; ignored when `postOCRCleanup` itself is off.
        public var postOCRCleanupVisionMode: Bool
        /// EPUB 3 `epub:type` per chapter via title classification
        /// (Haiku 4.5).
        public var semanticClassification: Bool
        /// Parse the printed TOC into an authoritative chapter tree
        /// (Haiku 4.5 default; escalates to Sonnet 4.6 on parse
        /// failure).
        public var tocParsing: Bool
        /// Tier 9 / Q-Metadata. One Haiku call per book over the
        /// front matter to extract title / author / year /
        /// publisher / ISBN into the OPF metadata. ~Free at Haiku
        /// rates; on by default in Cloud mode because the result
        /// is mostly upside (Library window gets real titles).
        public var metadataExtraction: Bool
        /// Tier 9 / Q-Coherence. One Haiku call per book that
        /// looks at a digest of every chapter and proposes
        /// recurring-OCR-error rewrites (character names with
        /// stripped diacritics, ligature artifacts, etc.). Each
        /// suggestion is guardrailed (length ratio, document
        /// occurrence count, no-collision) before applying. On
        /// by default in Cloud mode — single Haiku call, real
        /// quality win on long books.
        public var coherencePass: Bool
        /// Tier 9 / E-Routing. When `useClaudePageOCR` is on and
        /// this flag is on, pages whose embedded text passes the
        /// quality scorer's `.trust` verdict skip the Sonnet call
        /// and emit reflowed embedded text instead. Saves
        /// ~$0.04/page on born-digital pages within mixed-quality
        /// books. On by default — turning off forces Sonnet on
        /// every page (the original page-OCR behavior).
        public var adaptivePageRouting: Bool
        /// Tier 9 / E-Batches. When `useClaudePageOCR` is on and
        /// this flag is on, all the page-OCR Sonnet calls for one
        /// conversion submit as a single Anthropic Batches API
        /// request. 50% input + output token discount in exchange
        /// for asynchronous processing (typically 1-5 minutes
        /// total for a book of normal length, capped at 24h).
        /// Off by default — opt-in because the wait time changes
        /// the conversion experience from per-page progress to
        /// "submitting batch / waiting / processing".
        public var useBatchAPI: Bool
        /// Tier 9 / E-Parallel. When `useClaudePageOCR` is on, the
        /// per-page Sonnet calls run with this much concurrency
        /// (clamped to ≥ 1). Default 1 keeps the existing
        /// per-page rhythm; bumping to 4-8 cuts wall time
        /// roughly proportionally on bulk runs. Anthropic's
        /// Build-tier RPM accommodates 4-8 concurrent calls
        /// comfortably; higher tiers can push further.
        public var parallelPageOCRConcurrency: Int

        public init(
            hardRegionOCR: Bool = true,
            googleDocumentOCRInCascade: Bool = true,
            tableExtraction: Bool = true,
            postOCRCleanup: Bool = false,
            postOCRCleanupVisionMode: Bool = false,
            semanticClassification: Bool = false,
            tocParsing: Bool = false,
            metadataExtraction: Bool = true,
            coherencePass: Bool = true,
            adaptivePageRouting: Bool = true,
            useBatchAPI: Bool = false,
            parallelPageOCRConcurrency: Int = 1
        ) {
            self.hardRegionOCR = hardRegionOCR
            self.googleDocumentOCRInCascade = googleDocumentOCRInCascade
            self.tableExtraction = tableExtraction
            self.postOCRCleanup = postOCRCleanup
            self.postOCRCleanupVisionMode = postOCRCleanupVisionMode
            self.semanticClassification = semanticClassification
            self.tocParsing = tocParsing
            self.metadataExtraction = metadataExtraction
            self.coherencePass = coherencePass
            self.adaptivePageRouting = adaptivePageRouting
            self.useBatchAPI = useBatchAPI
            self.parallelPageOCRConcurrency = max(1, parallelPageOCRConcurrency)
        }

        /// Decode optionally so settings persisted before
        /// `postOCRCleanupVisionMode` / `metadataExtraction` existed
        /// don't break.
        private enum CodingKeys: String, CodingKey {
            case hardRegionOCR, tableExtraction, postOCRCleanup
            case postOCRCleanupVisionMode
            case semanticClassification, tocParsing
            case metadataExtraction
            case coherencePass
            case adaptivePageRouting
            case useBatchAPI
            case parallelPageOCRConcurrency
            case googleDocumentOCRInCascade
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.hardRegionOCR = try c.decode(Bool.self, forKey: .hardRegionOCR)
            // Default-on: cheap Stage 2.5 in the cascade that absorbs
            // most hard-region work before falling through to Claude.
            // No-op until a Google Cloud Vision key is configured.
            self.googleDocumentOCRInCascade = try c.decodeIfPresent(
                Bool.self, forKey: .googleDocumentOCRInCascade
            ) ?? true
            self.tableExtraction = try c.decode(Bool.self, forKey: .tableExtraction)
            self.postOCRCleanup = try c.decode(Bool.self, forKey: .postOCRCleanup)
            self.postOCRCleanupVisionMode = try c.decodeIfPresent(
                Bool.self, forKey: .postOCRCleanupVisionMode
            ) ?? false
            self.semanticClassification = try c.decode(Bool.self, forKey: .semanticClassification)
            self.tocParsing = try c.decode(Bool.self, forKey: .tocParsing)
            // Default to true so users on the existing default-on
            // Cloud features get metadata extraction without a
            // resave; persisted "false" still round-trips.
            self.metadataExtraction = try c.decodeIfPresent(
                Bool.self, forKey: .metadataExtraction
            ) ?? true
            // Default-on for previously-stored settings, same as
            // metadataExtraction — both are mostly-upside Haiku
            // features.
            self.coherencePass = try c.decodeIfPresent(
                Bool.self, forKey: .coherencePass
            ) ?? true
            // Default-on: existing users with page-OCR enabled
            // get the cost saving without a re-save; opting out
            // restores the every-page-Sonnet behavior.
            self.adaptivePageRouting = try c.decodeIfPresent(
                Bool.self, forKey: .adaptivePageRouting
            ) ?? true
            // Default-off: opt-in feature, async processing
            // changes the conversion experience.
            self.useBatchAPI = try c.decodeIfPresent(
                Bool.self, forKey: .useBatchAPI
            ) ?? false
            // Default 1: existing serial per-page rhythm. Users
            // bump explicitly when they want bulk-run speedup.
            // Clamp at decode time so a corrupt persisted value
            // (e.g. 0 or negative) can't break the run.
            let raw = try c.decodeIfPresent(
                Int.self, forKey: .parallelPageOCRConcurrency
            ) ?? 1
            self.parallelPageOCRConcurrency = max(1, raw)
        }
    }
}

/// `UserDefaults`-backed persistence for `AISettings`. One JSON blob
/// under `humanist.ai-settings`; reads return the default-init
/// settings when nothing is stored or the stored payload is corrupt.
///
/// `@unchecked Sendable` because `UserDefaults` is thread-safe by
/// Apple's documentation (atomic reads / writes per key) but isn't
/// formally annotated as such in the SDK.
public struct AISettingsStore: @unchecked Sendable {
    public let defaults: UserDefaults
    public let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "humanist.ai-settings"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AISettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AISettings.self, from: data) else {
            return AISettings()
        }
        return settings
    }

    public func save(_ settings: AISettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    /// Reset to defaults. Used by the Settings UI's "Restore Defaults"
    /// button and by tests that need a known starting state.
    public func reset() {
        defaults.removeObject(forKey: key)
    }
}
