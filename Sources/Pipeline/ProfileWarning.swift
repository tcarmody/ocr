import Foundation
import AI
import PDFIngest

/// Pre-flight content-vs-config mismatch warnings (Tier 1.5
/// "P-Profile-Warnings"). The `DocumentProfile` produced by
/// `DocumentProfiler` already carries every signal we need — this
/// is a thin presentation layer that turns the profile + the user's
/// settings + a couple of environment booleans into a list of
/// non-blocking nudges shown in the queue row.
///
/// Each warning is one of a closed enum so the UI can render the
/// right SF Symbol + headline without parsing strings, and the set
/// is deterministic per (profile, settings) input pair.
public enum ProfileWarning: String, Sendable, Codable, CaseIterable, Equatable {
    /// The PDF looks like a scan OR has dense embedded figures
    /// (`imageXObjectsPerPage` ≥ `figureDensityThreshold`), AND the
    /// user has a Cloud page-OCR provider available (Cloud mode +
    /// API key for the configured provider). Recommend Cloud page
    /// OCR — Sonnet / Gemini handle scans and figure-rich layouts
    /// noticeably better than the per-region cascade.
    case complexLayoutRecommendCloudPageOCR
    /// Same trigger (likely-scan / figure-dense layout) but the
    /// user is in Private mode or doesn't have a Cloud key.
    /// Surya is installed locally so it's the best available
    /// upgrade — fall back to recommending it instead.
    case complexLayoutRecommendSurya
    /// Same trigger, but neither Cloud page OCR nor Surya is
    /// available. Vision will run on every page and miss lines
    /// that either upgrade path catches reliably. Surface the
    /// install paths.
    case complexLayoutNoUpgradePathAvailable
    /// `NLLanguageRecognizer` produced a confident detection, but
    /// the detected language isn't one of the picker's supported
    /// codes — so auto-detect couldn't override the picker. The
    /// user's selected language is being used despite the mismatch.
    case detectedLanguageUnsupported
    /// `processingMode == .cloud` but no API key in the keychain.
    /// Cloud features won't run; everything falls back to the
    /// local cascade.
    case cloudModeButNoAPIKey
    /// `processingMode == .cloud` and a key is configured, but
    /// `CloudFeatures` has nothing toggled on. The user is in
    /// Cloud mode but no Cloud-mode features will fire.
    case cloudModeButNoFeaturesEnabled

    /// Headline shown in the queue row — keep it under ~50 chars so
    /// it fits on one line at the row's font size.
    public var headline: String {
        switch self {
        case .complexLayoutRecommendCloudPageOCR:
            return "Likely scan or figure-rich layout — enable Page OCR for best quality"
        case .complexLayoutRecommendSurya:
            return "Likely scan or figure-rich layout — enable Surya OCR for better text recovery"
        case .complexLayoutNoUpgradePathAvailable:
            return "Likely scan — install Surya or configure Cloud page OCR for better text"
        case .detectedLanguageUnsupported:
            return "Detected language isn't in the picker; using your selection"
        case .cloudModeButNoAPIKey:
            return "Cloud mode on, but no API key — Cloud features won't run"
        case .cloudModeButNoFeaturesEnabled:
            return "Cloud mode on, but every Cloud feature is toggled off"
        }
    }

    /// SF Symbol for the row's badge. `exclamationmark.triangle` for
    /// configurations that will actively underperform; `info.circle`
    /// for non-blocking informational notes.
    public var systemImage: String {
        switch self {
        case .complexLayoutRecommendCloudPageOCR:    return "sparkles"
        case .complexLayoutRecommendSurya:           return "exclamationmark.triangle"
        case .complexLayoutNoUpgradePathAvailable:   return "exclamationmark.triangle"
        case .detectedLanguageUnsupported:           return "info.circle"
        case .cloudModeButNoAPIKey:                  return "exclamationmark.triangle"
        case .cloudModeButNoFeaturesEnabled:         return "info.circle"
        }
    }

    /// Threshold for "figure-dense": at least one embedded image
    /// XObject every ~3 pages. Below this, the warning doesn't
    /// fire on the figure-density signal alone — likely-scan
    /// remains the load-bearing trigger.
    public static let figureDensityThreshold: Double = 0.3
}

