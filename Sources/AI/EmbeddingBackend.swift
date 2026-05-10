import Foundation
import NaturalLanguage

/// Backends that turn text into a fixed-dimension vector. Used by the
/// chat-with-book retriever to find conceptually similar paragraphs
/// even when the user's query doesn't share keywords with the source.
///
/// One protocol covers four implementations: Apple's on-device
/// `NLEmbedding` (default; free; no network), an Ollama embedding
/// endpoint, Voyage AI, and Gemini Embedding 2. Each one has a
/// stable `identifier` and `dimension` recorded in the per-book
/// embedding sidecar — a backend or dimension change forces a full
/// re-embed because the vector spaces aren't comparable.
public protocol EmbeddingBackend: Sendable {
    /// Stable identifier for this backend's vector space. Stored in
    /// the sidecar; mismatch → full rebuild. Recommended format:
    /// `<vendor>.<family>.<model>` (e.g. `apple.nl.sentence.en`,
    /// `ollama.nomic-embed-text`, `voyage.voyage-3-lite`,
    /// `gemini.embedding-002`).
    var identifier: String { get }
    /// Embedding dimension. Stored in the sidecar; mismatch → full
    /// rebuild.
    var dimension: Int { get }
    /// Embed a batch of texts. Order of results matches order of
    /// inputs. Empty input → empty output. Caller is responsible
    /// for batching to amortize per-call overhead — Voyage / Gemini
    /// support up to ~100 inputs per call; NLEmbedding is loop-per-
    /// text but accepts the same protocol.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// Errors surfaced by an `EmbeddingBackend`. Callers map to a banner
/// message in the chat pane.
public enum EmbeddingError: Error, LocalizedError {
    /// The backend's runtime dependency isn't available
    /// (e.g. `NLEmbedding.sentenceEmbedding(for: .english)` returned
    /// nil because the on-device model isn't installed).
    case backendUnavailable(String)
    /// The backend returned a vector of unexpected dimension.
    case dimensionMismatch(expected: Int, got: Int)
    /// A required API key isn't configured. Surfaces a Settings
    /// prompt rather than a generic network error.
    case missingAPIKey(provider: String)
    /// HTTP-level transport failure (timeout, connection lost, etc.).
    case network(Error)
    /// Provider returned non-2xx with an explanatory body.
    case serverError(status: Int, message: String?)
    /// Decoder couldn't parse the response body. Shouldn't happen in
    /// production; signals a contract change in the upstream API.
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable(let detail):
            return "Embedding backend unavailable: \(detail)"
        case .dimensionMismatch(let expected, let got):
            return "Embedding dimension mismatch: expected \(expected), got \(got)"
        case .missingAPIKey(let provider):
            return "No \(provider) API key. Add one in Settings → AI."
        case .network(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let status, let message):
            return "Embedding provider returned \(status)\(message.map { ": \($0)" } ?? "")"
        case .decode(let detail):
            return "Couldn't decode embedding response: \(detail)"
        }
    }
}

// MARK: - Apple NLEmbedding backend

/// On-device sentence embedding using `NLEmbedding`. Free, offline,
/// works for English, Spanish, French, German, Italian, Portuguese,
/// Russian, Chinese, and Japanese. Quality is moderate but adequate
/// for the chat-with-book use case — the BM25 ranker carries the
/// keyword-overlap precision; embeddings just have to surface
/// conceptually-related paragraphs the keyword pass missed.
///
/// `NLEmbedding.sentenceEmbedding(for: .english)` is loaded once and
/// reused for every embed call. The embedding is a value type that
/// owns its own backing store, so concurrent reads from multiple
/// tasks are safe.
public struct NLSentenceEmbeddingBackend: EmbeddingBackend {
    public let identifier: String
    public let dimension: Int
    /// Captured at init so each `embed` call is sync internally —
    /// avoids re-resolving the model per text. Mark `@unchecked
    /// Sendable` storage in the wrapper because `NLEmbedding` isn't
    /// formally Sendable but is documented as concurrency-safe for
    /// `vector(for:)` reads.
    private let embedding: ConcurrencySafeEmbedding

    /// Build a backend for the given language. Returns nil when
    /// Apple's on-device model isn't available (rare; the system
    /// includes English by default).
    public init?(language: NLLanguage = .english) {
        guard let raw = NLEmbedding.sentenceEmbedding(for: language) else {
            return nil
        }
        self.identifier = "apple.nl.sentence.\(language.rawValue)"
        self.dimension = raw.dimension
        self.embedding = ConcurrencySafeEmbedding(raw)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        // NLEmbedding's `vector(for:)` is synchronous and quick
        // (~1-3 ms per short text). Loop in-place; the protocol
        // exposes async to keep parity with HTTP-backed backends
        // that genuinely benefit from async batching.
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for text in texts {
            // Apple's API returns nil for inputs that produce no
            // useful representation (empty string, all-punctuation,
            // etc.). Emit a zero-vector — it'll fall to the bottom
            // of any cosine sort without breaking the pipeline.
            let vec = embedding.vector(for: text) ?? Array(repeating: 0, count: dimension)
            guard vec.count == dimension else {
                throw EmbeddingError.dimensionMismatch(
                    expected: dimension, got: vec.count
                )
            }
            out.append(vec.map(Float.init))
        }
        return out
    }
}

