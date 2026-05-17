import Foundation

/// HTTP embedding backend backed by Google's Gemini Embedding API.
/// Currently the highest-ranked multilingual embedder on the MTEB
/// leaderboard — best-fit for academic libraries with classical
/// Greek, Latin, Hebrew, or other non-English scholarly content.
///
/// Default model is `gemini-embedding-002`, with the standard 3072-
/// dim Matryoshka output. Users on a tight storage budget can pick
/// a smaller `outputDimensionality` (768, 1536) — the Matryoshka
/// representation guarantees the smaller vector is still a useful
/// embedding (just truncated; not a separate model).
///
/// Authentication is via `?key=<api_key>` query parameter, the
/// standard Google AI Studio pattern. The key is read fresh per
/// call so a key rotation doesn't require rebuilding the client.
public actor GeminiEmbeddingBackend: EmbeddingBackend {
    public let identifier: String
    public let dimension: Int
    public let model: String
    public let outputDimensionality: Int?
    private let keyStore: GeminiAPIKeyStore
    private let baseURL: URL
    private let requestTimeout: TimeInterval
    /// Target requests-per-minute ceiling. Tier 1 paid Gemini caps
    /// at 3000 RPM; defaulting to 2500 leaves ~17% headroom for
    /// jitter, clock skew, and any sibling processes that share the
    /// key. The actor's serialization makes this a global pace for
    /// every call through this backend instance.
    private let maxRequestsPerMinute: Int
    /// Retry budget when the server still returns 429 despite our
    /// throttling — usually means a concurrent process on the same
    /// API key, or a brief tier-cap glitch. Three attempts with
    /// `Retry-After` / exponential backoff covers nearly every
    /// real-world case without spamming on a wedge.
    private let maxRetriesOn429: Int
    /// Monotonic timestamp of the most recent request fired. Used
    /// to enforce `minimumInterval` between consecutive calls.
    /// Nil before the first request lands.
    private var lastRequestAt: ContinuousClock.Instant?

    /// Minimum wall-time between consecutive requests, derived
    /// from `maxRequestsPerMinute`. At 2500 RPM that's 24 ms.
    private var minimumInterval: Duration {
        .nanoseconds(Int64(60_000_000_000 / Int64(max(1, maxRequestsPerMinute))))
    }

    /// Build a backend by probing the API to learn the output
    /// dimension. Throws `EmbeddingError.missingAPIKey` when no key
    /// is configured.
    ///
    /// Default model is `gemini-embedding-2` — Google's first
    /// multimodal embedding model, GA on the Generative Language
    /// API. The older text-only `gemini-embedding-001` is still
    /// available for users who prefer it. Note the digit-only
    /// `-2` suffix (no `00` prefix); `gemini-embedding-002` is
    /// not a published model id and returns 404.
    public static func make(
        model: String = "gemini-embedding-2",
        outputDimensionality: Int? = nil,
        keyStore: GeminiAPIKeyStore = GeminiAPIKeyStore(),
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
        requestTimeout: TimeInterval = 60,
        maxRequestsPerMinute: Int = 2500,
        maxRetriesOn429: Int = 3
    ) async throws -> GeminiEmbeddingBackend {
        guard keyStore.hasKey else {
            throw EmbeddingError.missingAPIKey(provider: "Google AI Studio (Gemini)")
        }
        let backend = GeminiEmbeddingBackend(
            identifier: "gemini.\(model).\(outputDimensionality ?? 0)",
            dimension: outputDimensionality ?? 0,
            model: model,
            outputDimensionality: outputDimensionality,
            keyStore: keyStore,
            baseURL: baseURL,
            requestTimeout: requestTimeout,
            maxRequestsPerMinute: maxRequestsPerMinute,
            maxRetriesOn429: maxRetriesOn429
        )
        let probe = try await backend.embed(["x"])
        guard let firstVector = probe.first, !firstVector.isEmpty else {
            throw EmbeddingError.decode(
                "Gemini returned empty embeddings for the dimension probe"
            )
        }
        return GeminiEmbeddingBackend(
            identifier: "gemini.\(model).\(firstVector.count)",
            dimension: firstVector.count,
            model: model,
            outputDimensionality: outputDimensionality,
            keyStore: keyStore,
            baseURL: baseURL,
            requestTimeout: requestTimeout,
            maxRequestsPerMinute: maxRequestsPerMinute,
            maxRetriesOn429: maxRetriesOn429
        )
    }

    private init(
        identifier: String,
        dimension: Int,
        model: String,
        outputDimensionality: Int?,
        keyStore: GeminiAPIKeyStore,
        baseURL: URL,
        requestTimeout: TimeInterval,
        maxRequestsPerMinute: Int,
        maxRetriesOn429: Int
    ) {
        self.identifier = identifier
        self.dimension = dimension
        self.model = model
        self.outputDimensionality = outputDimensionality
        self.keyStore = keyStore
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
        self.maxRequestsPerMinute = max(1, maxRequestsPerMinute)
        self.maxRetriesOn429 = max(0, maxRetriesOn429)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let key = keyStore.read() else {
            throw EmbeddingError.missingAPIKey(provider: "Google AI Studio (Gemini)")
        }
        let path = "/v1beta/models/\(model):batchEmbedContents"
        let url = baseURL.appendingPathComponent(path)

        let body = RequestBody(
            requests: texts.map { text in
                RequestEntry(
                    model: "models/\(model)",
                    content: ContentEnvelope(
                        parts: [ContentPart(text: text)]
                    ),
                    taskType: "RETRIEVAL_DOCUMENT",
                    outputDimensionality: outputDimensionality
                )
            }
        )

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        // Google's docs prefer the `x-goog-api-key` header over
        // the `?key=` query param — same auth, but the key isn't
        // logged in URL-level traces.
        request.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try Self.encoder.encode(body)

        let (data, http) = try await sendThrottled(request: request)
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw EmbeddingError.serverError(
                status: http.statusCode,
                message: message?.isEmpty == false ? message : nil
            )
        }
        do {
            let envelope = try Self.decoder.decode(ResponseBody.self, from: data)
            // Gemini returns embeddings in input order — no `index`
            // field to sort by. Trust the order.
            for entry in envelope.embeddings where dimension > 0 && entry.values.count != dimension {
                throw EmbeddingError.dimensionMismatch(
                    expected: dimension, got: entry.values.count
                )
            }
            return envelope.embeddings.map { $0.values.map(Float.init) }
        } catch let error as EmbeddingError {
            throw error
        } catch {
            throw EmbeddingError.decode(String(describing: error))
        }
    }

    // MARK: - Throttle + 429 retry

    /// Send `request` while honoring our per-minute rate cap and
    /// retrying on 429 with the server's `Retry-After` hint
    /// (falls back to exponential backoff: 1s, 2s, 4s). Retries
    /// also re-throttle between attempts so a quick burst can't
    /// blow the cap. Throws the final failure if every attempt
    /// still returns 429.
    private func sendThrottled(
        request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try await waitForSlot()
            lastRequestAt = ContinuousClock.now

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw EmbeddingError.network(error)
            }
            guard let http = response as? HTTPURLResponse else {
                throw EmbeddingError.decode("non-HTTP response")
            }

            // Non-429: hand back to the caller. Success or any
            // other server error path that's not retryable here.
            if http.statusCode != 429 {
                return (data, http)
            }

            // 429: honor `Retry-After` if present (Google returns
            // seconds as an integer or HTTP-date; we only parse
            // integer seconds — date form is rare for this API).
            // Otherwise fall back to exponential backoff.
            if attempt >= maxRetriesOn429 {
                let message = String(data: data, encoding: .utf8)
                throw EmbeddingError.serverError(
                    status: 429,
                    message: message?.isEmpty == false ? message : nil
                )
            }
            let backoff = Self.retryAfterSeconds(from: http)
                ?? Self.exponentialBackoffSeconds(attempt: attempt)
            try await Task.sleep(for: .seconds(backoff))
            attempt += 1
        }
    }

    /// Sleep until at least `minimumInterval` has elapsed since
    /// the most recent request. No-op on the first call. Uses
    /// ContinuousClock so wall-clock changes can't skew the gap.
    private func waitForSlot() async throws {
        guard let last = lastRequestAt else { return }
        let now = ContinuousClock.now
        let elapsed = last.duration(to: now)
        if elapsed < minimumInterval {
            try await Task.sleep(for: minimumInterval - elapsed)
        }
    }

    /// Parse the `Retry-After` HTTP header as integer seconds.
    /// Returns nil when the header is absent or non-numeric (we
    /// don't bother with HTTP-date form — Google's API doesn't
    /// use it here in practice).
    private static func retryAfterSeconds(
        from response: HTTPURLResponse
    ) -> Double? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(raw.trimmingCharacters(in: .whitespaces)),
              seconds >= 0 else {
            return nil
        }
        return seconds
    }

    /// Exponential backoff: 1s, 2s, 4s, 8s, … capped at 30s. Used
    /// only when the 429 response doesn't include a `Retry-After`
    /// header, which is uncommon but worth handling defensively.
    private static func exponentialBackoffSeconds(attempt: Int) -> Double {
        let base = pow(2.0, Double(attempt))
        return min(base, 30)
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        let requests: [RequestEntry]
    }

    private struct RequestEntry: Encodable {
        let model: String
        let content: ContentEnvelope
        let taskType: String
        let outputDimensionality: Int?

        // Google's Generative Language API uses camelCase JSON
        // keys (taskType / outputDimensionality), not snake_case.
        // The legacy `embedding-001` endpoint accepted both, but
        // `gemini-embedding-001` only accepts the camelCase form.
        enum CodingKeys: String, CodingKey {
            case model, content, taskType, outputDimensionality
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model, forKey: .model)
            try c.encode(content, forKey: .content)
            try c.encode(taskType, forKey: .taskType)
            // Only emit `outputDimensionality` when set — Gemini
            // returns the model's native dimension when absent.
            if let dim = outputDimensionality {
                try c.encode(dim, forKey: .outputDimensionality)
            }
        }
    }

    private struct ContentEnvelope: Encodable {
        let parts: [ContentPart]
    }

    private struct ContentPart: Encodable {
        let text: String
    }

    private struct ResponseBody: Decodable {
        struct Embedding: Decodable {
            let values: [Double]
        }
        let embeddings: [Embedding]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
