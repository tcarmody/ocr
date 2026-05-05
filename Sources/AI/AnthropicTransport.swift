import Foundation

/// Minimal abstraction over `URLSession.data(for:)` so the API
/// client can be unit-tested without a network and so a future
/// batch-mode runner can swap in its own transport without touching
/// `AnthropicMessageRequest` / `AnthropicMessageResponse`.
public protocol AnthropicTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// Production transport: a thin wrapper around `URLSession`.
public struct URLSessionTransport: AnthropicTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
