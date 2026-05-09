import Foundation

/// Selectable backend for the editor's chat-with-book pane.
///
/// `cloudHaiku` and `cloudSonnet` route to the Anthropic API
/// (require an API key). `localOllama` routes to a local Ollama
/// daemon (no key, no cost, no network egress).
///
/// The view model reads this enum per-send via UserDefaults
/// (`humanist.chat.backend`) so a Settings change applies on the
/// next query without rebuilding the chat session.
public enum ChatBackend: String, CaseIterable, Identifiable, Sendable {
    case cloudHaiku
    case cloudSonnet
    case localOllama

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cloudHaiku:  return "Cloud (Haiku)"
        case .cloudSonnet: return "Cloud (Sonnet)"
        case .localOllama: return "Local (Ollama)"
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .cloudHaiku, .cloudSonnet: return true
        case .localOllama:              return false
        }
    }
}
