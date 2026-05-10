import Foundation

/// HTTP embedding backend backed by Voyage AI's REST API. Voyage is
/// Anthropic's recommended embedding provider; competitive with the
/// best closed-source models on technical / academic English at a
/// fraction of the cost (~$0.02 per 1M tokens, ~$0.005 per book).
///
/// Default model is `voyage-3` (1024-dim, strong general-purpose).
/// Users with cost sensitivity can pick `voyage-3-lite` (512-dim,
/// ~half the price) via Settings.
///
/// Authentication is a single `Authorization: Bearer <key>` header;
/// the key is read fresh per call from the keychain so the client
/// doesn't outlast a key rotation.
public actor VoyageEmbeddingBackend: EmbeddingBackend {
    public let identifier: String
    public let dimension: Int
    public let model: String
    private let keyStore: VoyageAPIKeyStore
    private let baseURL: URL
    private let requestTimeout: TimeInterval

    /// Build a backend by probing the API to learn the dimension.
    /// Throws `EmbeddingError.missingAPIKey` when no key is
    /// configured, and surfaces the upstream HTTP error otherwise.
    public static func make(
        model: String = "voyage-3",
        keyStore: VoyageAPIKeyStore = VoyageAPIKeyStore(),
        baseURL: URL = URL(string: "https://api.voyageai.com")!,
        requestTimeout: TimeInterval = 60
    ) async throws -> VoyageEmbeddingBackend {
        guard keyStore.hasKey else {
            throw EmbeddingError.missingAPIKey(provider: "Voyage")
        }
        let backend = VoyageEmbeddingBackend(
            identifier: "voyage.\(model)",
            dimension: 0,
            model: model,
            keyStore: keyStore,
            baseURL: baseURL,
            requestTimeout: requestTimeout
        )
        // Probe with a single short string. The dimension comes
        // back in the embedding length; we re-create the backend
        // with the discovered dimension.
        let probe = try await backend.embed(["x"])
        guard let firstVector = probe.first, !firstVector.isEmpty else {
            throw EmbeddingError.decode(
                "Voyage returned empty embeddings for the dimension probe"
            )
        }
        return VoyageEmbeddingBackend(
            identifier: "voyage.\(model)",
            dimension: firstVector.count,
            model: model,
            keyStore: keyStore,
            baseURL: baseURL,
            requestTimeout: requestTimeout
        )
    }

    private init(
        identifier: String,
        dimension: Int,
        model: String,
        keyStore: VoyageAPIKeyStore,
        baseURL: URL,
        requestTimeout: TimeInterval
    ) {
        self.identifier = identifier
        self.dimension = dimension
        self.model = model
        self.keyStore = keyStore
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let key = keyStore.read() else {
            throw EmbeddingError.missingAPIKey(provider: "Voyage")
        }
        let body = RequestBody(input: texts, model: model, inputType: "document")
        let url = baseURL.appendingPathComponent("v1/embeddings")
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
            // Voyage returns results in a `data` array indexed by
            // `index`; sort by index to match input order.
            let sorted = envelope.data.sorted(by: { $0.index < $1.index })
            // Defend against an unexpected dimension after the probe
            // ran — would corrupt the sidecar silently otherwise.
            for entry in sorted where dimension > 0 && entry.embedding.count != dimension {
                throw EmbeddingError.dimensionMismatch(
                    expected: dimension, got: entry.embedding.count
                )
            }
            return sorted.map { $0.embedding.map(Float.init) }
        } catch let error as EmbeddingError {
            throw error
        } catch {
            throw EmbeddingError.decode(String(describing: error))
        }
    }

    // MARK: - Wire types

    /// Voyage's `/v1/embeddings` request shape. `input_type` is
    /// "document" for the corpus pass and "query" for one-shot
    /// query embeddings; for v1 we send "document" for both since
    /// the quality difference is small and the chat path doesn't
    /// distinguish.
    private struct RequestBody: Encodable {
        let input: [String]
        let model: String
        let inputType: String

        enum CodingKeys: String, CodingKey {
            case input
            case model
            case inputType = "input_type"
        }
    }

    private struct ResponseBody: Decodable {
        struct Item: Decodable {
            let embedding: [Double]
            let index: Int
        }
        let data: [Item]
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
