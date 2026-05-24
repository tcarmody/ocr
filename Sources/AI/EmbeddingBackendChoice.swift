import Foundation

/// Selectable embedding backend for the chat-with-book retriever.
/// Mirrors `ChatBackend` in shape: each case maps to one
/// `EmbeddingBackend` implementation and may need additional setup
/// (an Ollama daemon, a Voyage / Gemini API key).
///
/// The retriever's choice and the chat-answering choice are
/// independent — a user can run Cloud Sonnet for answers but use
/// free local NLEmbedding for retrieval, or vice versa.
public enum EmbeddingBackendChoice: String, CaseIterable, Identifiable, Sendable {
    /// Default: on-device `NLEmbedding`. Free, offline, moderate
    /// quality; the right starting point.
    case appleNL
    /// Ollama embedding endpoint (`/api/embed`). Better quality than
    /// NLEmbedding for technical text; requires the daemon and a
    /// pulled embedding model (e.g. `nomic-embed-text`).
    case ollama
    /// Voyage AI cloud embeddings. Strong on technical / academic
    /// English. Cheap (~$0.005/book). Requires a Voyage API key.
    case voyage
    /// Google Gemini Embedding 002. Currently best-in-class on the
    /// MTEB multilingual leaderboard; the right default for users
    /// reading classical-script academic content. Requires a Google
    /// AI Studio API key.
    case gemini

    public var id: String { rawValue }

    /// Persisted under this key in `UserDefaults`. Read per-build
    /// so a Settings change applies on the next chat session.
    public static let userDefaultsKey = "humanist.chat.embeddingBackend"

    public var displayName: String {
        switch self {
        case .appleNL: return "Apple NLEmbedding (offline, free)"
        case .ollama:  return "Ollama (local model)"
        case .voyage:  return "Voyage AI (cloud)"
        case .gemini:  return "Google Gemini Embedding (cloud)"
        }
    }

    public var blurb: String {
        switch self {
        case .appleNL:
            return "On-device sentence embedding. No setup, no API key, no network. Quality is moderate but enough to surface conceptually-related paragraphs the keyword pass missed."
        case .ollama:
            return "Local embedding model via the Ollama daemon. Better quality than Apple's built-in for technical text; requires a pulled embedding model like nomic-embed-text."
        case .voyage:
            return "Voyage AI's cloud embeddings. Strong on technical / academic English. Adds an API call per paragraph at index time (~$0.005 per book). Requires a Voyage API key."
        case .gemini:
            return "Google Gemini Embedding 002 — currently the highest-ranked multilingual embedder on MTEB. Best fit for books with classical Greek, Latin, or other non-English scholarly content. Requires a Google AI Studio API key."
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .appleNL, .ollama: return false
        case .voyage, .gemini:  return true
        }
    }

    /// Namespace prefix every concrete `identifier` for this
    /// choice starts with. Used by Settings's "Clear outdated"
    /// surface to flag sidecars built against a different
    /// provider — model identifiers always start with the
    /// provider name (`apple.nl.sentence.<lang>`,
    /// `voyage.<model>`, `gemini.<model>.<dim>`,
    /// `ollama.<model>`) so a starts-with check is sufficient
    /// to detect cross-provider drift. Does NOT catch
    /// within-provider model switches (e.g. Gemini-001 → 002
    /// stays a "gemini." identifier) — those are rare enough
    /// that `clearAll` is the right escape hatch.
    public var identifierPrefix: String {
        switch self {
        case .appleNL: return "apple.nl."
        case .ollama:  return "ollama."
        case .voyage:  return "voyage."
        case .gemini:  return "gemini."
        }
    }
}
