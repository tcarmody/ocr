import Foundation
import SwiftUI
import AI

/// View-model for `AISettingsView`. Owns the in-memory `AISettings`,
/// persists changes to the user-defaults-backed store, and bridges
/// the keychain-backed API key into a `@Published` mirror so SwiftUI
/// can render "key configured" state without holding the secret in
/// view state.
@MainActor
final class AISettingsViewModel: ObservableObject {
    @Published var settings: AISettings {
        didSet { settingsStore.save(settings) }
    }
    /// Mirrored copy of "is a key stored." Updated on read / write
    /// of `apiKey`; used by the view to switch between "Add Key" and
    /// "Replace Key" affordances.
    @Published private(set) var hasAPIKey: Bool
    /// Plain-text API key for the entry field. Only populated when
    /// the user is actively editing — saved to keychain on `commit`.
    @Published var pendingAPIKey: String = ""
    /// Result of the last "Test Connection" call. Nil before any
    /// test fires; non-nil shows an inline status message.
    @Published var testResult: TestResult?

    enum TestResult {
        case success(String)
        case failure(String)
    }

    let settingsStore: AISettingsStore
    let keyStore: AnthropicAPIKeyStore
    /// Closure that builds an API client from the current key. Held
    /// as a closure so tests can swap in a mocked transport.
    let clientFactory: @MainActor (AnthropicAPIKeyStore) -> AnthropicAPIClient

    init(
        settingsStore: AISettingsStore = AISettingsStore(),
        keyStore: AnthropicAPIKeyStore = AnthropicAPIKeyStore(),
        clientFactory: @escaping @MainActor (AnthropicAPIKeyStore) -> AnthropicAPIClient = { keyStore in
            AnthropicAPIClient(apiKeyProvider: { keyStore.read() })
        }
    ) {
        self.settingsStore = settingsStore
        self.keyStore = keyStore
        self.clientFactory = clientFactory
        self.settings = settingsStore.load()
        self.hasAPIKey = keyStore.hasKey
    }

    // MARK: - API key flow

    /// Persist `pendingAPIKey` to the keychain. Trims whitespace; a
    /// blank entry is treated as a deletion so the user can clear
    /// the stored key from the same field.
    func commitAPIKey() {
        let trimmed = pendingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try keyStore.delete()
            } else {
                try keyStore.write(trimmed)
            }
            hasAPIKey = keyStore.hasKey
            pendingAPIKey = ""
            testResult = nil
        } catch {
            testResult = .failure("Couldn't save key: \(error.localizedDescription)")
        }
    }

    func deleteAPIKey() {
        do {
            try keyStore.delete()
            hasAPIKey = keyStore.hasKey
            pendingAPIKey = ""
            testResult = nil
        } catch {
            testResult = .failure("Couldn't remove key: \(error.localizedDescription)")
        }
    }

    /// Round-trip a small Haiku request to verify the stored key is
    /// valid + reachable. The "ping" is a 1-token Haiku call —
    /// sub-cent cost, sub-second latency.
    func testConnection() async {
        guard hasAPIKey else {
            testResult = .failure("No API key set.")
            return
        }
        let client = clientFactory(keyStore)
        let request = AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 1,
            messages: [Message(role: .user, content: .plain("hi"))],
            thinking: .disabled
        )
        do {
            let response = try await client.send(request)
            testResult = .success(
                "Connected. Model: \(response.model). Tokens: \(response.usage.summary)"
            )
        } catch let error as AnthropicAPIError {
            testResult = .failure(error.localizedDescription)
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }

    // MARK: - Convenience for the view

    var isCloud: Bool {
        get { settings.processingMode == .cloud }
        set { settings.processingMode = newValue ? .cloud : .privateLocal }
    }

    func resetToDefaults() {
        settingsStore.reset()
        settings = settingsStore.load()
    }
}
