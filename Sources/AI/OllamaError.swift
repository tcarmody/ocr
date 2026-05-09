import Foundation

/// Typed errors for the Ollama HTTP client. Mirrors the shape of
/// `AnthropicAPIError` so chat-pane error handling stays uniform
/// across Cloud and local backends.
public enum OllamaError: Error, LocalizedError, Sendable {
    /// `localhost:11434` refused the connection. Ollama isn't
    /// installed, the daemon isn't running, or it's listening on
    /// a non-default port.
    case daemonNotReachable

    /// Ollama responded but doesn't have the requested model.
    /// User needs to `ollama pull <name>` (or use the setup wizard).
    case modelNotPulled(name: String)

    /// Underlying URL/network failure (timeout, transient I/O).
    case network(Error)

    /// Server returned non-2xx with a body we couldn't parse.
    case serverError(status: Int, message: String?)

    /// Response body didn't decode to the expected shape.
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .daemonNotReachable:
            return "Ollama isn't running. Open Ollama (or run `ollama serve` in Terminal) and try again."
        case .modelNotPulled(let name):
            return "Model \"\(name)\" isn't installed. Pull it with `ollama pull \(name)` or use Set Up Local Chat."
        case .network(let err):
            return "Network error talking to Ollama: \(err.localizedDescription)"
        case .serverError(let status, let message):
            return message.map { "Ollama error (\(status)): \($0)" } ?? "Ollama error (\(status))."
        case .decode(let detail):
            return "Couldn't parse Ollama response: \(detail)"
        }
    }
}
