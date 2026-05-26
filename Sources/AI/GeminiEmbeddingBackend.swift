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

    /// `batchEmbedContents` server-side limit on items per request.
    /// Gemini documents 100; sending more returns 400 Bad Request
    /// ("at most 100 instances allowed per request"). Long books
    /// routinely cross this — a 1500-paragraph book without
    /// client-side chunking would hit a single request with 15×
    /// the documented cap and fail outright.
    private static let maxItemsPerRequest: Int = 100

    /// Per-item input cap. Gemini's embedding models accept up to
    /// 2048 tokens per instance; over the cap returns 400 for the
    /// whole batch. Our paragraph extractor produces mostly short
    /// items (median ~300 chars), but the occasional huge
    /// blockquote / pre-formatted section can blow past the limit.
    /// Truncate at 7500 chars (≈ 1875 tokens at 4 chars/token,
    /// conservative buffer under the 2048 cap) before submission.
    private static let maxCharsPerItem: Int = 7500

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

        // Truncate any over-length items before chunking. The
        // truncation is per-item; chunking is per-batch. Both
        // safety nets are needed: a single 50K-char paragraph
        // would 400-out the whole batch even if the batch only
        // had 10 items.
        let truncated = texts.map { text -> String in
            text.count > Self.maxCharsPerItem
                ? String(text.prefix(Self.maxCharsPerItem))
                : text
        }

        // Split into chunks of ≤ maxItemsPerRequest. Each chunk
        // goes through the existing throttled-send path, which
        // handles RPM/TPM rate-limiting + 429 retry across the
        // whole sequence — the shared rate limiter ensures we
        // don't burst over Google's per-minute budget even when
        // a long book splits into 15+ sequential sub-batches.
        // Sequential rather than concurrent because the rate
        // limiter would just queue concurrent calls anyway, and
        // sequential makes failure semantics + ordering simpler.
        var allEmbeddings: [[Float]] = []
        allEmbeddings.reserveCapacity(truncated.count)
        for chunk in truncated.chunked(into: Self.maxItemsPerRequest) {
            let chunkEmbeddings = try await embedOneChunk(chunk, apiKey: key)
            allEmbeddings.append(contentsOf: chunkEmbeddings)
        }
        return allEmbeddings
    }

    /// Send one ≤ `maxItemsPerRequest`-sized chunk through
    /// `batchEmbedContents`. Same shape as the v1 `embed(_:)` but
    /// without the input-size check (caller already chunked).
    private func embedOneChunk(
        _ texts: [String], apiKey: String
    ) async throws -> [[Float]] {
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
        request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try Self.encoder.encode(body)

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
            // Prefer the structured retryDelay from the response
            // body (Google returns it under
            // `error.details[?@type=="…RetryInfo"].retryDelay` as
            // a duration string like "16s" or "16.12s"). Falls back
            // to the regex match of "Please retry in Xs" in the
            // message field, and finally to the HTTP header.
            let retryAfter = Self.retryAfterSecondsFromBody(data: data)
                ?? Self.retryAfterSeconds(from: http)
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

    /// Parse Google's structured retry hint from the 429 response
    /// body. Two paths:
    ///   1. `error.details[?@type=="…RetryInfo"].retryDelay`
    ///      (the canonical `google.rpc.RetryInfo` shape; duration
    ///      string like `"16s"` or `"16.120805818s"`).
    ///   2. Regex-match `"Please retry in 16.12s"` from
    ///      `error.message` as a fallback for cases where the
    ///      RetryInfo detail is missing.
    /// Returns nil when neither path yields a parseable duration.
    static func retryAfterSecondsFromBody(data: Data) -> Double? {
        guard let json = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              let error = json["error"] as? [String: Any]
        else { return nil }
        // Structured RetryInfo detail.
        if let details = error["details"] as? [[String: Any]] {
            for detail in details {
                let type = detail["@type"] as? String ?? ""
                guard type.contains("RetryInfo"),
                      let delay = detail["retryDelay"] as? String
                else { continue }
                if let seconds = parseDurationString(delay) {
                    return seconds
                }
            }
        }
        // Message-string fallback. Google's message phrasing is
        // stable enough across the embedding endpoints to make a
        // regex match safe; if they change the wording, the
        // structured detail above is still the primary path.
        if let message = error["message"] as? String,
           let range = message.range(
               of: #"retry in (\d+(?:\.\d+)?)s"#,
               options: .regularExpression
           ) {
            let match = String(message[range])
            let numericPart = match
                .replacingOccurrences(of: "retry in ", with: "")
                .replacingOccurrences(of: "s", with: "")
            if let seconds = Double(numericPart), seconds >= 0 {
                return seconds
            }
        }
        return nil
    }

    /// Parse a protobuf-style duration string (`"16s"`,
    /// `"16.120805818s"`) into a seconds Double. Returns nil for
    /// any other shape — e.g. `"1m"` or `"500ms"` — since the
    /// embedding API only returns plain-seconds durations.
    static func parseDurationString(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("s") else { return nil }
        let body = String(trimmed.dropLast())
        guard let seconds = Double(body), seconds >= 0 else { return nil }
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

private extension Array {
    /// Slice into contiguous sub-arrays of length ≤ `size`. Final
    /// slice may be shorter. Used by `GeminiEmbeddingBackend.embed`
    /// to partition large paragraph counts under the 100-items-
    /// per-request server limit.
    func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0, "chunk size must be positive")
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
