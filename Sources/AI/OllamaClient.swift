import Foundation

/// Minimal HTTP client for an Ollama daemon at `localhost:11434`.
/// Non-streaming for v1 — matches `BookChatViewModel`'s synchronous
/// send path. Streaming via Ollama's NDJSON format is straightforward
/// to add later if interactive token output becomes desirable.
///
/// All inference runs locally via the user's Ollama installation.
/// No API key, no network egress, no per-token cost.
public actor OllamaClient {

    public struct Config: Sendable {
        public var baseURL: URL
        /// Long timeout — local inference on a 26B model can take
        /// 30–90 s for a multi-paragraph reply. Anthropic's 120 s
        /// default is fine for Cloud calls but tight for local
        /// when context is heavy. 300 s gives MoE models headroom.
        public var requestTimeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "http://localhost:11434")!,
            requestTimeout: TimeInterval = 300
        ) {
            self.baseURL = baseURL
            self.requestTimeout = requestTimeout
        }

        public static let `default` = Config()
    }

    public let config: Config

    public init(config: Config = .default) {
        self.config = config
    }

    // MARK: - Public API

    /// One non-streaming chat round-trip. System + user prompt in,
    /// assistant text out.
    public func chat(
        model: String,
        system: String,
        userMessage: String
    ) async throws -> String {
        let body = ChatRequestBody(
            model: model,
            messages: [
                Message(role: "system", content: system),
                Message(role: "user", content: userMessage),
            ],
            stream: false
        )
        let request = try buildRequest(path: "/api/chat", body: body)
        let (data, response) = try await sendOnce(request, modelHint: model)
        do {
            let envelope = try Self.decoder.decode(ChatResponseBody.self, from: data)
            return envelope.message.content
        } catch {
            throw OllamaError.decode(String(describing: error))
        }
        _ = response
    }

    /// True when the daemon is reachable. Cheap probe — used by the
    /// setup wizard and the chat pane's "is Ollama up?" banner.
    public func ping() async -> Bool {
        var request = URLRequest(
            url: config.baseURL.appendingPathComponent("api/tags"),
            timeoutInterval: 3
        )
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { $0.statusCode == 200 } ?? false
        } catch {
            return false
        }
    }

    /// Returns the list of locally-pulled model tags. Caller can use
    /// this to verify a model exists before sending a chat request.
    public func installedModels() async throws -> [String] {
        var request = URLRequest(
            url: config.baseURL.appendingPathComponent("api/tags"),
            timeoutInterval: 5
        )
        request.httpMethod = "GET"
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OllamaError.daemonNotReachable
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.serverError(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                message: nil
            )
        }
        do {
            let envelope = try Self.decoder.decode(TagsResponseBody.self, from: data)
            return envelope.models.map(\.name)
        } catch {
            throw OllamaError.decode(String(describing: error))
        }
    }

    // MARK: - Internals

    private func sendOnce(
        _ request: URLRequest, modelHint: String
    ) async throws -> (Data, URLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
                                             || urlError.code == .networkConnectionLost {
            throw OllamaError.daemonNotReachable
        } catch {
            throw OllamaError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.decode("non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return (data, response)
        case 404:
            // Ollama returns 404 with `{"error":"model 'X' not found, ..."}`
            // when the requested model isn't pulled.
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("not found") {
                throw OllamaError.modelNotPulled(name: modelHint)
            }
            throw OllamaError.serverError(status: 404, message: body.isEmpty ? nil : body)
        default:
            let body = String(data: data, encoding: .utf8)
            throw OllamaError.serverError(
                status: http.statusCode,
                message: body?.isEmpty == false ? body : nil
            )
        }
    }

    private func buildRequest(
        path: String, body: some Encodable
    ) throws -> URLRequest {
        var request = URLRequest(
            url: config.baseURL.appendingPathComponent(path),
            timeoutInterval: config.requestTimeout
        )
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw OllamaError.decode("encoding failed: \(error)")
        }
        return request
    }

    // MARK: - Wire types

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct ChatRequestBody: Codable {
        let model: String
        let messages: [Message]
        let stream: Bool
    }

    private struct ChatResponseBody: Codable {
        let model: String
        let message: Message
        let done: Bool
    }

    private struct TagsResponseBody: Codable {
        struct Model: Codable {
            let name: String
            let size: Int?
        }
        let models: [Model]
    }

    // MARK: - JSON

    nonisolated static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    nonisolated static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
