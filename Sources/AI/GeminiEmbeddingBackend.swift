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

    /// Build a backend by probing the API to learn the output
    /// dimension. Throws `EmbeddingError.missingAPIKey` when no key
    /// is configured.
    public static func make(
        model: String = "gemini-embedding-002",
        outputDimensionality: Int? = nil,
        keyStore: GeminiAPIKeyStore = GeminiAPIKeyStore(),
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
        requestTimeout: TimeInterval = 60
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
            requestTimeout: requestTimeout
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
            requestTimeout: requestTimeout
        )
    }

    private init(
        identifier: String,
        dimension: Int,
        model: String,
        outputDimensionality: Int?,
        keyStore: GeminiAPIKeyStore,
        baseURL: URL,
        requestTimeout: TimeInterval
    ) {
        self.identifier = identifier
        self.dimension = dimension
        self.model = model
        self.outputDimensionality = outputDimensionality
        self.keyStore = keyStore
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let key = keyStore.read() else {
            throw EmbeddingError.missingAPIKey(provider: "Google AI Studio (Gemini)")
        }
        let path = "/v1beta/models/\(model):batchEmbedContents"
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "key", value: key)]

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

        var request = URLRequest(url: components.url!, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)

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

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        let requests: [RequestEntry]
    }

    private struct RequestEntry: Encodable {
        let model: String
        let content: ContentEnvelope
        let taskType: String
        let outputDimensionality: Int?

        enum CodingKeys: String, CodingKey {
            case model, content
            case taskType = "task_type"
            case outputDimensionality = "output_dimensionality"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model, forKey: .model)
            try c.encode(content, forKey: .content)
            try c.encode(taskType, forKey: .taskType)
            // Only emit `output_dimensionality` when set — Gemini
            // returns the model's full default (3072 for
            // gemini-embedding-002) when absent.
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
