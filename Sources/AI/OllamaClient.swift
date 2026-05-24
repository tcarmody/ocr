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

    /// One conversation turn passed to `chat` / `chatStream` as
    /// prior context. Maps 1:1 onto the wire-level `role` /
    /// `content` Ollama expects.
    public struct ChatHistoryMessage: Sendable {
        public enum Role: String, Sendable {
            case user, assistant
        }
        public let role: Role
        public let content: String
        public init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }

    // MARK: - Public API

    /// One non-streaming chat round-trip. System + user prompt in,
    /// assistant text out. `history` carries prior turns when the
    /// caller wants the model to see conversation context; defaults
    /// empty so existing single-turn callers don't need to opt in.
    public func chat(
        model: String,
        system: String,
        history: [ChatHistoryMessage] = [],
        userMessage: String
    ) async throws -> String {
        var messages: [Message] = [Message(role: "system", content: system)]
        for m in history {
            messages.append(Message(role: m.role.rawValue, content: m.content))
        }
        messages.append(Message(role: "user", content: userMessage))
        let body = ChatRequestBody(
            model: model,
            messages: messages,
            stream: false
        )
        let request = try buildRequest(path: "/api/chat", body: body)
        let (data, _) = try await sendOnce(request, modelHint: model)
        do {
            let envelope = try Self.decoder.decode(ChatResponseBody.self, from: data)
            return envelope.message.content
        } catch {
            throw OllamaError.decode(String(describing: error))
        }
    }

    /// Streaming chat. Yields incremental `content` deltas as
    /// Ollama emits them. Stream terminates after the daemon
    /// signals `done: true`. Cancellation propagates: cancelling
    /// the consuming Task terminates the URLSession bytes pull.
    ///
    /// Wire format is NDJSON — one JSON object per line; each
    /// carries `{message: {content: "…"}, done: false}` for
    /// deltas and `{done: true, …}` for the terminal frame.
    /// Lines arrive incrementally so we can't decode the body
    /// in one shot.
    public nonisolated func chatStream(
        model: String,
        system: String,
        history: [ChatHistoryMessage] = [],
        userMessage: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runChatStream(
                    model: model,
                    system: system,
                    history: history,
                    userMessage: userMessage,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runChatStream(
        model: String,
        system: String,
        history: [ChatHistoryMessage],
        userMessage: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        var messages: [Message] = [Message(role: "system", content: system)]
        for m in history {
            messages.append(Message(role: m.role.rawValue, content: m.content))
        }
        messages.append(Message(role: "user", content: userMessage))
        let body = ChatRequestBody(
            model: model,
            messages: messages,
            stream: true
        )
        let request: URLRequest
        do {
            request = try buildRequest(path: "/api/chat", body: body)
        } catch {
            continuation.finish(throwing: error)
            return
        }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
                                             || urlError.code == .networkConnectionLost {
            continuation.finish(throwing: OllamaError.daemonNotReachable)
            return
        } catch {
            continuation.finish(throwing: OllamaError.network(error))
            return
        }
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: OllamaError.decode("non-HTTP response"))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            // Drain the body to surface the error message — same
            // posture as sendOnce for the non-streaming path.
            var collected = Data()
            do {
                for try await byte in bytes { collected.append(byte) }
            } catch { /* ignore — main error is the status code */ }
            let bodyString = String(data: collected, encoding: .utf8) ?? ""
            if http.statusCode == 404, bodyString.contains("not found") {
                continuation.finish(throwing: OllamaError.modelNotPulled(name: model))
            } else {
                continuation.finish(throwing: OllamaError.serverError(
                    status: http.statusCode,
                    message: bodyString.isEmpty ? nil : bodyString
                ))
            }
            return
        }
        // NDJSON pull. URLSession.AsyncBytes.lines gives us
        // one NDJSON object per line; decode each and yield the
        // content delta. Empty content (a heartbeat frame from
        // the daemon, or the terminal `done: true` envelope
        // with no message content) is skipped.
        do {
            for try await line in bytes.lines {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                guard !line.isEmpty,
                      let lineData = line.data(using: .utf8) else {
                    continue
                }
                let frame = try Self.decoder.decode(
                    StreamFrame.self, from: lineData
                )
                if let content = frame.message?.content, !content.isEmpty {
                    continuation.yield(content)
                }
                if frame.done == true {
                    continuation.finish()
                    return
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: OllamaError.network(error))
        }
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

    /// Embed a batch of texts via `/api/embed`. The daemon must have
    /// the requested embedding model pulled (e.g.
    /// `ollama pull nomic-embed-text`); if it's missing, the call
    /// returns `OllamaError.modelNotPulled`.
    ///
    /// Vectors come back as `[Double]` from Ollama; we down-convert
    /// to `[Float]` to match the rest of the pipeline (sidecar
    /// storage and cosine math).
    public func embed(model: String, texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let body = EmbedRequestBody(model: model, input: texts)
        let request = try buildRequest(path: "/api/embed", body: body)
        let (data, _) = try await sendOnce(request, modelHint: model)
        do {
            let envelope = try Self.decoder.decode(EmbedResponseBody.self, from: data)
            return envelope.embeddings.map { $0.map(Float.init) }
        } catch {
            throw OllamaError.decode(String(describing: error))
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

    /// One NDJSON frame from `/api/chat` with `stream: true`. The
    /// daemon emits both delta frames (`message.content` carries
    /// the incremental text, `done: false`) and a terminal
    /// envelope (`done: true`, often with no message content).
    /// `message` is optional so the terminal frame parses
    /// cleanly. `done` is optional so heartbeat frames (rare but
    /// possible) don't break decode.
    private struct StreamFrame: Codable {
        let message: Message?
        let done: Bool?
    }

    private struct EmbedRequestBody: Codable {
        let model: String
        /// Ollama's `/api/embed` accepts either a single string or
        /// an array of strings; we always send the array form so the
        /// response shape is consistent.
        let input: [String]
    }

    private struct EmbedResponseBody: Codable {
        /// Always present, indexed parallel to the input array. Ollama
        /// reports `[Double]` per text; the client down-converts.
        let embeddings: [[Double]]
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
