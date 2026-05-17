import Foundation
import os

/// Logger for the embedding backend's rate-limit diagnostics. Every
/// 429 gets a structured line including the response body so the
/// specific Google quota that fired is captured in Console.app
/// without needing a debugger attached. Subsystem matches the rest
/// of the project so a single Console filter sees everything.
private let geminiEmbedLog = Logger(
    subsystem: "com.tcarmody.Humanist",
    category: "GeminiEmbeddingBackend"
)

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
    /// Retry budget when the server still returns 429 despite the
    /// shared rate limiter — usually means a transient quota
    /// fluctuation or a sibling process sharing the API project.
    /// Three attempts with `Retry-After` / exponential backoff
    /// covers nearly every real-world case without spamming on a
    /// wedge.
    private let maxRetriesOn429: Int

    /// Rough English token-density estimate. The Gemini tokenizer
    /// isn't exposed locally; we use 4 chars/token as a stand-in.
    /// Over-estimates for code-heavy or whitespace-padded text,
    /// under-estimates for some non-Latin scripts — fine for
    /// budget gating (we'd rather under-pace than over-pace).
    private static let charsPerTokenEstimate: Int = 4

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
        maxTokensPerMinute: Int = 800_000,
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
            maxTokensPerMinute: maxTokensPerMinute,
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
            maxTokensPerMinute: maxTokensPerMinute,
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
        maxTokensPerMinute: Int,
        maxRetriesOn429: Int
    ) {
        self.identifier = identifier
        self.dimension = dimension
        self.model = model
        self.outputDimensionality = outputDimensionality
        self.keyStore = keyStore
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
        self.maxRetriesOn429 = max(0, maxRetriesOn429)
        // Forward RPM/TPM caps to the process-wide rate limiter so
        // every backend instance respects the same global budget.
        // Last writer wins; in normal use all callers pass the
        // same defaults so the call is idempotent.
        Task {
            await GeminiEmbeddingRateLimiter.shared.configure(
                maxRequestsPerMinute: maxRequestsPerMinute,
                maxTokensPerMinute: maxTokensPerMinute
            )
        }
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

        // Estimate input tokens for the TPM gate. Sum of all input
        // text divided by `charsPerTokenEstimate`. Floors at 1 so a
        // microscopic input still counts against the budget.
        let estimatedTokens = max(1, texts.reduce(0) {
            $0 + ($1.count / Self.charsPerTokenEstimate)
        })
        let (data, http) = try await sendThrottled(
            request: request, estimatedTokens: estimatedTokens
        )
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

    /// Send `request` while honoring both rate caps (RPM + TPM)
    /// and retrying on 429 with the server's `Retry-After` hint
    /// (falls back to exponential backoff: 1s, 2s, 4s). Retries
    /// also re-throttle between attempts so a quick burst can't
    /// blow the cap. Throws the final failure if every attempt
    /// still returns 429. `estimatedTokens` is the expected input
    /// token count for this request (charged against the TPM
    /// sliding window before firing and recorded after firing).
    private func sendThrottled(
        request: URLRequest, estimatedTokens: Int
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try await GeminiEmbeddingRateLimiter.shared.acquireSlot(
                estimatedTokens: estimatedTokens
            )

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

            // Non-429: record this request in the token window so
            // future calls (from any backend instance) account for
            // the spend. Then hand back to the caller.
            if http.statusCode != 429 {
                await GeminiEmbeddingRateLimiter.shared.recordSuccess(
                    tokens: estimatedTokens
                )
                return (data, http)
            }

            // 429: honor `Retry-After` if present (Google returns
            // seconds as an integer or HTTP-date; we only parse
            // integer seconds — date form is rare for this API).
            // Otherwise fall back to exponential backoff. Don't
            // record this attempt in the token window — the server
            // rejected it, so the tokens didn't count against the
            // user's actual budget either.
            let body = String(data: data, encoding: .utf8) ?? "(non-UTF8 body)"
            let retryAfter = Self.retryAfterSeconds(from: http)
            // Diagnostic: every 429 logs the full response body so
            // the specific Google quota dimension that fired
            // (`quotaMetric`, `quotaId`, `quotaDimensions`) is
            // captured for triage. `privacy: .public` on each
            // interpolation — without it macOS Logger redacts
            // string values as `<private>` in Console.app and we
            // lose exactly the information we wanted. The body is
            // Google's error JSON, no secrets; the retry-after
            // value is a duration string; both are safe to log.
            let retryAfterDescription = retryAfter
                .map { String(format: "%.1fs", $0) } ?? "absent"
            geminiEmbedLog.warning(
                """
                429 from Gemini embedding API \
                (attempt \(attempt + 1)/\(self.maxRetriesOn429 + 1), \
                estimated tokens=\(estimatedTokens), \
                retry-after=\(retryAfterDescription, privacy: .public)). \
                Response body: \(body, privacy: .public)
                """
            )
            if attempt >= maxRetriesOn429 {
                throw EmbeddingError.serverError(
                    status: 429,
                    message: body.isEmpty ? nil : body
                )
            }
            let backoff = retryAfter
                ?? Self.exponentialBackoffSeconds(attempt: attempt)
            try await Task.sleep(for: .seconds(backoff))
            attempt += 1
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
