import Foundation
import AI

/// Shared embedding-backend resolution. Centralizes the logic both
/// `BookChatViewModel` and `LibraryChatViewModel` (and now the
/// bulk-index builder) used to read the user's Settings choice and
/// build the corresponding `EmbeddingBackend` — one point of truth
/// for the per-backend factory call + fallback policy.
///
/// Returns the resolved backend plus an optional failure message
/// the UI can surface when the chosen backend isn't available
/// (Voyage key missing, Ollama daemon down, etc.). Both chat
/// surfaces fall back to NLEmbedding on failure; the bulk-index
/// path doesn't auto-fall-back because the user is asking for
/// every book to be re-embedded with a *specific* backend, and a
/// silent fall-back to a different vector space would be a footgun.
enum BackendResolver {

    struct Resolution {
        let backend: (any EmbeddingBackend)?
        /// User-facing message for the UI. nil on success.
        let failureMessage: String?
        /// Note to surface when the resolution succeeded but the
        /// requested backend silently degraded to NLEmbedding
        /// (e.g. Ollama daemon unreachable). nil otherwise.
        let fallbackNote: String?
    }

    /// Resolve for chat use. Falls back to NLEmbedding on any
    /// non-NLEmbedding backend's failure so the chat path keeps
    /// working — the fallbackNote captures the original reason
    /// for a UI surface.
    static func resolveForChat() async -> Resolution {
        let choice = currentChoice()
        switch choice {
        case .appleNL:
            return Resolution(
                backend: NLSentenceEmbeddingBackend(language: .english),
                failureMessage: nil,
                fallbackNote: nil
            )
        case .ollama:
            do {
                let model = ollamaEmbeddingModel()
                let backend = try await OllamaEmbeddingBackend.make(model: model)
                return Resolution(backend: backend, failureMessage: nil, fallbackNote: nil)
            } catch {
                let note = "Ollama embedding unavailable (\(error.localizedDescription)). Using Apple NLEmbedding instead."
                return Resolution(
                    backend: NLSentenceEmbeddingBackend(language: .english),
                    failureMessage: nil,
                    fallbackNote: note
                )
            }
        case .voyage:
            do {
                let backend = try await VoyageEmbeddingBackend.make(
                    model: voyageModel()
                )
                return Resolution(backend: backend, failureMessage: nil, fallbackNote: nil)
            } catch {
                let note = "Voyage embedding unavailable (\(error.localizedDescription)). Using Apple NLEmbedding instead."
                return Resolution(
                    backend: NLSentenceEmbeddingBackend(language: .english),
                    failureMessage: nil,
                    fallbackNote: note
                )
            }
        case .gemini:
            do {
                let backend = try await GeminiEmbeddingBackend.make(
                    model: geminiModel(),
                    outputDimensionality: geminiOutputDimensionality()
                )
                return Resolution(backend: backend, failureMessage: nil, fallbackNote: nil)
            } catch {
                let note = "Gemini embedding unavailable (\(error.localizedDescription)). Using Apple NLEmbedding instead."
                return Resolution(
                    backend: NLSentenceEmbeddingBackend(language: .english),
                    failureMessage: nil,
                    fallbackNote: note
                )
            }
        }
    }

    /// Resolve for bulk indexing. *Doesn't* fall back — the user is
    /// asking for every book to be embedded with a specific
    /// backend, and silently swapping vector spaces would corrupt
    /// the federation. On failure, returns a `failureMessage` for
    /// the UI to alert on.
    static func resolveForLibraryIndexing() async -> Resolution {
        let choice = currentChoice()
        switch choice {
        case .appleNL:
            if let backend = NLSentenceEmbeddingBackend(language: .english) {
                return Resolution(backend: backend, failureMessage: nil, fallbackNote: nil)
            }
            return Resolution(
                backend: nil,
                failureMessage: "Apple NLEmbedding for English isn't available on this system.",
                fallbackNote: nil
            )
        case .ollama:
            do {
                let backend = try await OllamaEmbeddingBackend.make(
                    model: ollamaEmbeddingModel()
                )
                return Resolution(backend: backend, failureMessage: nil, fallbackNote: nil)
            } catch {
                return Resolution(
                    backend: nil,
                    failureMessage: "Couldn't reach the Ollama embedding model: \(error.localizedDescription)",
                    fallbackNote: nil
                )
            }
        case .voyage:
            do {
                let backend = try await VoyageEmbeddingBackend.make(
                    model: voyageModel()
                )
                return Resolution(backend: backend, failureMessage: nil, fallbackNote: nil)
            } catch {
                return Resolution(
                    backend: nil,
                    failureMessage: "Voyage embedding probe failed: \(error.localizedDescription)",
                    fallbackNote: nil
                )
            }
        case .gemini:
            do {
                let backend = try await GeminiEmbeddingBackend.make(
                    model: geminiModel(),
                    outputDimensionality: geminiOutputDimensionality()
                )
                return Resolution(backend: backend, failureMessage: nil, fallbackNote: nil)
            } catch {
                return Resolution(
                    backend: nil,
                    failureMessage: "Gemini embedding probe failed: \(error.localizedDescription)",
                    fallbackNote: nil
                )
            }
        }
    }

    // MARK: - Settings access

    private static func currentChoice() -> EmbeddingBackendChoice {
        let raw = UserDefaults.standard.string(
            forKey: EmbeddingBackendChoice.userDefaultsKey
        ) ?? EmbeddingBackendChoice.appleNL.rawValue
        return EmbeddingBackendChoice(rawValue: raw) ?? .appleNL
    }

    private static func ollamaEmbeddingModel() -> String {
        let raw = UserDefaults.standard.string(
            forKey: "humanist.chat.ollamaEmbeddingModel"
        ) ?? ""
        return raw.isEmpty ? "nomic-embed-text" : raw
    }

    private static func voyageModel() -> String {
        let raw = UserDefaults.standard.string(
            forKey: "humanist.chat.voyageModel"
        ) ?? ""
        return raw.isEmpty ? "voyage-3" : raw
    }

    private static func geminiModel() -> String {
        let raw = UserDefaults.standard.string(
            forKey: "humanist.chat.geminiModel"
        ) ?? ""
        if raw.isEmpty || raw == "gemini-embedding-002" {
            return "gemini-embedding-2"
        }
        return raw
    }

    private static func geminiOutputDimensionality() -> Int? {
        let raw = UserDefaults.standard.integer(
            forKey: "humanist.chat.geminiOutputDimensionality"
        )
        return raw > 0 ? raw : nil
    }
}
