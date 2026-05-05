import Foundation

/// Pinned Claude model identifier for the Messages API.
///
/// Use only the exact strings declared here — appending a date suffix
/// to an alias (e.g. `claude-sonnet-4-6-20251101`) returns a 404.
/// Added new models by extending `rawValue` cases or constructing
/// `AnthropicModel(rawValue:)` directly with an authoritative string
/// from Anthropic's published model catalog.
///
/// Wrapping `RawRepresentable` instead of a closed enum keeps
/// forward-compatibility: a future Claude release can be passed
/// through without a SDK update, while the static constants below
/// give callers type-safe, mnemonic names for the models we ship
/// against today.
public struct AnthropicModel: Sendable, Codable, Equatable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Sonnet 4.6 — best speed / intelligence balance. Used for
    /// vision-heavy tasks where ground-truth quality matters: hard-
    /// region OCR (polytonic Greek, Hebrew, mixed scripts) and
    /// table-structure extraction.
    public static let sonnet4_6 = AnthropicModel(rawValue: "claude-sonnet-4-6")

    /// Haiku 4.5 — fastest and most cost-effective. Used for the
    /// text-only Tier 2 features: post-OCR character cleanup,
    /// semantic chapter classification, TOC parsing.
    public static let haiku4_5 = AnthropicModel(rawValue: "claude-haiku-4-5")

    /// Haiku 4.5 pinned to a dated snapshot — strictest reproducibility
    /// for evaluation pipelines that want byte-for-byte identical
    /// behavior across deploys. Production code typically uses the
    /// alias above.
    public static let haiku4_5_20251001 = AnthropicModel(rawValue: "claude-haiku-4-5-20251001")
}
