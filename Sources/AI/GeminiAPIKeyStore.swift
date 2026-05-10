import Foundation

/// Keychain-backed store for the user's Google AI Studio API key.
/// The key is used for Gemini Embedding 002 (and any future Gemini-
/// backed features). Same shape as `AnthropicAPIKeyStore` and
/// `VoyageAPIKeyStore` — different keychain service suffix so the
/// three keys don't collide.
public struct GeminiAPIKeyStore: Sendable {

    public let service: String
    public let account: String

    private var underlying: KeychainAPIKeyStore {
        KeychainAPIKeyStore(service: service, account: account)
    }

    public init(service: String? = nil, account: String = "default") {
        self.service = service ?? Self.defaultServiceName
        self.account = account
    }

    public static var defaultServiceName: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.humanist"
        return "\(bundleID).gemini-api-key"
    }

    public func read() -> String? { underlying.read() }
    public func write(_ value: String) throws { try underlying.write(value) }
    public func delete() throws { try underlying.delete() }
    public var hasKey: Bool { underlying.hasKey }

    public typealias KeychainError = KeychainAPIKeyStore.KeychainError
}
