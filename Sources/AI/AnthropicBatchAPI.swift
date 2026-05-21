import Foundation

/// Tier 9 / E-Batches. Anthropic Messages Batches API
/// (`POST /v1/messages/batches`). Discounts input + output tokens
/// 50% in exchange for asynchronous processing — submit a batch
/// of requests, poll until the server reports `ended`, fetch the
/// JSONL result file, dispatch each line back to the matching
/// caller via `customId`.
///
/// Use cases:
///   * **Whole-page Sonnet OCR** — tens to hundreds of pages per
///     book. Largest cost line item; biggest absolute savings.
///   * **Hard-region OCR** — variable count, but single books can
///     fire 50-200 calls in scanned-Greek territory.
///   * **Post-OCR Haiku cleanup** — when triggered widely on a
///     scanned book.
///
/// Doesn't apply to one-call-per-book features (TOC parsing,
/// chapter classification, metadata extraction, coherence pass)
/// — those don't have anything to batch.
///
/// The transport layer is shared with `AnthropicAPIClient` via
/// the `AnthropicTransport` protocol so swapping URLSession for
/// a mock is the same code path the Messages API uses.

// MARK: - Submit

/// Body of `POST /v1/messages/batches`. Up to 100K requests per
/// batch (Anthropic's documented limit); we cap at a much smaller
/// number per book in practice.
public struct AnthropicBatchSubmitRequest: Sendable, Encodable, Equatable {
    public var requests: [Request]

    public init(requests: [Request]) {
        self.requests = requests
    }

    /// One entry inside a batch — a `customId` the caller chooses
    /// to correlate the response back to its origin, plus the
    /// regular `params` (a full `AnthropicMessageRequest` body).
    public struct Request: Sendable, Encodable, Equatable {
        /// Unique within this batch. The caller sets it (typically
        /// "page-NNN" or a UUID) and looks it up in the result
        /// stream to dispatch each response.
        public var customId: String
        public var params: AnthropicMessageRequest

        public init(customId: String, params: AnthropicMessageRequest) {
            self.customId = customId
            self.params = params
        }

        private enum CodingKeys: String, CodingKey {
            case customId = "custom_id"
            case params
        }
    }
}

/// Response from `POST /v1/messages/batches` — the server has
/// accepted the batch and is processing asynchronously. The
/// caller polls `GET /v1/messages/batches/{id}` for status.
public struct AnthropicBatchSubmitResponse: Sendable, Decodable, Equatable {
    /// Server-assigned identifier for this batch.
    public var id: String
    /// Initial status — usually `in_progress`. Caller polls until
    /// `ended`.
    public var processingStatus: ProcessingStatus
    /// `archived_at` and similar timestamps are present in the
    /// real response but Phase-1 callers don't use them.

    public init(id: String, processingStatus: ProcessingStatus) {
        self.id = id
        self.processingStatus = processingStatus
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case processingStatus = "processing_status"
    }

    public enum ProcessingStatus: String, Sendable, Codable, Equatable {
        case inProgress = "in_progress"
        case canceling
        case ended
    }
}

/// Body of `GET /v1/messages/batches/{id}`. Same shape as the
/// submit response plus a `request_counts` block + a
/// `results_url` once `processing_status == .ended`.
public struct AnthropicBatchStatusResponse: Sendable, Decodable, Equatable {
    public var id: String
    public var processingStatus: AnthropicBatchSubmitResponse.ProcessingStatus
    /// URL to GET for the JSONL result stream. Populated once the
    /// batch reaches `.ended`. Nil while in-progress.
    public var resultsUrl: String?

    public init(
        id: String,
        processingStatus: AnthropicBatchSubmitResponse.ProcessingStatus,
        resultsUrl: String? = nil
    ) {
        self.id = id
        self.processingStatus = processingStatus
        self.resultsUrl = resultsUrl
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case processingStatus = "processing_status"
        case resultsUrl = "results_url"
    }
}

/// One line of the `results_url` JSONL stream. The `customId` ties
/// the result back to the submit request; `result` carries either
/// the successful response body or an error envelope.
public struct AnthropicBatchResultLine: Sendable, Decodable, Equatable {
    public var customId: String
    public var result: Result

    public init(customId: String, result: Result) {
        self.customId = customId
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case customId = "custom_id"
        case result
    }

