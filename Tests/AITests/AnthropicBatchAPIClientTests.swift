import XCTest
@testable import AI

/// `AnthropicBatchAPIClient` against a mocked `AnthropicTransport`.
/// Verifies the wire shapes (submit body, GET status / results
/// URLs, headers), the result-line decoder's branching across
/// succeeded / errored / refused / canceled / expired, and the
/// poll loop (calls status repeatedly until `.ended`).
final class AnthropicBatchAPIClientTests: XCTestCase {

    actor MockTransport: AnthropicTransport {
        struct Step {
            var status: Int
            var body: Data
            var headers: [String: String] = [:]
        }
        private var queue: [Step]
        private(set) var sentRequests: [URLRequest] = []

        init(steps: [Step]) { self.queue = steps }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            sentRequests.append(request)
            guard !queue.isEmpty else {
                throw NSError(domain: "MockTransport", code: 0)
            }
            let step = queue.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: step.status,
                httpVersion: "HTTP/1.1", headerFields: step.headers
            )!
            return (step.body, response)
        }
    }

    private func makeClient(
        transport: any AnthropicTransport,
        pollInterval: TimeInterval = 0.001,
        pollTimeout: TimeInterval = 5
    ) -> AnthropicBatchAPIClient {
        AnthropicBatchAPIClient(
            config: AnthropicBatchAPIClient.Config(
                pollInterval: pollInterval,
                pollTimeout: pollTimeout
            ),
            transport: transport,
            apiKeyProvider: { "sk-test" },
            sleeper: { _ in }
        )
    }

    // MARK: - submit

    func test_submit_posts_to_batches_endpoint_with_required_headers() async throws {
        let body = #"""
        {"id":"msgbatch_01","processing_status":"in_progress"}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 200, body: body)])
        let client = makeClient(transport: mock)
        let req = AnthropicBatchSubmitRequest(requests: [
            .init(customId: "page-0", params: AnthropicMessageRequest(
                model: .haiku4_5, maxTokens: 16,
                messages: [.init(role: .user, content: .plain("hi"))]
            )),
        ])
        let resp = try await client.submit(req)
        XCTAssertEqual(resp.id, "msgbatch_01")
        XCTAssertEqual(resp.processingStatus, .inProgress)

        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].httpMethod, "POST")
        XCTAssertTrue(sent[0].url?.path.contains("/v1/messages/batches") == true)
        XCTAssertEqual(sent[0].value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(sent[0].value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(sent[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func test_submit_serializes_custom_id_per_request() async throws {
        let body = #"""
        {"id":"msgbatch_x","processing_status":"in_progress"}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 200, body: body)])
        let client = makeClient(transport: mock)
        let req = AnthropicBatchSubmitRequest(requests: [
            .init(customId: "page-0", params: AnthropicMessageRequest(
                model: .haiku4_5, maxTokens: 8,
                messages: [.init(role: .user, content: .plain("a"))]
            )),
            .init(customId: "page-1", params: AnthropicMessageRequest(
                model: .haiku4_5, maxTokens: 8,
                messages: [.init(role: .user, content: .plain("b"))]
            )),
        ])
        _ = try await client.submit(req)

        let sent = await mock.sentRequests
        let json = try JSONSerialization.jsonObject(
            with: sent[0].httpBody!
        ) as! [String: Any]
        let requests = json["requests"] as! [[String: Any]]
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["custom_id"] as? String, "page-0")
        XCTAssertEqual(requests[1]["custom_id"] as? String, "page-1")
    }

    func test_submit_throws_missing_api_key() async {
        let mock = MockTransport(steps: [])
        let client = AnthropicBatchAPIClient(
            transport: mock, apiKeyProvider: { nil }
        )
        do {
            _ = try await client.submit(
                AnthropicBatchSubmitRequest(requests: [])
            )
            XCTFail("expected missing-key error")
        } catch AnthropicAPIError.missingAPIKey {
            // expected
        } catch {
            XCTFail("expected .missingAPIKey, got \(error)")
        }
    }

    func test_submit_maps_4xx_to_typed_error() async {
        let errorBody = #"""
        {"type":"error","error":{"type":"invalid_request_error","message":"too many requests in batch"}}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 400, body: errorBody)])
        let client = makeClient(transport: mock)
        do {
            _ = try await client.submit(
                AnthropicBatchSubmitRequest(requests: [])
            )
            XCTFail("expected invalid-request error")
        } catch AnthropicAPIError.invalidRequest(let msg) {
            XCTAssertTrue(msg.contains("too many"))
        } catch {
            XCTFail("expected .invalidRequest, got \(error)")
        }
    }

    // MARK: - status

    func test_status_decodes_in_progress_response() async throws {
        let body = #"""
        {"id":"msgbatch_01","processing_status":"in_progress"}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 200, body: body)])
        let client = makeClient(transport: mock)
        let s = try await client.status(batchId: "msgbatch_01")
        XCTAssertEqual(s.processingStatus, .inProgress)
        XCTAssertNil(s.resultsUrl)

        let sent = await mock.sentRequests
        XCTAssertEqual(sent[0].httpMethod, "GET")
        XCTAssertTrue(sent[0].url?.path.contains("msgbatch_01") == true)
    }

    func test_status_decodes_ended_response_with_results_url() async throws {
        let body = #"""
        {"id":"msgbatch_01","processing_status":"ended","results_url":"https://example.invalid/results.jsonl"}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 200, body: body)])
        let client = makeClient(transport: mock)
        let s = try await client.status(batchId: "msgbatch_01")
        XCTAssertEqual(s.processingStatus, .ended)
        XCTAssertEqual(s.resultsUrl, "https://example.invalid/results.jsonl")
    }

    // MARK: - awaitCompletion

    func test_awaitCompletion_polls_until_ended() async throws {
        // Three status calls: in_progress, in_progress, ended.
        // The client must poll three times to converge.
        let inProgress = #"""
        {"id":"msgbatch_01","processing_status":"in_progress"}
        """#.data(using: .utf8)!
        let ended = #"""
        {"id":"msgbatch_01","processing_status":"ended","results_url":"https://example.invalid/r"}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [
            .init(status: 200, body: inProgress),
            .init(status: 200, body: inProgress),
            .init(status: 200, body: ended),
        ])
        let client = makeClient(transport: mock)
        let final = try await client.awaitCompletion(batchId: "msgbatch_01")
        XCTAssertEqual(final.processingStatus, .ended)
        XCTAssertEqual(final.resultsUrl, "https://example.invalid/r")
        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 3,
            "should poll until ended — three rounds for this fixture")
    }

    // MARK: - fetchResults — JSONL decoder

    func test_fetchResults_decodes_succeeded_line() async throws {
        let line = #"""
        {"custom_id":"page-0","result":{"type":"succeeded","message":{"id":"msg","type":"message","role":"assistant","model":"claude-haiku-4-5","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":1}}}}
        """#
        let mock = MockTransport(steps: [
            .init(status: 200, body: line.data(using: .utf8)!)
        ])
        let client = makeClient(transport: mock)
        let results = try await client.fetchResults(
            from: "https://example.invalid/results"
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].customId, "page-0")
        guard case .succeeded(let msg) = results[0].result else {
            XCTFail("expected .succeeded"); return
        }
        XCTAssertEqual(msg.primaryText, "hi")
    }

    func test_fetchResults_decodes_refusal_as_refused_branch() async throws {
        // Refusal stop reason routes to `.refused`, not `.succeeded`,
        // so callers can branch cleanly on the result type instead
        // of inspecting `didRefuse` on every line.
        let line = #"""
        {"custom_id":"page-0","result":{"type":"succeeded","message":{"id":"msg","type":"message","role":"assistant","model":"claude-haiku-4-5","content":[{"type":"text","text":"I cannot help."}],"stop_reason":"refusal","usage":{"input_tokens":5,"output_tokens":3}}}}
        """#
        let mock = MockTransport(steps: [
            .init(status: 200, body: line.data(using: .utf8)!)
        ])
        let client = makeClient(transport: mock)
        let results = try await client.fetchResults(
            from: "https://example.invalid/r"
        )
        XCTAssertEqual(results.count, 1)
        guard case .refused = results[0].result else {
            XCTFail("expected .refused branch for refusal stop reason"); return
        }
    }

    func test_fetchResults_decodes_errored_line() async throws {
        let line = #"""
        {"custom_id":"page-1","result":{"type":"errored","error":{"type":"server_error","message":"oops"}}}
        """#
        let mock = MockTransport(steps: [
            .init(status: 200, body: line.data(using: .utf8)!)
        ])
        let client = makeClient(transport: mock)
        let results = try await client.fetchResults(
            from: "https://example.invalid/r"
        )
        XCTAssertEqual(results.count, 1)
        guard case .errored(let msg) = results[0].result else {
            XCTFail("expected .errored"); return
        }
        XCTAssertEqual(msg, "oops")
    }

    func test_fetchResults_decodes_canceled_and_expired_lines() async throws {
        let lines = """
            {"custom_id":"page-2","result":{"type":"canceled"}}
            {"custom_id":"page-3","result":{"type":"expired"}}
            """
        let mock = MockTransport(steps: [
            .init(status: 200, body: lines.data(using: .utf8)!)
        ])
        let client = makeClient(transport: mock)
        let results = try await client.fetchResults(
            from: "https://example.invalid/r"
        )
        XCTAssertEqual(results.count, 2)
        guard case .canceled = results[0].result else {
            XCTFail("expected .canceled for page-2"); return
        }
        guard case .expired = results[1].result else {
            XCTFail("expected .expired for page-3"); return
        }
    }

    func test_fetchResults_skips_corrupt_jsonl_lines() async throws {
        // One valid + one nonsense + one valid. The decoder skips
        // the corrupt line without throwing — partial-batch
        // recovery is the point.
        let lines = """
            {"custom_id":"page-0","result":{"type":"canceled"}}
            this is not json
            {"custom_id":"page-1","result":{"type":"expired"}}
            """
        let mock = MockTransport(steps: [
            .init(status: 200, body: lines.data(using: .utf8)!)
        ])
        let client = makeClient(transport: mock)
        let results = try await client.fetchResults(
            from: "https://example.invalid/r"
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map(\.customId), ["page-0", "page-1"])
    }
}
