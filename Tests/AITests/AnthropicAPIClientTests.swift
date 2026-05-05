import XCTest
@testable import AI

/// Exercises the retry / error-mapping / header-shape logic of
/// `AnthropicAPIClient` against an in-memory mock transport. No
/// network involved.
final class AnthropicAPIClientTests: XCTestCase {

    // MARK: - Mock transport

    /// Transport that returns canned responses queue-style. Each
    /// `send` call pops the next response. Captures every URLRequest
    /// it received so assertions can verify headers + body.
    actor MockTransport: AnthropicTransport {
        struct Step {
            var status: Int
            var body: Data
            var headers: [String: String] = [:]
        }
        private var queue: [Step]
        private(set) var sentRequests: [URLRequest] = []

        init(steps: [Step]) {
            self.queue = steps
        }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            sentRequests.append(request)
            guard !queue.isEmpty else {
                throw NSError(domain: "MockTransport", code: 0,
                              userInfo: [NSLocalizedDescriptionKey: "queue exhausted"])
            }
            let step = queue.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: step.status,
                httpVersion: "HTTP/1.1",
                headerFields: step.headers
            )!
            return (step.body, response)
        }
    }

    private func successBody(text: String = "ok") -> Data {
        let json = #"""
        {
          "id": "msg_test",
          "type": "message",
          "role": "assistant",
          "model": "claude-haiku-4-5-20251001",
          "content": [{"type":"text","text":"\#(text)"}],
          "stop_reason": "end_turn",
          "usage": {"input_tokens": 5, "output_tokens": 1}
        }
        """#
        return json.data(using: .utf8)!
    }

    private func errorBody(type: String, message: String) -> Data {
        let json = #"""
        {"type":"error","error":{"type":"\#(type)","message":"\#(message)"},"request_id":"req_x"}
        """#
        return json.data(using: .utf8)!
    }

    private func makeClient(
        transport: any AnthropicTransport,
        config: AnthropicAPIClient.Config = .default,
        apiKey: String? = "sk-test"
    ) -> AnthropicAPIClient {
        AnthropicAPIClient(
            config: config,
            transport: transport,
            apiKeyProvider: { apiKey },
            // Replace Task.sleep with an instant return so retry
            // tests don't actually wait.
            sleeper: { _ in }
        )
    }

    private func minimalRequest() -> AnthropicMessageRequest {
        AnthropicMessageRequest(
            model: .haiku4_5,
            maxTokens: 128,
            messages: [Message(role: .user, content: .plain("hi"))]
        )
    }

    // MARK: - Happy path

    func test_successful_request_returns_decoded_response() async throws {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: "hello"))
        ])
        let client = makeClient(transport: mock)
        let response = try await client.send(minimalRequest())
        XCTAssertEqual(response.id, "msg_test")
        XCTAssertEqual(response.primaryText, "hello")
    }

    func test_request_includes_required_headers_and_body() async throws {
        let mock = MockTransport(steps: [.init(status: 200, body: successBody())])
        let client = makeClient(transport: mock)
        _ = try await client.send(minimalRequest())
        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 1)
        let req = sent[0]
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(req.url?.path, "/v1/messages")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertNotNil(req.httpBody)
    }

    func test_no_beta_header_when_betaHeaders_empty() async throws {
        let mock = MockTransport(steps: [.init(status: 200, body: successBody())])
        let client = makeClient(transport: mock)
        _ = try await client.send(minimalRequest())
        let sent = await mock.sentRequests
        XCTAssertNil(sent[0].value(forHTTPHeaderField: "anthropic-beta"))
    }

    // MARK: - Missing key

    func test_missing_api_key_throws_before_network_call() async {
        let mock = MockTransport(steps: [])
        let client = makeClient(transport: mock, apiKey: nil)
        await XCTAssertThrowsError(try await client.send(minimalRequest())) { error in
            guard let typed = error as? AnthropicAPIError else {
                XCTFail("Expected AnthropicAPIError, got \(error)"); return
            }
            if case .missingAPIKey = typed { /* ok */ }
            else { XCTFail("Expected .missingAPIKey, got \(typed)") }
        }
    }

    // MARK: - Error mapping

    func test_400_maps_to_invalidRequest() async {
        let mock = MockTransport(steps: [
            .init(status: 400, body: errorBody(type: "invalid_request_error", message: "bad field"))
        ])
        let client = makeClient(transport: mock)
        await XCTAssertThrowsError(try await client.send(minimalRequest())) { error in
            guard case AnthropicAPIError.invalidRequest(let msg) = error else {
                XCTFail("Expected .invalidRequest, got \(error)"); return
            }
            XCTAssertEqual(msg, "bad field")
        }
    }

    func test_401_maps_to_authenticationFailed() async {
        let mock = MockTransport(steps: [.init(status: 401, body: Data())])
        let client = makeClient(transport: mock)
        await XCTAssertThrowsError(try await client.send(minimalRequest())) { error in
            if case AnthropicAPIError.authenticationFailed = error { /* ok */ }
            else { XCTFail("Expected .authenticationFailed, got \(error)") }
        }
    }

    func test_404_maps_to_notFound() async {
        let mock = MockTransport(steps: [
            .init(status: 404, body: errorBody(type: "not_found_error", message: "no model"))
        ])
        let client = makeClient(transport: mock)
        await XCTAssertThrowsError(try await client.send(minimalRequest())) { error in
            if case AnthropicAPIError.notFound = error { /* ok */ }
            else { XCTFail("Expected .notFound, got \(error)") }
        }
    }

    func test_429_with_retry_after_header_is_surfaced() async {
        let cfg = AnthropicAPIClient.Config(maxRetries: 0)  // no retry — surface raw
        let mock = MockTransport(steps: [
            .init(status: 429, body: errorBody(type: "rate_limit_error", message: "slow down"),
                  headers: ["retry-after": "30"])
        ])
        let client = makeClient(transport: mock, config: cfg)
        await XCTAssertThrowsError(try await client.send(minimalRequest())) { error in
            guard case AnthropicAPIError.rateLimited(let retryAfter) = error else {
                XCTFail("Expected .rateLimited, got \(error)"); return
            }
            XCTAssertEqual(retryAfter, 30)
        }
    }

    // MARK: - Retry behavior

    func test_429_then_200_succeeds_after_retry() async throws {
        let mock = MockTransport(steps: [
            .init(status: 429, body: errorBody(type: "rate_limit_error", message: "slow"),
                  headers: ["retry-after": "1"]),
            .init(status: 200, body: successBody(text: "after retry")),
        ])
        let client = makeClient(transport: mock)
        let response = try await client.send(minimalRequest())
        XCTAssertEqual(response.primaryText, "after retry")
        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 2)
    }

    func test_500_retries_then_succeeds() async throws {
        let mock = MockTransport(steps: [
            .init(status: 500, body: errorBody(type: "api_error", message: "blip")),
            .init(status: 503, body: errorBody(type: "api_error", message: "blip")),
            .init(status: 200, body: successBody(text: "fine")),
        ])
        let client = makeClient(transport: mock)
        let response = try await client.send(minimalRequest())
        XCTAssertEqual(response.primaryText, "fine")
        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 3)
    }

    func test_400_does_not_retry() async {
        let mock = MockTransport(steps: [
            .init(status: 400, body: errorBody(type: "invalid_request_error", message: "bad")),
        ])
        let client = makeClient(transport: mock)
        await XCTAssertThrowsError(try await client.send(minimalRequest()))
        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 1, "non-retryable errors should not retry")
    }

    func test_retries_exhaust_when_all_attempts_fail() async {
        let cfg = AnthropicAPIClient.Config(maxRetries: 2)
        let mock = MockTransport(steps: [
            .init(status: 500, body: errorBody(type: "api_error", message: "blip")),
            .init(status: 500, body: errorBody(type: "api_error", message: "blip")),
            .init(status: 500, body: errorBody(type: "api_error", message: "blip")),
        ])
        let client = makeClient(transport: mock, config: cfg)
        await XCTAssertThrowsError(try await client.send(minimalRequest())) { error in
            if case AnthropicAPIError.serverError = error { /* ok */ }
            else { XCTFail("Expected .serverError, got \(error)") }
        }
        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 3, "should attempt initial + 2 retries")
    }
}

private func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message().isEmpty ? "Expected throw" : message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