    public enum Result: Sendable, Equatable {
        /// Success — full message response, identical shape to
        /// the synchronous Messages API response.
        case succeeded(message: AnthropicMessageResponse)
        /// Server-side error for this individual request. Other
        /// requests in the batch may have succeeded.
        case errored(message: String)
        /// The model declined to respond (refusal stop reason).
        case refused(message: AnthropicMessageResponse)
        /// Batch was canceled before this request finished.
        case canceled
        /// Request expired (24h max processing window).
        case expired
    }
}

extension AnthropicBatchResultLine.Result: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, message, error
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "succeeded":
            let msg = try c.decode(
                AnthropicMessageResponse.self, forKey: .message
            )
            // The wire shape uses "succeeded" for both real
            // success and refusal; we split on `didRefuse` so
            // callers can branch cleanly.
            self = msg.didRefuse ? .refused(message: msg) : .succeeded(message: msg)
        case "errored":
            // The batch JSONL puts the error directly in the
            // `error` field as `{"type": "...", "message": "..."}`,
            // unlike the synchronous-API error envelope which
            // wraps that in another `{"type": "error", "error": ...}`
            // outer. Decode the inner shape; fall back to plain
            // string in case a future API change varies it.
            struct Inner: Decodable {
                let type: String?
                let message: String
            }
            if let inner = try? c.decode(Inner.self, forKey: .error) {
                self = .errored(message: inner.message)
            } else if let s = try? c.decode(String.self, forKey: .error) {
                self = .errored(message: s)
            } else {
                self = .errored(message: "unknown error")
            }
        case "canceled":
            self = .canceled
        case "expired":
            self = .expired
        default:
            self = .errored(message: "unrecognized result type: \(type)")
        }
    }
}

// MARK: - Client

