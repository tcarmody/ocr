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
    /// Mirrored "is a Gemini key stored." Drives the Replace/Save
    /// affordance for the Gemini key field.
    @Published private(set) var hasGeminiKey: Bool
    /// Mirrored "is a Google Cloud Vision key stored." Same shape.
    @Published private(set) var hasGoogleCloudVisionKey: Bool
    /// Mirrored "is a LandingAI ADE key stored." Same shape.
    @Published private(set) var hasLandingAIKey: Bool
    /// Plain-text API key for the entry field. Only populated when
    /// the user is actively editing — saved to keychain on `commit`.
    @Published var pendingAPIKey: String = ""
    /// Plain-text Gemini key entry buffer.
    @Published var pendingGeminiKey: String = ""
    /// Plain-text Google Cloud Vision key entry buffer.
    @Published var pendingGoogleCloudVisionKey: String = ""
    /// Plain-text LandingAI ADE key entry buffer.
    @Published var pendingLandingAIKey: String = ""
    /// Result of the last Anthropic "Test Connection" call. Nil
    /// before any test fires; non-nil shows an inline status message.
    @Published var testResult: TestResult?
    /// Result of the last Gemini test. Per-provider field so the
    /// four rows can show their own status without colliding.
    @Published var geminiTestResult: TestResult?
    /// Result of the last Google Cloud Vision test.
    @Published var googleCloudVisionTestResult: TestResult?
    /// Result of the last LandingAI ADE test.
    @Published var landingAITestResult: TestResult?

    enum TestResult {
        case success(String)
        case failure(String)
    }

    let settingsStore: AISettingsStore
    let keyStore: AnthropicAPIKeyStore
    let geminiKeyStore: GeminiAPIKeyStore
    let googleCloudVisionKeyStore: GoogleCloudVisionAPIKeyStore
    let landingAIKeyStore: LandingAIAPIKeyStore
    /// Closure that builds an API client from the current key. Held
    /// as a closure so tests can swap in a mocked transport.
    let clientFactory: @MainActor (AnthropicAPIKeyStore) -> AnthropicAPIClient

    init(
        settingsStore: AISettingsStore = AISettingsStore(),
        keyStore: AnthropicAPIKeyStore = AnthropicAPIKeyStore(),
        geminiKeyStore: GeminiAPIKeyStore = GeminiAPIKeyStore(),
        googleCloudVisionKeyStore: GoogleCloudVisionAPIKeyStore = GoogleCloudVisionAPIKeyStore(),
        landingAIKeyStore: LandingAIAPIKeyStore = LandingAIAPIKeyStore(),
        clientFactory: @escaping @MainActor (AnthropicAPIKeyStore) -> AnthropicAPIClient = { keyStore in
            AnthropicAPIClient(apiKeyProvider: { keyStore.read() })
        }
    ) {
        self.settingsStore = settingsStore
        self.keyStore = keyStore
        self.geminiKeyStore = geminiKeyStore
        self.googleCloudVisionKeyStore = googleCloudVisionKeyStore
        self.landingAIKeyStore = landingAIKeyStore
        self.clientFactory = clientFactory
        self.settings = settingsStore.load()
        self.hasAPIKey = keyStore.hasKey
        self.hasGeminiKey = geminiKeyStore.hasKey
        self.hasGoogleCloudVisionKey = googleCloudVisionKeyStore.hasKey
        self.hasLandingAIKey = landingAIKeyStore.hasKey
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

    // MARK: - Gemini key flow

    func commitGeminiKey() {
        let trimmed = pendingGeminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try geminiKeyStore.delete()
            } else {
                try geminiKeyStore.write(trimmed)
            }
            hasGeminiKey = geminiKeyStore.hasKey
            pendingGeminiKey = ""
        } catch {
            testResult = .failure("Couldn't save Gemini key: \(error.localizedDescription)")
        }
    }

    func deleteGeminiKey() {
        do {
            try geminiKeyStore.delete()
            hasGeminiKey = geminiKeyStore.hasKey
            pendingGeminiKey = ""
        } catch {
            testResult = .failure("Couldn't remove Gemini key: \(error.localizedDescription)")
        }
    }

    // MARK: - Google Cloud Vision key flow

    func commitGoogleCloudVisionKey() {
        let trimmed = pendingGoogleCloudVisionKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try googleCloudVisionKeyStore.delete()
            } else {
                try googleCloudVisionKeyStore.write(trimmed)
            }
            hasGoogleCloudVisionKey = googleCloudVisionKeyStore.hasKey
            pendingGoogleCloudVisionKey = ""
        } catch {
            testResult = .failure(
                "Couldn't save Cloud Vision key: \(error.localizedDescription)"
            )
        }
    }

    func deleteGoogleCloudVisionKey() {
        do {
            try googleCloudVisionKeyStore.delete()
            hasGoogleCloudVisionKey = googleCloudVisionKeyStore.hasKey
            pendingGoogleCloudVisionKey = ""
        } catch {
            testResult = .failure(
                "Couldn't remove Cloud Vision key: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - LandingAI ADE key flow

    func commitLandingAIKey() {
        let trimmed = pendingLandingAIKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try landingAIKeyStore.delete()
            } else {
                try landingAIKeyStore.write(trimmed)
            }
            hasLandingAIKey = landingAIKeyStore.hasKey
            pendingLandingAIKey = ""
        } catch {
            testResult = .failure(
                "Couldn't save LandingAI key: \(error.localizedDescription)"
            )
        }
    }

    func deleteLandingAIKey() {
        do {
            try landingAIKeyStore.delete()
            hasLandingAIKey = landingAIKeyStore.hasKey
            pendingLandingAIKey = ""
        } catch {
            testResult = .failure(
                "Couldn't remove LandingAI key: \(error.localizedDescription)"
            )
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

    /// Probe the Gemini API by listing available models. Free —
    /// `GET /v1beta/models` doesn't count against generation quota
    /// and returns a list of models the key has access to.
    func testGeminiConnection() async {
        guard hasGeminiKey, let key = geminiKeyStore.read(), !key.isEmpty else {
            geminiTestResult = .failure("No Gemini key set.")
            return
        }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                geminiTestResult = .failure("Non-HTTP response.")
                return
            }
            if (200..<300).contains(http.statusCode) {
                let count = Self.countGeminiModels(in: data)
                geminiTestResult = .success(
                    count > 0
                        ? "Connected. \(count) models available."
                        : "Connected."
                )
            } else {
                let message = Self.googleErrorMessage(in: data)
                    ?? "HTTP \(http.statusCode)"
                geminiTestResult = .failure(message)
            }
        } catch {
            geminiTestResult = .failure(error.localizedDescription)
        }
    }

    /// Probe the Google Cloud Vision API with a tiny 1×1 PNG +
    /// `LABEL_DETECTION` request. Costs ~$0.0015 — the cheapest
    /// usable annotate call. Returning 200 with an empty
    /// `responses` array confirms the key is valid and the Vision
    /// API is enabled on the project. Anything 4xx surfaces the
    /// server's error message (typical: `PERMISSION_DENIED` when
    /// the Vision API isn't enabled).
    func testGoogleCloudVisionConnection() async {
        guard hasGoogleCloudVisionKey,
              let key = googleCloudVisionKeyStore.read(),
              !key.isEmpty
        else {
            googleCloudVisionTestResult = .failure("No Cloud Vision key set.")
            return
        }
        // 1x1 transparent PNG (smallest valid PNG bytes).
        let onePixelPNG: [UInt8] = [
            0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
            0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
            0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
            0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,
            0x89,0x00,0x00,0x00,0x0D,0x49,0x44,0x41,
            0x54,0x78,0x9C,0x63,0x00,0x01,0x00,0x00,
            0x05,0x00,0x01,0x0D,0x0A,0x2D,0xB4,0x00,
            0x00,0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,
            0x42,0x60,0x82
        ]
        let base64 = Data(onePixelPNG).base64EncodedString()
        let bodyJSON = """
        {"requests":[{"image":{"content":"\(base64)"},"features":[{"type":"LABEL_DETECTION","maxResults":1}]}]}
        """
        guard let url = URL(string: "https://vision.googleapis.com/v1/images:annotate?key=\(key)") else {
            googleCloudVisionTestResult = .failure("Invalid URL.")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyJSON.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                googleCloudVisionTestResult = .failure("Non-HTTP response.")
                return
            }
            if (200..<300).contains(http.statusCode) {
                googleCloudVisionTestResult = .success("Connected.")
            } else {
                let message = Self.googleErrorMessage(in: data)
                    ?? "HTTP \(http.statusCode)"
                googleCloudVisionTestResult = .failure(message)
            }
        } catch {
            googleCloudVisionTestResult = .failure(error.localizedDescription)
        }
    }

    /// Probe the LandingAI ADE API. There's no auth-only ping
    /// endpoint; the cheapest probe is a real `:parse` call with a
    /// 1×1 PNG. Costs ~$0.03 — significant for a Test button, so
    /// the UI caption flags the cost. A 200 response confirms the
    /// key + endpoint, even when the parsed markdown is empty.
    func testLandingAIConnection() async {
        guard hasLandingAIKey,
              let key = landingAIKeyStore.read(),
              !key.isEmpty
        else {
            landingAITestResult = .failure("No LandingAI key set.")
            return
        }
        let onePixelPNG: [UInt8] = [
            0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
            0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
            0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
            0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,
            0x89,0x00,0x00,0x00,0x0D,0x49,0x44,0x41,
            0x54,0x78,0x9C,0x63,0x00,0x01,0x00,0x00,
            0x05,0x00,0x01,0x0D,0x0A,0x2D,0xB4,0x00,
            0x00,0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,
            0x42,0x60,0x82
        ]
        let png = Data(onePixelPNG)
        let boundary = "Boundary-" + UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\ndpt-2-latest\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"document\"; filename=\"probe.png\"\r\n".data(using: .utf8)!
        )
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(png)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        guard let url = URL(string: "https://api.va.landing.ai/v1/ade/parse") else {
            landingAITestResult = .failure("Invalid URL.")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.addValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                landingAITestResult = .failure("Non-HTTP response.")
                return
            }
            if (200..<300).contains(http.statusCode) {
                landingAITestResult = .success("Connected.")
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                let trimmed = body.count > 140
                    ? String(body.prefix(140)) + "…" : body
                landingAITestResult = .failure(
                    "HTTP \(http.statusCode): \(trimmed)"
                )
            }
        } catch {
            landingAITestResult = .failure(error.localizedDescription)
        }
    }

    /// Extract `error.message` from a Google API error envelope.
    /// Returns nil when the body isn't a recognizable Google
    /// error JSON.
    private static func googleErrorMessage(in data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let err = obj["error"] as? [String: Any],
              let m = err["message"] as? String
        else { return nil }
        return m
    }

    /// Count `models[].name` entries in a Gemini list-models
    /// response. Defensive: returns 0 if the body shape is
    /// unexpected (a successful 200 with empty list still tells
    /// the user "connected").
    private static func countGeminiModels(in data: Data) -> Int {
        guard let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let list = obj["models"] as? [Any]
        else { return 0 }
        return list.count
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
