import Foundation

/// Minimal Sendable abstraction over `URLSession.data(for:)` for
/// Google Generative Language API clients. Mirrors
/// `AnthropicTransport` so the same mock-injection pattern works
/// for batch client unit tests without a network. The Gemini sync
/// engine in `GeminiPageOCREngine` still uses `URLSession.shared`
/// directly (it predates this protocol); the batch client below
/// uses this seam so its tests can replay scripted responses.
public protocol GoogleAITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// Production transport: a thin wrapper around `URLSession`.
public struct URLSessionGoogleAITransport: GoogleAITransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
