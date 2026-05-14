import Foundation

/// Keychain-backed store for the user's Google Cloud Vision API key.
/// Used by `GoogleDocumentOCREngine` (Cloud Vision DOCUMENT_TEXT_DETECTION)
/// in the cascade Stage 2.5. Separate from `GeminiAPIKeyStore` because
/// keys issued from Google AI Studio (used for Gemini generative models)
/// don't authenticate against `vision.googleapis.com`; users provision
/// the Cloud Vision key from the Google Cloud Console with the Vision
/// API enabled on the project. Same shape as the other API-key stores;
/// distinct keychain service suffix.
public struct GoogleCloudVisionAPIKeyStore: Sendable {

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
        return "\(bundleID).google-cloud-vision-api-key"
    }

    public func read() -> String? { underlying.read() }
    public func write(_ value: String) throws { try underlying.write(value) }
    public func delete() throws { try underlying.delete() }
    public var hasKey: Bool { underlying.hasKey }

    public typealias KeychainError = KeychainAPIKeyStore.KeychainError
}
