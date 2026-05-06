import Foundation

/// A BCP-47 language tag (https://tools.ietf.org/html/bcp47).
///
/// Wraps a string so the type system distinguishes language tags from
/// arbitrary strings. We don't validate the tag here — that would either
/// require a full BCP-47 parser or a brittle allowlist; instead we trust
/// callers to use the constants below or pass valid tags from outside.
public struct BCP47: Sendable, Hashable, RawRepresentable, ExpressibleByStringLiteral, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init?(rawValue: String) {
        self.init(rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    // Modern languages we care about up front.
    public static let en: BCP47 = "en"
    public static let fr: BCP47 = "fr"
    public static let de: BCP47 = "de"
    public static let it: BCP47 = "it"
    public static let es: BCP47 = "es"

    // Day-1 ancient languages from the plan.
    public static let grc: BCP47 = "grc" // Ancient/Koine Greek
    public static let la: BCP47 = "la"   // Latin

    // Useful subtags (kept here so they're discoverable without re-typing).
    public static let grcKoine: BCP47 = "grc-x-koine"
    public static let laMedieval: BCP47 = "la-x-medieval"
}
