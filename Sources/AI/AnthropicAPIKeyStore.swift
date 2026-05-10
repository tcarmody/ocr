import Foundation

/// Keychain-backed store for the user's Anthropic API key. Thin
/// wrapper around `KeychainAPIKeyStore` with the Anthropic-specific
/// service suffix (`<bundle>.anthropic-api-key`).
///
/// The wrapper preserves the original public API surface — the
/// existing call sites (`AnthropicAPIKeyStore()`, `.read()`,
/// `.write(_:)`, `.delete()`, `.hasKey`) work unchanged — while the
/// keychain plumbing lives in one place so additional providers
/// (Voyage, Gemini) reuse the same code path.
public struct AnthropicAPIKeyStore: Sendable {

    /// Keychain service identifier. Defaults to the bundle's
    /// reverse-DNS id; tests pass a per-test value so they don't
    /// collide with a real key the user has stored.
    public let service: String
    public let account: String

    private var underlying: KeychainAPIKeyStore {
        KeychainAPIKeyStore(service: service, account: account)
    }

    public init(service: String? = nil, account: String = "default") {
        self.service = service ?? Self.defaultServiceName
        self.account = account
    }

    /// Default keychain service name — bundle id + suffix when an
    /// `Info.plist` is available, otherwise a static fallback for
    /// command-line tests / SPM contexts.
    public static var defaultServiceName: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.humanist"
        return "\(bundleID).anthropic-api-key"
    }

    public func read() -> String? { underlying.read() }
    public func write(_ value: String) throws { try underlying.write(value) }
    public func delete() throws { try underlying.delete() }
    public var hasKey: Bool { underlying.hasKey }

    /// Re-exported for callers that catch the error type.
    public typealias KeychainError = KeychainAPIKeyStore.KeychainError
}
