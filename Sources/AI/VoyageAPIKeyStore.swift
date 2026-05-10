import Foundation

/// Keychain-backed store for the user's Voyage AI API key. Voyage is
/// Anthropic's recommended embedding provider; cheap (~$0.005/book)
/// and strong on technical / academic English.
///
/// Same shape as `AnthropicAPIKeyStore` — different keychain service
/// suffix so the two keys don't collide. Both wrap the shared
/// `KeychainAPIKeyStore`.
public struct VoyageAPIKeyStore: Sendable {

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
        return "\(bundleID).voyage-api-key"
    }

    public func read() -> String? { underlying.read() }
    public func write(_ value: String) throws { try underlying.write(value) }
    public func delete() throws { try underlying.delete() }
    public var hasKey: Bool { underlying.hasKey }

    public typealias KeychainError = KeychainAPIKeyStore.KeychainError
}
