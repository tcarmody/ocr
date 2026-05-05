import Foundation

/// Errors surfaced by the Anthropic API client.
///
/// `isRetryable` exposes which categories the client retries
/// internally; callers don't usually need to retry themselves, but
/// the flag is public so a higher-level scheduler (a future
/// batch-mode runner, or an editor "regenerate" affordance) can
/// distinguish "the request is bad" from "we hit a transient
/// upstream blip."
public enum AnthropicAPIError: Error, LocalizedError, Sendable {
    /// No API key in the keychain — Cloud mode requires the user
    /// to paste one in the Settings pane.
    case missingAPIKey
    /// 400 — malformed request, missing field, bad schema.
    case invalidRequest(message: String)
    /// 401 — bad / revoked key.
    case authenticationFailed
    /// 403 — key is valid but not permitted for the requested model.
    case permissionDenied(message: String)
    /// 404 — model id doesn't exist; usually a typo or a model that
    /// was retired.
    case notFound(message: String)
    /// 413 — request body exceeds upload limit.
    case requestTooLarge
    /// 429 — `retry-after` is the server's hint (in seconds); nil
    /// when the response didn't include the header.
    case rateLimited(retryAfter: TimeInterval?)
    /// 500 / 502 / 503 — service issue.
    case serverError(status: Int, message: String?)
    /// 529 — Anthropic temporarily overloaded.
    case overloaded
    /// URLSession failed (network down, TLS error, timeout).
    case network(any Error)
    /// Response body wasn't JSON or didn't match the schema.
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key configured. Add one in Settings."
        case .invalidRequest(let m):       return "Invalid request: \(m)"
        case .authenticationFailed:        return "Anthropic API authentication failed — check the key in Settings."
        case .permissionDenied(let m):     return "Permission denied: \(m)"
        case .notFound(let m):             return "Not found: \(m)"
        case .requestTooLarge:             return "Request body exceeds the API size limit."
        case .rateLimited(let retry):
            if let retry { return "Rate limited (retry after \(Int(retry))s)." }
            return "Rate limited."
        case .serverError(let s, let m):
            if let m { return "Anthropic server error \(s): \(m)" }
            return "Anthropic server error \(s)."
        case .overloaded:                  return "Anthropic API is overloaded — try again shortly."
        case .network(let e):              return "Network error: \(e.localizedDescription)"
        case .decode(let m):               return "Failed to decode response: \(m)"
        }
    }

    /// True when retrying the same request stands a chance of
    /// succeeding without caller intervention. Used by the client's
    /// retry loop.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .network:
            return true
        case .serverError(let status, _):
            return status >= 500
        case .missingAPIKey, .invalidRequest, .authenticationFailed,
             .permissionDenied, .notFound, .requestTooLarge, .decode:
            return false
        }
    }
}