/// Inputs for `ProfileWarningEvaluator.evaluate(...)`. Bundled into
/// a struct so the call site stays compact and adding a new signal
/// later doesn't churn every caller's argument list.
public struct ProfileWarningInputs: Sendable {
    public let profile: DocumentProfile
    /// Whether the queue's high-accuracy / Surya toggle is on for
    /// this drop.
    public let useHighAccuracyOCR: Bool
    /// Whether the queue's Cloud page-OCR toggle is on for this
    /// drop. Independent of `useHighAccuracyOCR`; the two are
    /// mutually exclusive at the launcher level (different OCR
    /// engines), but inputs here are plain values so the
    /// evaluator can reason about each independently.
    public let useClaudePageOCR: Bool
    /// AI processing mode for this conversion.
    public let processingMode: ProcessingMode
    /// Cloud-feature toggles. Unused for non-cloud modes.
    public let cloudFeatures: AISettings.CloudFeatures
    /// True when the keychain has a non-empty Anthropic API key.
    /// Caller is responsible for the keychain read so this struct
    /// stays plain-data.
    public let hasAPIKey: Bool
    /// True when the keychain has a non-empty Google AI Studio
    /// (Gemini) API key. Lets the evaluator recommend Cloud page
    /// OCR even when the configured provider is Gemini-flavored
    /// without an Anthropic key.
    public let hasGeminiKey: Bool
    /// True when the Surya CLI is detected on this machine
    /// (`uv tool` install). Drives the
    /// `complexLayoutRecommendSurya` vs
    /// `complexLayoutNoUpgradePathAvailable` split.
    public let suryaAvailable: Bool
    /// BCP-47 primary subtags the queue's language picker offers.
    /// Used to detect "we detected `cy` but the picker doesn't
    /// have Welsh."
    public let pickerSupportedLanguages: [String]

    public init(
        profile: DocumentProfile,
        useHighAccuracyOCR: Bool,
        useClaudePageOCR: Bool = false,
        processingMode: ProcessingMode,
        cloudFeatures: AISettings.CloudFeatures,
        hasAPIKey: Bool,
        hasGeminiKey: Bool = false,
        suryaAvailable: Bool = false,
        pickerSupportedLanguages: [String]
    ) {
        self.profile = profile
        self.useHighAccuracyOCR = useHighAccuracyOCR
        self.useClaudePageOCR = useClaudePageOCR
        self.processingMode = processingMode
        self.cloudFeatures = cloudFeatures
        self.hasAPIKey = hasAPIKey
        self.hasGeminiKey = hasGeminiKey
        self.suryaAvailable = suryaAvailable
        self.pickerSupportedLanguages = pickerSupportedLanguages
    }
}

/// Pure function: profile + settings → warning list. No side
/// effects, no I/O, no actor hops — the call site (queue
/// view-model) handles those and feeds in plain values.
public enum ProfileWarningEvaluator {
    public static func evaluate(_ inputs: ProfileWarningInputs) -> [ProfileWarning] {
        var warnings: [ProfileWarning] = []

        // Complex-layout trigger: pure-scan OR figure-dense. Both
        // shapes benefit from an upgrade beyond the per-region
        // Vision cascade. Skip when the user already picked an
        // upgrade path for this conversion.
        let complexLayout = inputs.profile.isLikelyScan
            || inputs.profile.imageXObjectsPerPage
                >= ProfileWarning.figureDensityThreshold
        let upgradeAlreadyPicked = inputs.useHighAccuracyOCR
            || inputs.useClaudePageOCR
        if complexLayout && !upgradeAlreadyPicked {
            // Pick the strongest available upgrade path. Cloud
            // page OCR ranks above Surya because Sonnet / Gemini
            // handle figures + captions + scanned text better
            // than the per-region cascade with Surya layout.
            let cloudPageOCRAvailable = inputs.processingMode == .cloud
                && (inputs.hasAPIKey || inputs.hasGeminiKey)
            if cloudPageOCRAvailable {
                warnings.append(.complexLayoutRecommendCloudPageOCR)
            } else if inputs.suryaAvailable {
                warnings.append(.complexLayoutRecommendSurya)
            } else {
                warnings.append(.complexLayoutNoUpgradePathAvailable)
            }
        }

        // Detected language confident but not supported by the picker.
        // The auto-detect machinery in QueueViewModel only overrides
        // when the language is supported, so this path means we
        // *kept* the picker's selection — surface the mismatch so
        // the user can investigate (often it's a confusable like
        // Welsh detected on a Cornish text, where the picker has
        // neither).
        if let primary = inputs.profile.primaryLanguage,
           inputs.profile.confidence >= 0.7,
           !inputs.pickerSupportedLanguages.contains(primary) {
            warnings.append(.detectedLanguageUnsupported)
        }

        // Cloud mode misconfiguration — two distinct cases.
        if inputs.processingMode == .cloud {
            if !inputs.hasAPIKey {
                warnings.append(.cloudModeButNoAPIKey)
            } else if !inputs.cloudFeatures.anyEnabled {
                warnings.append(.cloudModeButNoFeaturesEnabled)
            }
        }

        return warnings
    }
}

private extension AISettings.CloudFeatures {
    /// True when at least one Cloud-mode feature toggle is on. Used
    /// by the no-features-enabled warning to differentiate "Cloud
    /// mode is on and will fire" from "Cloud mode is on but does
    /// nothing."
    var anyEnabled: Bool {
        hardRegionOCR || tableExtraction || postOCRCleanup
            || semanticClassification || tocParsing
    }
}
