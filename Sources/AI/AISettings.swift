import Foundation

/// User-facing AI configuration, persisted to `UserDefaults`.
///
/// The processing-mode toggle and per-feature switches live here.
/// API keys are *not* in this struct — they live in the keychain
/// via `AnthropicAPIKeyStore`. Phase 1 only builds the storage
/// layer + the Settings UI; the pipeline reads `processingMode`
/// in Phase 2 onward.
public struct AISettings: Sendable, Codable, Equatable {
    public var processingMode: ProcessingMode
    public var cloudFeatures: CloudFeatures
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
        perBookCallCap: Int = 200,
        forceOCR: Bool = false
    ) {
        self.processingMode = processingMode
        self.cloudFeatures = cloudFeatures
        self.perBookCallCap = perBookCallCap
        self.forceOCR = forceOCR
    }

    private enum CodingKeys: String, CodingKey {
        case processingMode, cloudFeatures, perBookCallCap, forceOCR
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.processingMode = try c.decode(ProcessingMode.self, forKey: .processingMode)
        self.cloudFeatures = try c.decode(CloudFeatures.self, forKey: .cloudFeatures)
        self.perBookCallCap = try c.decode(Int.self, forKey: .perBookCallCap)
        // Decode optionally so settings persisted before this field
        // existed don't fail to round-trip.
        self.forceOCR = try c.decodeIfPresent(Bool.self, forKey: .forceOCR) ?? false
    }

    /// Per-feature toggles. Each is independently switchable, but
    /// none of them activate unless `processingMode == .cloud`. The
    /// model selection per feature follows our recommendation:
    /// Sonnet 4.6 for vision-heavy tasks, Haiku 4.5 for text.
    public struct CloudFeatures: Sendable, Codable, Equatable {
        /// Vision OCR for hard regions where Vision + Tesseract both
        /// scored below the quality floor (Sonnet 4.6).
        public var hardRegionOCR: Bool
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

        public init(
            hardRegionOCR: Bool = true,
            tableExtraction: Bool = true,
            postOCRCleanup: Bool = false,
            postOCRCleanupVisionMode: Bool = false,
            semanticClassification: Bool = false,
            tocParsing: Bool = false,
            metadataExtraction: Bool = true,
            coherencePass: Bool = true,
            adaptivePageRouting: Bool = true
        ) {
            self.hardRegionOCR = hardRegionOCR
            self.tableExtraction = tableExtraction
            self.postOCRCleanup = postOCRCleanup
            self.postOCRCleanupVisionMode = postOCRCleanupVisionMode
            self.semanticClassification = semanticClassification
            self.tocParsing = tocParsing
            self.metadataExtraction = metadataExtraction
            self.coherencePass = coherencePass
            self.adaptivePageRouting = adaptivePageRouting
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
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.hardRegionOCR = try c.decode(Bool.self, forKey: .hardRegionOCR)
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