/// `NLEmbedding` storage that's safe to ferry across tasks. The
/// underlying `NLEmbedding` is documented as concurrency-safe for
/// read-only `vector(for:)` queries (it's a thin wrapper over an
/// immutable mmap'd model file), but it isn't annotated `Sendable`
/// in the SDK. The wrapper holds the reference behind an
/// `@unchecked Sendable` boundary so we don't propagate the
/// non-Sendable type into the public protocol.
private struct ConcurrencySafeEmbedding: @unchecked Sendable {
    let raw: NLEmbedding
    init(_ raw: NLEmbedding) { self.raw = raw }
    func vector(for text: String) -> [Double]? {
        // Trim before lookup — leading/trailing whitespace doesn't
        // change semantics but does change the lookup key for cache
        // misses upstream of NLEmbedding.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return raw.vector(for: trimmed)
    }
}

// MARK: - Ollama embedding backend

/// Embedding backend driven by an Ollama daemon's `/api/embed`
/// endpoint. Better quality than `NLEmbedding` for technical / code
/// content (depending on the chosen model), and free / local — the
/// same Ollama install that powers the local-chat path can serve
/// embeddings.
///
/// Dimension is probed at construction time by embedding a single
/// short string; this is the only way to know without a per-model
/// hard-coded table, which would silently break when users pick
/// non-standard models.
public struct OllamaEmbeddingBackend: EmbeddingBackend {
    public let identifier: String
    public let dimension: Int
    public let model: String
    private let client: OllamaClient

    /// Build a backend by probing the daemon for the model's
    /// dimension. Throws `EmbeddingError.backendUnavailable` if the
    /// daemon isn't reachable or the model isn't pulled.
    public static func make(
        model: String, client: OllamaClient = OllamaClient()
    ) async throws -> OllamaEmbeddingBackend {
        let probe: [[Float]]
        do {
            probe = try await client.embed(model: model, texts: ["x"])
        } catch let error as OllamaError {
            switch error {
            case .daemonNotReachable:
                throw EmbeddingError.backendUnavailable(
                    "Ollama daemon not running at \(client.config.baseURL.absoluteString)"
                )
            case .modelNotPulled(let name):
                throw EmbeddingError.backendUnavailable(
                    "Ollama model \"\(name)\" isn't pulled. Run `ollama pull \(name)`."
                )
            case .serverError(let status, let message):
                throw EmbeddingError.serverError(
                    status: status, message: message
                )
            case .network(let inner):
                throw EmbeddingError.network(inner)
            case .decode(let detail):
                throw EmbeddingError.decode(detail)
            }
        }
        guard let firstVector = probe.first, !firstVector.isEmpty else {
            throw EmbeddingError.decode(
                "ollama returned empty embeddings for the dimension probe"
            )
        }
        return OllamaEmbeddingBackend(
            identifier: "ollama.\(model)",
            dimension: firstVector.count,
            model: model,
            client: client
        )
    }

    /// Internal init — public callers go through `make` so the
    /// dimension probe always runs.
    internal init(
        identifier: String,
        dimension: Int,
        model: String,
        client: OllamaClient
    ) {
        self.identifier = identifier
        self.dimension = dimension
        self.model = model
        self.client = client
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        do {
            let vectors = try await client.embed(model: model, texts: texts)
            // Defend against a daemon that returns vectors of a
            // different dimension than what the probe saw — would
            // corrupt the sidecar silently otherwise.
            for v in vectors where v.count != dimension {
                throw EmbeddingError.dimensionMismatch(
                    expected: dimension, got: v.count
                )
            }
            return vectors
        } catch let error as EmbeddingError {
            throw error
        } catch let error as OllamaError {
            switch error {
            case .daemonNotReachable:
                throw EmbeddingError.backendUnavailable(
                    "Ollama daemon not running"
                )
            case .modelNotPulled(let name):
                throw EmbeddingError.backendUnavailable(
                    "Ollama model \"\(name)\" not pulled"
                )
            case .serverError(let status, let message):
                throw EmbeddingError.serverError(
                    status: status, message: message
                )
            case .network(let inner):
                throw EmbeddingError.network(inner)
            case .decode(let detail):
                throw EmbeddingError.decode(detail)
            }
        }
    }
}