/// Dedicated client for the Batches API. Shares the
/// `AnthropicTransport` abstraction with the synchronous
/// `AnthropicAPIClient` so test mocks work the same way.
public actor AnthropicBatchAPIClient {
    public struct Config: Sendable, Equatable {
        public var baseURL: URL
        public var apiVersion: String
        /// Polling cadence for `awaitCompletion`. Default 10s.
        /// Anthropic documents most batches completing within an
        /// hour, with a 24 h cap — a 10s tick gives reasonable
        /// status updates without hammering the API even for
        /// the faster end of that range.
        public var pollInterval: TimeInterval
        /// Hard timeout on `awaitCompletion`. 24h to match
        /// Anthropic's documented max processing window. Caller
        /// can pass shorter for tests.
        public var pollTimeout: TimeInterval
        public var requestTimeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "https://api.anthropic.com")!,
            apiVersion: String = "2023-06-01",
            pollInterval: TimeInterval = 10,
            pollTimeout: TimeInterval = 24 * 60 * 60,
            requestTimeout: TimeInterval = 120
        ) {
            self.baseURL = baseURL
            self.apiVersion = apiVersion
            self.pollInterval = pollInterval
            self.pollTimeout = pollTimeout
            self.requestTimeout = requestTimeout
        }
    }

    public let config: Config
    private let transport: any AnthropicTransport
    private let apiKeyProvider: @Sendable () -> String?
    /// Test seam — replaces `Task.sleep` for poll-loop testing.
    private let sleeper: (@Sendable (TimeInterval) async throws -> Void)?

    public init(
        config: Config = Config(),
        transport: any AnthropicTransport = URLSessionTransport(),
        apiKeyProvider: @escaping @Sendable () -> String?,
        sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) {
        self.config = config
        self.transport = transport
        self.apiKeyProvider = apiKeyProvider
        self.sleeper = sleeper
    }

    // MARK: - Submit

    /// Submit a batch. Returns the server-assigned id + initial
    /// processing status. Throws `AnthropicAPIError` on failure.
    public func submit(
        _ batch: AnthropicBatchSubmitRequest
    ) async throws -> AnthropicBatchSubmitResponse {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw AnthropicAPIError.missingAPIKey
        }
        var url = config.baseURL
        url.append(path: "v1/messages/batches")
        var ur = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        ur.httpMethod = "POST"
        ur.addValue("application/json", forHTTPHeaderField: "Content-Type")
        ur.addValue(key, forHTTPHeaderField: "x-api-key")
        ur.addValue(config.apiVersion, forHTTPHeaderField: "anthropic-version")
        do {
            ur.httpBody = try Self.encoder.encode(batch)
        } catch {
            throw AnthropicAPIError.invalidRequest(
                message: "batch encoding failed: \(error)"
            )
        }
        let (data, response) = try await sendRaw(ur)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicAPIError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapErrorResponse(status: http.statusCode, headers: http, body: data)
        }
        do {
            return try Self.decoder.decode(
                AnthropicBatchSubmitResponse.self, from: data
            )
        } catch {
            throw AnthropicAPIError.decode(String(describing: error))
        }
    }

    // MARK: - Status

    public func status(
        batchId: String
    ) async throws -> AnthropicBatchStatusResponse {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw AnthropicAPIError.missingAPIKey
        }
        var url = config.baseURL
        url.append(path: "v1/messages/batches/\(batchId)")
        var ur = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        ur.httpMethod = "GET"
        ur.addValue(key, forHTTPHeaderField: "x-api-key")
        ur.addValue(config.apiVersion, forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await sendRaw(ur)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicAPIError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapErrorResponse(status: http.statusCode, headers: http, body: data)
        }
        do {
            return try Self.decoder.decode(
                AnthropicBatchStatusResponse.self, from: data
            )
        } catch {
            throw AnthropicAPIError.decode(String(describing: error))
        }
    }

    /// Poll until the batch reaches `.ended` (or `.canceling` →
    /// `.ended`). Throws on poll timeout or transport error.
    /// Returns the final status (which carries `resultsUrl`).
    public func awaitCompletion(
        batchId: String
    ) async throws -> AnthropicBatchStatusResponse {
        let start = Date()
        while true {
            try Task.checkCancellation()
            let s = try await status(batchId: batchId)
            if s.processingStatus == .ended { return s }
            if Date().timeIntervalSince(start) >= config.pollTimeout {
                throw AnthropicAPIError.serverError(
                    status: -1,
                    message: "batch \(batchId) did not complete within \(config.pollTimeout)s"
                )
            }
            try await sleep(config.pollInterval)
        }
    }

    // MARK: - Results

    /// Fetch the JSONL result stream and decode each line into a
    /// `BatchResultLine`. The `resultsUrl` is opaque per the
    /// Anthropic docs — we treat it as a fully-qualified URL the
    /// server gives us. Same auth headers as the other endpoints.
    public func fetchResults(
        from resultsUrl: String
    ) async throws -> [AnthropicBatchResultLine] {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw AnthropicAPIError.missingAPIKey
        }
        guard let url = URL(string: resultsUrl) else {
            throw AnthropicAPIError.decode("invalid results_url")
        }
        var ur = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        ur.httpMethod = "GET"
        ur.addValue(key, forHTTPHeaderField: "x-api-key")
        ur.addValue(config.apiVersion, forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await sendRaw(ur)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicAPIError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapErrorResponse(status: http.statusCode, headers: http, body: data)
        }
        // JSONL: one JSON object per line. Decode each
        // independently so a single corrupt line doesn't fail
        // the whole batch.
        let text = String(data: data, encoding: .utf8) ?? ""
        var out: [AnthropicBatchResultLine] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let entry = try? Self.decoder.decode(
                AnthropicBatchResultLine.self, from: lineData
            ) {
                out.append(entry)
            }
        }
        return out
    }

    // MARK: - private

    private func sendRaw(_ ur: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await transport.send(ur)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AnthropicAPIError.network(error)
        }
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        if let sleeper {
            try await sleeper(seconds)
        } else {
            try await Task.sleep(
                nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
            )
        }
    }

    private func mapErrorResponse(
        status: Int, headers: HTTPURLResponse, body: Data
    ) -> AnthropicAPIError {
        let envelope = try? Self.decoder.decode(
            AnthropicErrorEnvelope.self, from: body
        )
        let message = envelope?.error.message
            ?? String(data: body, encoding: .utf8)
            ?? ""
        switch status {
        case 400: return .invalidRequest(message: message)
        case 401: return .authenticationFailed
        case 403: return .permissionDenied(message: message)
        case 404: return .notFound(message: message)
        case 413: return .requestTooLarge
        case 429:
            let retryAfter = headers.value(forHTTPHeaderField: "retry-after")
                .flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        case 529: return .overloaded
        default:
            return .serverError(
                status: status,
                message: message.isEmpty ? nil : message
            )
        }
    }

    nonisolated static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    nonisolated static let decoder: JSONDecoder = JSONDecoder()
}
