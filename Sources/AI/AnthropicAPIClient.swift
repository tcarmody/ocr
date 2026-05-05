import Foundation

/// Synchronous Messages API client.
///
/// One request in, one response out. Handles auth-header injection,
/// retry-with-backoff for transient failures, and HTTP-status →
/// typed-error mapping. Knows nothing about Document / OCR / Pipeline
/// types — request and response are pure JSON-shaped data.
///
/// ## Future batch path
/// A bulk-mode runner (the `R-Bulk-Editor` work in `PLANS.md` Tier 5)
/// will sit alongside this type, taking `[AnthropicMessageRequest]`
/// and yielding `[AnthropicMessageResponse]` against
/// `/v1/messages/batches` for a 50% cost reduction. Both clients
/// reuse the request and response structs and the transport
/// protocol unchanged — only the URL path, body shape, and
/// poll/result handling differ.
public actor AnthropicAPIClient {

    /// Connection-level configuration. Defaults match Anthropic's
    /// recommended posture (current API version, sane retry policy,
    /// 120s per-request timeout that leaves room for the model to
    /// produce ≤16K tokens without hitting the SDK's HTTP timeout
    /// guard).
    public struct Config: Sendable {
        public var baseURL: URL
        public var apiVersion: String
        public var maxRetries: Int
        public var initialBackoff: TimeInterval
        public var maxBackoff: TimeInterval
        public var requestTimeout: TimeInterval
        /// Optional beta-feature opt-ins (`anthropic-beta` header).
        /// Empty for Phase 1 — vision, prompt caching, and
        /// `output_config.format` are all GA.
        public var betaHeaders: [String]

        public init(
            baseURL: URL = URL(string: "https://api.anthropic.com")!,
            apiVersion: String = "2023-06-01",
            maxRetries: Int = 3,
            initialBackoff: TimeInterval = 1.0,
            maxBackoff: TimeInterval = 30.0,
            requestTimeout: TimeInterval = 120.0,
            betaHeaders: [String] = []
        ) {
            self.baseURL = baseURL
            self.apiVersion = apiVersion
            self.maxRetries = maxRetries
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
            self.requestTimeout = requestTimeout
            self.betaHeaders = betaHeaders
        }

        public static let `default` = Config()
    }

    public let config: Config
    private let transport: any AnthropicTransport
    private let apiKeyProvider: @Sendable () -> String?
    /// Test seam — when non-nil, replaces `Task.sleep` with a mock
    /// so retry-backoff tests don't actually wait. Production code
    /// uses `Task.sleep(nanoseconds:)`.
    private let sleeper: (@Sendable (TimeInterval) async throws -> Void)?

    /// Build a client with an explicit API key provider. The provider
    /// closure is invoked for every request — passing a closure
    /// (rather than a captured string) lets the keychain-backed
    /// store rotate keys without rebuilding the client.
    public init(
        config: Config = .default,
        transport: any AnthropicTransport = URLSessionTransport(),
        apiKeyProvider: @escaping @Sendable () -> String?,
        sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) {
        self.config = config
        self.transport = transport
        self.apiKeyProvider = apiKeyProvider
        self.sleeper = sleeper
    }

    // MARK: - Send

    /// Submit one Messages API request. Retries transient failures
    /// (429 / 5xx / network) with exponential backoff up to
    /// `config.maxRetries`. Throws the last error (typed
    /// `AnthropicAPIError`) when retries are exhausted or the error
    /// is non-retryable.
    public func send(_ request: AnthropicMessageRequest) async throws -> AnthropicMessageResponse {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw AnthropicAPIError.missingAPIKey
        }
        let urlRequest = try buildURLRequest(for: request, apiKey: key)

        var attempt = 0
        var lastError: AnthropicAPIError?
        while attempt <= config.maxRetries {
            try Task.checkCancellation()
            do {
                return try await sendOnce(urlRequest)
            } catch let error as AnthropicAPIError {
                lastError = error
                guard error.isRetryable, attempt < config.maxRetries else {
                    throw error
                }
                let delay = backoffDelay(forAttempt: attempt, error: error)
                try await sleep(delay)
                attempt += 1
            }
        }
        // Loop exit only happens via throw above; this is a guard
        // for future refactors that change the loop structure.
        throw lastError ?? .serverError(status: -1, message: "retry loop exhausted")
    }

    // MARK: - Single attempt

    private func sendOnce(_ urlRequest: URLRequest) async throws -> AnthropicMessageResponse {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AnthropicAPIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicAPIError.decode("non-HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            do {
                return try Self.decoder.decode(AnthropicMessageResponse.self, from: data)
            } catch {
                throw AnthropicAPIError.decode(String(describing: error))
            }
        default:
            throw mapErrorResponse(status: http.statusCode, headers: http, body: data)
        }
    }

    // MARK: - Error mapping

    private func mapErrorResponse(
        status: Int, headers: HTTPURLResponse, body: Data
    ) -> AnthropicAPIError {
        // Body is best-effort: success returns 200 / 4xx / 5xx all
        // come from JSON envelopes, but a misbehaving proxy could
        // strip it. Fall back to a generic message in that case.
        let envelope = try? Self.decoder.decode(AnthropicErrorEnvelope.self, from: body)
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
            return .serverError(status: status, message: message.isEmpty ? nil : message)
        }
    }

    // MARK: - URLRequest builder

    private func buildURLRequest(
        for request: AnthropicMessageRequest, apiKey: String
    ) throws -> URLRequest {
        var url = config.baseURL
        url.append(path: "v1/messages")
        var ur = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        ur.httpMethod = "POST"
        ur.addValue("application/json", forHTTPHeaderField: "Content-Type")
        ur.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        ur.addValue(config.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !config.betaHeaders.isEmpty {
            ur.addValue(
                config.betaHeaders.joined(separator: ","),
                forHTTPHeaderField: "anthropic-beta"
            )
        }
        do {
            ur.httpBody = try Self.encoder.encode(request)
        } catch {
            throw AnthropicAPIError.invalidRequest(
                message: "request encoding failed: \(error)"
            )
        }
        return ur
    }

    // MARK: - Backoff + sleep

    /// Exponential backoff with `retry-after` override. `attempt` is
    /// zero-based: attempt 0 waits `initialBackoff`, attempt 1 waits
    /// `2 × initialBackoff`, etc., capped at `maxBackoff`.
    nonisolated private func backoffDelay(
        forAttempt attempt: Int, error: AnthropicAPIError
    ) -> TimeInterval {
        if case .rateLimited(let retryAfter?) = error {
            return min(retryAfter, config.maxBackoff)
        }
        let exponential = config.initialBackoff * pow(2.0, Double(attempt))
        return min(exponential, config.maxBackoff)
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        if let sleeper {
            try await sleeper(seconds)
        } else {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    }

    // MARK: - Encoder / decoder

    nonisolated static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Sort keys so request bodies are byte-stable across
        // identical inputs — directly relevant to prompt-cache hit
        // rates: any byte change in the prefix invalidates the
        // cache, and key-order drift is the most common silent
        // invalidator.
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    nonisolated static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
