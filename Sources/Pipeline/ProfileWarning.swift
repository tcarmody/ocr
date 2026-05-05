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
    /// The PDF looks like a scan (no usable embedded text on any
    /// sampled page) but the user has Surya / high-accuracy OCR
    /// turned off. Vision will run on every page and miss lines that
    /// Surya catches reliably.
    case likelyScanButHighAccuracyOff
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
        case .likelyScanButHighAccuracyOff:
            return "Likely scan — Surya would likely improve quality"
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
        case .likelyScanButHighAccuracyOff:    return "exclamationmark.triangle"
        case .detectedLanguageUnsupported:     return "info.circle"
        case .cloudModeButNoAPIKey:            return "exclamationmark.triangle"
        case .cloudModeButNoFeaturesEnabled:   return "info.circle"
        }
    }
}

/// Inputs for `ProfileWarningEvaluator.evaluate(...)`. Bundled into
/// a struct so the call site stays compact and adding a new signal
/// later doesn't churn every caller's argument list.
public struct ProfileWarningInputs: Sendable {
    public let profile: DocumentProfile
    /// Whether the queue's high-accuracy / Surya toggle is on for
    /// this drop.
    public let useHighAccuracyOCR: Bool
    /// AI processing mode for this conversion.
    public let processingMode: ProcessingMode
    /// Cloud-feature toggles. Unused for non-cloud modes.
    public let cloudFeatures: AISettings.CloudFeatures
    /// True when the keychain has a non-empty Anthropic API key.
    /// Caller is responsible for the keychain read so this struct
    /// stays plain-data.
    public let hasAPIKey: Bool
    /// BCP-47 primary subtags the queue's language picker offers.
    /// Used to detect "we detected `cy` but the picker doesn't
    /// have Welsh."
    public let pickerSupportedLanguages: [String]

    public init(
        profile: DocumentProfile,
        useHighAccuracyOCR: Bool,
        processingMode: ProcessingMode,
        cloudFeatures: AISettings.CloudFeatures,
        hasAPIKey: Bool,
        pickerSupportedLanguages: [String]
    ) {
        self.profile = profile
        self.useHighAccuracyOCR = useHighAccuracyOCR
        self.processingMode = processingMode
        self.cloudFeatures = cloudFeatures
        self.hasAPIKey = hasAPIKey
        self.pickerSupportedLanguages = pickerSupportedLanguages
    }
}

/// Pure function: profile + settings → warning list. No side
/// effects, no I/O, no actor hops — the call site (queue
/// view-model) handles those and feeds in plain values.
public enum ProfileWarningEvaluator {
    public static func evaluate(_ inputs: ProfileWarningInputs) -> [ProfileWarning] {
        var warnings: [ProfileWarning] = []

        // Likely scan + high-accuracy OCR off. Skip when the toggle
        // is on (Surya will run); skip when we can't tell from the
        // profile (no scan flag yet). Order: surface this first
        // because it directly affects local-mode output quality.
        if inputs.profile.isLikelyScan && !inputs.useHighAccuracyOCR {
            warnings.append(.likelyScanButHighAccuracyOff)
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
