import Foundation

/// Keychain-backed store for the user's LandingAI ADE API key. Used by
/// `LandingAIDocumentEngine` (Agentic Document Extraction Gen2 `/v2/parse`)
/// as an alternative cloud document-OCR provider alongside
/// `GoogleDocumentOCREngine`. Issued from ade.landing.ai (EU keys from
/// ade.eu-west-1.landing.ai — keys are deployment-specific); the
/// SDK reads the same value from the `VISION_AGENT_API_KEY` env var.
/// Same shape as the other API-key stores; distinct keychain service
/// suffix so it doesn't collide with the Cloud Vision or Anthropic key.
public struct LandingAIAPIKeyStore: Sendable {

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
        return "\(bundleID).landingai-ade-api-key"
    }

    public func read() -> String? { underlying.read() }
    public func write(_ value: String) throws { try underlying.write(value) }
    public func delete() throws { try underlying.delete() }
    public var hasKey: Bool { underlying.hasKey }

    public typealias KeychainError = KeychainAPIKeyStore.KeychainError
}
