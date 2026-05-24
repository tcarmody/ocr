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

    // MARK: - Tool use (agentic loop)

    /// Tool the model can call mid-turn. Mirrors the Anthropic
    /// `Tool` shape but with Ollama's wire format
    /// (`type: function, function: { name, description, parameters }`).
    /// `parametersJSON` is the raw JSON Schema bytes the caller
    /// already has — the same shape `LibraryChatTools` produces for
    /// the cloud path, reused verbatim.
    public struct ToolDescriptor: Sendable {
        public let name: String
        public let description: String
        public let parametersJSON: Data

        public init(name: String, description: String, parametersJSON: Data) {
            self.name = name
            self.description = description
            self.parametersJSON = parametersJSON
        }
    }

    /// One tool invocation the model requested. `id` is synthesized
    /// (UUID) because Ollama doesn't always include one — the
    /// agentic loop carries the id back as a key for the matching
    /// tool result message even though Ollama's wire shape doesn't
    /// require it (no `tool_use_id` round-trip like Anthropic).
    public struct ToolCall: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let argumentsJSON: Data
    }

    /// One message in the agentic conversation. Richer than
    /// `ChatHistoryMessage` because the tool path needs assistant
    /// turns that carry `tool_calls` and dedicated tool-result
    /// turns (Ollama role: "tool").
    public enum AgenticMessage: Sendable {
        case system(String)
        case user(String)
        case assistant(text: String, toolCalls: [ToolCall])
        case toolResult(name: String, content: String)
    }

    /// One assistant turn parsed from `/api/chat`. When `toolCalls`
    /// is empty, `text` is the final answer (or partial answer the
    /// loop should append). When non-empty, the caller dispatches
    /// the calls, appends their results as `.toolResult` messages,
    /// and re-sends.
    public struct AssistantResponse: Sendable {
        public let text: String
        public let toolCalls: [ToolCall]
    }

    /// One round-trip of the agentic chat loop. Non-streaming —
    /// each round is a full request/response cycle. Streaming the
    /// final-answer round is a follow-up; for v1 we mirror the
    /// cloud agentic path's non-streaming shape.
    ///
    /// Models that don't support tool use (Gemma family, smaller
    /// models without function-calling templates) will simply
    /// respond with text and no `tool_calls` — the loop exits as if
    /// the model had everything it needed. No capability detection
    /// or graceful-fallback machinery is required for that case;
    /// the absence of `tool_calls` IS the signal.
    public func chatAgentic(
        model: String,
        messages: [AgenticMessage],
        tools: [ToolDescriptor]
    ) async throws -> AssistantResponse {
        let wireTools = try tools.map { tool in
            AgenticChatRequestBody.ToolWire(
                type: "function",
                function: AgenticChatRequestBody.ToolWire.Function(
                    name: tool.name,
                    description: tool.description,
                    // Hand the JSON-Schema bytes through as a generic
                    // JSON value so we don't have to re-encode them.
                    parameters: try AnyCodable(jsonBytes: tool.parametersJSON)
                )
            )
        }
        let body = AgenticChatRequestBody(
            model: model,
            messages: messages.map(Self.wireMessage(_:)),
            tools: wireTools,
            stream: false
        )
        let request = try buildRequest(path: "/api/chat", body: body)
        let (data, _) = try await sendOnce(request, modelHint: model)
        let envelope: AgenticChatResponseBody
        do {
            envelope = try Self.decoder.decode(
                AgenticChatResponseBody.self, from: data
            )
        } catch {
            throw OllamaError.decode(String(describing: error))
        }
        let calls: [ToolCall] = (envelope.message.tool_calls ?? []).map { wire in
            let argsData = (try? Self.encoder.encode(wire.function.arguments))
                ?? Data("{}".utf8)
            return ToolCall(
                id: UUID().uuidString,
                name: wire.function.name,
                argumentsJSON: argsData
            )
        }
        return AssistantResponse(
            text: envelope.message.content ?? "",
            toolCalls: calls
        )
    }

    /// One event in the streaming agentic chat. Callers iterate the
    /// `AsyncThrowingStream` and update their UI for each — `.textDelta`
    /// for incremental token output, `.toolCalls` when the model
    /// requests one or more tool invocations (stream terminates
    /// after this frame; caller dispatches and re-enters the loop),
    /// `.done` for stream end without tool calls (final answer).
    public enum AgenticStreamEvent: Sendable {
        case textDelta(String)
        case toolCalls([ToolCall])
        case done
    }

    /// Streaming agentic chat — same shape as `chatAgentic` but
    /// yields incremental token deltas via NDJSON. When the model
    /// emits tool_calls, the stream yields a `.toolCalls(...)`
    /// event and terminates; the caller dispatches the calls,
    /// appends `.toolResult` to its message thread, and starts
    /// a fresh streaming round.
    ///
    /// Restores the streaming UX Ollama users had on the
    /// pre-tool-use path (commit c1a7562 made every round
    /// non-streaming as the simplest first cut). With this method,
    /// the model's text deltas appear live during the final-answer
    /// round, and intermediate tool-using rounds still feel
    /// responsive via the toolStatus indicator.
    public nonisolated func chatAgenticStream(
        model: String,
        messages: [AgenticMessage],
        tools: [ToolDescriptor]
    ) -> AsyncThrowingStream<AgenticStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runChatAgenticStream(
                    model: model,
                    messages: messages,
                    tools: tools,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runChatAgenticStream(
        model: String,
        messages: [AgenticMessage],
        tools: [ToolDescriptor],
        continuation: AsyncThrowingStream<AgenticStreamEvent, Error>.Continuation
    ) async {
        let wireTools: [AgenticChatRequestBody.ToolWire]
        do {
            wireTools = try tools.map { tool in
                AgenticChatRequestBody.ToolWire(
                    type: "function",
                    function: AgenticChatRequestBody.ToolWire.Function(
                        name: tool.name,
                        description: tool.description,
                        parameters: try AnyCodable(jsonBytes: tool.parametersJSON)
                    )
                )
            }
        } catch {
            continuation.finish(throwing: error)
            return
        }
        let body = AgenticChatRequestBody(
            model: model,
            messages: messages.map(Self.wireMessage(_:)),
            tools: wireTools,
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
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            continuation.finish(throwing: OllamaError.serverError(
                status: http.statusCode, message: nil
            ))
            return
        }
        // NDJSON pull. Tool_calls arrive in a single frame (Ollama
        // doesn't stream individual tool-call argument tokens); when
        // we see one, yield it and stop. Plain-text deltas yield as
        // `.textDelta`. The terminal `done: true` frame with no
        // content + no tool_calls yields `.done`.
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
                let frame: AgenticStreamFrame
                do {
                    frame = try Self.decoder.decode(
                        AgenticStreamFrame.self, from: lineData
                    )
                } catch {
                    // Heartbeat / partial line / unrecognized shape —
                    // skip rather than tearing down the stream.
                    continue
                }
                if let calls = frame.message?.tool_calls, !calls.isEmpty {
                    let mapped: [ToolCall] = calls.map { wire in
                        let argsData = (try? Self.encoder.encode(wire.function.arguments))
                            ?? Data("{}".utf8)
                        return ToolCall(
                            id: UUID().uuidString,
                            name: wire.function.name,
                            argumentsJSON: argsData
                        )
                    }
                    continuation.yield(.toolCalls(mapped))
                    continuation.finish()
                    return
                }
                if let content = frame.message?.content, !content.isEmpty {
                    continuation.yield(.textDelta(content))
                }
                if frame.done == true {
                    continuation.yield(.done)
                    continuation.finish()
                    return
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: OllamaError.network(error))
        }
    }

    /// One NDJSON frame from `/api/chat` with `stream: true` and
    /// `tools:` in the request. Shape mirrors the non-streaming
    /// `AgenticChatResponseBody` but every field is optional so
    /// heartbeats and partial frames decode cleanly.
    fileprivate struct AgenticStreamFrame: Decodable {
        let message: AssistantFragment?
        let done: Bool?

        struct AssistantFragment: Decodable {
            let role: String?
            let content: String?
            let tool_calls: [AgenticChatResponseBody.ToolCallWire]?

            private enum CodingKeys: String, CodingKey {
                case role, content, tool_calls
            }
        }
    }

    /// Translate the AgenticMessage enum into wire-level messages.
    /// Tool results use Ollama's `{role: "tool", content: ...,
    /// name: ...}` shape; assistant turns with tool calls inline
    /// the calls under `tool_calls`.
    nonisolated private static func wireMessage(
        _ msg: AgenticMessage
    ) -> AgenticChatRequestBody.MessageWire {
        switch msg {
        case .system(let s):
            return AgenticChatRequestBody.MessageWire(
                role: "system", content: s, name: nil, tool_calls: nil
            )
        case .user(let s):
            return AgenticChatRequestBody.MessageWire(
                role: "user", content: s, name: nil, tool_calls: nil
            )
        case .assistant(let text, let calls):
            let wireCalls: [AgenticChatRequestBody.ToolCallWire]?
            if calls.isEmpty {
                wireCalls = nil
            } else {
                wireCalls = calls.map { call in
                    let args = (try? Self.decoder.decode(
                        AnyCodable.self, from: call.argumentsJSON
                    )) ?? AnyCodable(.object([:]))
                    return AgenticChatRequestBody.ToolCallWire(
                        function: AgenticChatRequestBody.ToolCallWire.FunctionWire(
                            name: call.name, arguments: args
                        )
                    )
                }
            }
            return AgenticChatRequestBody.MessageWire(
                role: "assistant",
                content: text,
                name: nil,
                tool_calls: wireCalls
            )
        case .toolResult(let name, let content):
            return AgenticChatRequestBody.MessageWire(
                role: "tool",
                content: content,
                name: name,
                tool_calls: nil
            )
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

    // MARK: - Agentic wire types

    fileprivate struct AgenticChatRequestBody: Encodable {
        let model: String
        let messages: [MessageWire]
        let tools: [ToolWire]
        let stream: Bool

        struct MessageWire: Encodable {
            let role: String
            let content: String
            let name: String?
            // Ollama key is `tool_calls`; Encodable maps `tool_calls`
            // directly via `CodingKeys.snakeCase` would be wrong
            // (the rest of the body uses camel-equivalent names).
            // Use a manual CodingKey instead.
            let tool_calls: [ToolCallWire]?

            private enum CodingKeys: String, CodingKey {
                case role, content, name
                case tool_calls
            }
        }

        struct ToolCallWire: Codable {
            let function: FunctionWire

            struct FunctionWire: Codable {
                let name: String
                let arguments: AnyCodable
            }
        }

        struct ToolWire: Encodable {
            let type: String
            let function: Function

            struct Function: Encodable {
                let name: String
                let description: String
                let parameters: AnyCodable
            }
        }
    }

    fileprivate struct AgenticChatResponseBody: Decodable {
        let model: String
        let message: AssistantMessage
        let done: Bool

        struct AssistantMessage: Decodable {
            let role: String
            let content: String?
            let tool_calls: [ToolCallWire]?

            private enum CodingKeys: String, CodingKey {
                case role, content, tool_calls
            }
        }

        struct ToolCallWire: Decodable {
            let function: FunctionWire

            struct FunctionWire: Decodable {
                let name: String
                let arguments: AnyCodable
            }
        }
    }

    /// Minimal "anything JSON" Codable so the agentic request/response
    /// can shuttle the model's `arguments` payload (and the tools'
    /// `parameters` JSON Schema) through without us having to model
    /// every shape. Encoder/decoder both pass through arbitrary
    /// nested object / array / scalar trees.
    fileprivate struct AnyCodable: Codable {
        let value: Value

        enum Value {
            case object([String: AnyCodable])
            case array([AnyCodable])
            case string(String)
            case number(Double)
            case bool(Bool)
            case null
        }

        init(_ value: Value) { self.value = value }

        /// Construct from raw JSON bytes — used when threading a
        /// JSON-Schema (`Tool.parametersJSON`) through.
        init(jsonBytes: Data) throws {
            let raw = try JSONSerialization.jsonObject(with: jsonBytes)
            self.value = AnyCodable.lift(raw)
        }

        private static func lift(_ raw: Any) -> Value {
            if let dict = raw as? [String: Any] {
                var out: [String: AnyCodable] = [:]
                for (k, v) in dict {
                    out[k] = AnyCodable(AnyCodable.lift(v))
                }
                return .object(out)
            }
            if let arr = raw as? [Any] {
                return .array(arr.map { AnyCodable(AnyCodable.lift($0)) })
            }
            if let s = raw as? String { return .string(s) }
            if let b = raw as? Bool { return .bool(b) }
            if let n = raw as? NSNumber {
                // NSNumber is what JSONSerialization hands back for
                // numeric literals; check if it's actually a Bool
                // (CFBoolean bridges) before treating as double.
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    return .bool(n.boolValue)
                }
                return .number(n.doubleValue)
            }
            return .null
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { value = .null; return }
            if let b = try? c.decode(Bool.self) { value = .bool(b); return }
            if let d = try? c.decode(Double.self) { value = .number(d); return }
            if let s = try? c.decode(String.self) { value = .string(s); return }
            if let a = try? c.decode([AnyCodable].self) { value = .array(a); return }
            if let o = try? c.decode([String: AnyCodable].self) {
                value = .object(o); return
            }
            value = .null
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch value {
            case .null:           try c.encodeNil()
            case .bool(let b):    try c.encode(b)
            case .number(let n):
                // Preserve integer shape when the model passed an
                // integer (Ollama's arguments often have integer
                // fields like top_k / book_limit).
                if n.rounded() == n,
                   n >= Double(Int.min), n <= Double(Int.max) {
                    try c.encode(Int(n))
                } else {
                    try c.encode(n)
                }
            case .string(let s):  try c.encode(s)
            case .array(let a):   try c.encode(a)
            case .object(let o):  try c.encode(o)
            }
        }
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
