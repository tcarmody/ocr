import XCTest
@testable import AI

/// `GeminiBatchAPIClient` against a mocked `GoogleAITransport`.
/// Mirrors the existing `AnthropicBatchAPIClientTests` shape so
/// the two batch surfaces have parallel test posture. Covers:
///   * Files-API upload (init + finalize two-step).
///   * Submit body shape + per-model endpoint.
///   * Status / state-enum decoding (incl. dest.file_name +
///     error.message extraction).
///   * Poll loop reaches a terminal state.
///   * Result JSONL parser: succeeded, errored (`status` shape),
///     errored (`error` shape), malformed lines.
final class GeminiBatchAPIClientTests: XCTestCase {

    actor MockTransport: GoogleAITransport {
        struct Step {
            var status: Int
            var body: Data
            var headers: [String: String] = [:]
        }
        private var queue: [Step]
        private(set) var sentRequests: [URLRequest] = []
        private(set) var sentBodies: [Data] = []

        init(steps: [Step]) { self.queue = steps }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            sentRequests.append(request)
            sentBodies.append(request.httpBody ?? Data())
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
        transport: any GoogleAITransport,
        pollInterval: TimeInterval = 0.001,
        pollTimeout: TimeInterval = 5
    ) -> GeminiBatchAPIClient {
        GeminiBatchAPIClient(
            config: GeminiBatchAPIClient.Config(
                pollInterval: pollInterval,
                pollTimeout: pollTimeout
            ),
            transport: transport,
            apiKeyProvider: { "AIza-test" },
            sleeper: { _ in }
        )
    }

    // MARK: - upload

    func test_uploadJSONL_two_step_returns_file_name() async throws {
        let initBody = Data()  // Google returns empty body + headers
        let initHeaders = [
            "x-goog-upload-url": "https://upload.example/abc123"
        ]
        let finalizeBody = #"""
        {"file":{"name":"files/abc-123","display_name":"input.jsonl"}}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [
            .init(status: 200, body: initBody, headers: initHeaders),
            .init(status: 200, body: finalizeBody),
        ])
        let client = makeClient(transport: mock)
        let name = try await client.uploadJSONL(
            "abc".data(using: .utf8)!,
            displayName: "input.jsonl"
        )
        XCTAssertEqual(name, "files/abc-123")

        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 2)
        // Init request: POST to /upload/v1beta/files
        XCTAssertEqual(sent[0].httpMethod, "POST")
        XCTAssertTrue(sent[0].url?.path.contains("/upload/v1beta/files") == true)
        XCTAssertEqual(
            sent[0].value(forHTTPHeaderField: "X-Goog-Upload-Protocol"),
            "resumable"
        )
        XCTAssertEqual(
            sent[0].value(forHTTPHeaderField: "X-Goog-Upload-Command"),
            "start"
        )
        XCTAssertEqual(
            sent[0].value(forHTTPHeaderField: "x-goog-api-key"),
            "AIza-test"
        )
        // Finalize request: POST to the upload URL with finalize cmd
        XCTAssertEqual(sent[1].httpMethod, "POST")
        XCTAssertEqual(
            sent[1].url?.absoluteString,
            "https://upload.example/abc123"
        )
        XCTAssertEqual(
            sent[1].value(forHTTPHeaderField: "X-Goog-Upload-Command"),
            "upload, finalize"
        )
    }

    func test_uploadJSONL_missing_upload_url_throws() async throws {
        // Init returns 200 but no x-goog-upload-url header.
        let mock = MockTransport(steps: [
            .init(status: 200, body: Data(), headers: [:])
        ])
        let client = makeClient(transport: mock)
        do {
            _ = try await client.uploadJSONL(
                Data(), displayName: "x"
            )
            XCTFail("expected throw")
        } catch GeminiBatchError.missingUploadURL {
            // expected
        }
    }

    // MARK: - submit

    func test_submit_posts_to_per_model_endpoint_with_required_headers() async throws {
        // Real submit body shape: Long-Running Operation envelope
        // with state under `metadata`, prefix BATCH_STATE_*.
        let body = #"""
        {"name":"batches/abc",
         "metadata":{
           "@type":"type.googleapis.com/google.ai.generativelanguage.v1main.GenerateContentBatch",
           "state":"BATCH_STATE_PENDING",
           "displayName":"book-x"
         }}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 200, body: body)])
        let client = makeClient(transport: mock)
        let req = GeminiBatchSubmitRequest(
            displayName: "book-x",
            inputFileName: "files/abc-123"
        )
        let resp = try await client.submit(
            model: "gemini-2.5-flash",
            request: req
        )
        XCTAssertEqual(resp.name, "batches/abc")
        XCTAssertEqual(resp.state, .pending)

        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].httpMethod, "POST")
        XCTAssertTrue(
            sent[0].url?.path
                .contains("/v1beta/models/gemini-2.5-flash:batchGenerateContent")
                == true
        )
        XCTAssertEqual(
            sent[0].value(forHTTPHeaderField: "x-goog-api-key"),
            "AIza-test"
        )
        XCTAssertEqual(
            sent[0].value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )

        // Verify the nested body envelope shape.
        let sentBody = await mock.sentBodies[0]
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: sentBody)
                as? [String: Any]
        )
        let batch = try XCTUnwrap(json["batch"] as? [String: Any])
        XCTAssertEqual(batch["display_name"] as? String, "book-x")
        let input = try XCTUnwrap(batch["input_config"] as? [String: Any])
        XCTAssertEqual(input["file_name"] as? String, "files/abc-123")
    }

    // MARK: - status

    func test_status_decodes_succeeded_with_response_responsesFile() async throws {
        // Live API shape: metadata.state + response.responsesFile
        // on a succeeded LRO.
        let body = #"""
        {"name":"batches/abc",
         "metadata":{"state":"BATCH_STATE_SUCCEEDED"},
         "response":{"responsesFile":"files/results-xyz"}}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 200, body: body)])
        let client = makeClient(transport: mock)
        let resp = try await client.status(name: "batches/abc")
        XCTAssertEqual(resp.state, .succeeded)
        XCTAssertEqual(resp.resultsFileName, "files/results-xyz")
        XCTAssertNil(resp.errorMessage)
    }

    func test_status_decodes_succeeded_fallback_dest_fileName() async throws {
        // Some SDK paths surface `dest.fileName` instead. Decoder
        // should accept either.
        let body = #"""
        {"name":"batches/abc",
         "metadata":{"state":"BATCH_STATE_SUCCEEDED"},
         "dest":{"fileName":"files/results-xyz"}}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 200, body: body)])
        let client = makeClient(transport: mock)
        let resp = try await client.status(name: "batches/abc")
        XCTAssertEqual(resp.resultsFileName, "files/results-xyz")
    }

    func test_status_decodes_succeeded_fallback_dest_file_name_snake() async throws {
        // Older docs show `dest.file_name` (snake). Still accepted.
        let body = #"""
        {"name":"batches/abc",
         "metadata":{"state":"BATCH_STATE_SUCCEEDED"},
         "dest":{"file_name":"files/results-xyz"}}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 200, body: body)])
        let client = makeClient(transport: mock)
        let resp = try await client.status(name: "batches/abc")
        XCTAssertEqual(resp.resultsFileName, "files/results-xyz")
    }

    func test_status_decodes_failed_with_error_message() async throws {
        let body = #"""
        {"name":"batches/abc",
         "metadata":{
           "state":"BATCH_STATE_FAILED",
           "error":{"message":"invalid file","code":3}
         }}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 200, body: body)])
        let client = makeClient(transport: mock)
        let resp = try await client.status(name: "batches/abc")
        XCTAssertEqual(resp.state, .failed)
        XCTAssertEqual(resp.errorMessage, "invalid file")
        XCTAssertNil(resp.resultsFileName)
    }

    func test_status_accepts_legacy_JOB_STATE_prefix() async throws {
        // Older docs surface JOB_STATE_* — decoder should still
        // accept it.
        let body = #"""
        {"name":"batches/abc",
         "metadata":{"state":"JOB_STATE_RUNNING"}}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 200, body: body)])
        let client = makeClient(transport: mock)
        let resp = try await client.status(name: "batches/abc")
        XCTAssertEqual(resp.state, .running)
    }

    // MARK: - await completion

    func test_awaitCompletion_polls_until_terminal() async throws {
        let running = #"""
        {"name":"batches/abc","metadata":{"state":"BATCH_STATE_RUNNING"}}
        """#.data(using: .utf8)!
        let done = #"""
        {"name":"batches/abc",
         "metadata":{"state":"BATCH_STATE_SUCCEEDED"},
         "response":{"responsesFile":"files/r"}}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [
            .init(status: 200, body: running),
            .init(status: 200, body: running),
            .init(status: 200, body: done),
        ])
        let client = makeClient(transport: mock)
        let resp = try await client.awaitCompletion(name: "batches/abc")
        XCTAssertEqual(resp.state, .succeeded)
        XCTAssertEqual(resp.resultsFileName, "files/r")
        let count = await mock.sentRequests.count
        XCTAssertEqual(count, 3)
    }

    func test_awaitCompletion_returns_unsuccessful_terminals_for_inspection() async throws {
        // Expired / failed / cancelled all return — caller inspects.
        for state in ["BATCH_STATE_EXPIRED", "BATCH_STATE_FAILED", "BATCH_STATE_CANCELLED"] {
            let body = #"""
            {"name":"batches/abc","metadata":{"state":"\#(state)"}}
            """#.data(using: .utf8)!
            let mock = MockTransport(steps: [.init(status: 200, body: body)])
            let client = makeClient(transport: mock)
            let resp = try await client.awaitCompletion(name: "batches/abc")
            XCTAssertTrue(resp.state.isTerminal)
            XCTAssertNotEqual(resp.state, .succeeded)
        }
    }

    func test_awaitCompletion_throws_on_poll_timeout() async throws {
        let running = #"""
        {"name":"batches/abc","metadata":{"state":"BATCH_STATE_RUNNING"}}
        """#.data(using: .utf8)!
        let steps = Array(repeating: MockTransport.Step(
            status: 200, body: running
        ), count: 1000)
        let mock = MockTransport(steps: steps)
        // Tiny pollTimeout so the test finishes quickly. The
        // sleeper is a no-op (no real wait), so the loop will
        // iterate fast and trip the timeout check.
        let client = GeminiBatchAPIClient(
            config: .init(pollInterval: 0.001, pollTimeout: 0.001),
            transport: mock,
            apiKeyProvider: { "AIza-test" },
            sleeper: { _ in }
        )
        do {
            _ = try await client.awaitCompletion(name: "batches/abc")
            XCTFail("expected timeout throw")
        } catch GeminiBatchError.pollTimedOut(_, let s) {
            XCTAssertEqual(s, 0.001, accuracy: 0.0001)
        }
    }

    // MARK: - fetch results

    func test_parseResultsJSONL_handles_live_shape_with_metadata_key() throws {
        // Live API result-line shape captured from a real run:
        // `metadata.key` (mirrors how the submit body nests it).
        let jsonl = #"""
        {"metadata":{"key":"page-00000"},"response":{"candidates":[{"content":{"parts":[{"text":"hi"}]}}],"usageMetadata":{"totalTokenCount":42}}}
        """#
        let data = jsonl.data(using: .utf8)!
        let lines = GeminiBatchAPIClient.parseResultsJSONL(data: data)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].key, "page-00000")
        if case .succeeded = lines[0].result {
            // expected
        } else {
            XCTFail("expected succeeded result")
        }
    }

    func test_parseResultsJSONL_handles_success_status_error_and_malformed() throws {
        // Mix of legacy top-level-key shape (kept tolerant in
        // case Google ever flips back) and edge cases.
        let jsonl = [
            #"{"key":"page-00000","response":{"candidates":[{"content":{"parts":[{"text":"hi"}]}}]}}"#,
            #"{"key":"page-00001","status":{"code":3,"message":"safety filter"}}"#,
            #"{"key":"page-00002","error":{"message":"unknown error","code":13}}"#,
            #"{"key":"page-00003","weird":"shape"}"#,
            #"not even json"#,
        ].joined(separator: "\n")
        let data = jsonl.data(using: .utf8)!
        let lines = GeminiBatchAPIClient.parseResultsJSONL(data: data)
        XCTAssertEqual(lines.count, 4)  // last line not JSON, skipped

        XCTAssertEqual(lines[0].key, "page-00000")
        if case .succeeded(let raw) = lines[0].result {
            let obj = try JSONSerialization.jsonObject(with: raw)
                as? [String: Any]
            XCTAssertNotNil(obj?["candidates"])
        } else {
            XCTFail("expected succeeded")
        }

        XCTAssertEqual(lines[1].key, "page-00001")
        if case .errored(let m) = lines[1].result {
            XCTAssertEqual(m, "safety filter")
        } else {
            XCTFail("expected errored")
        }

        XCTAssertEqual(lines[2].key, "page-00002")
        if case .errored(let m) = lines[2].result {
            XCTAssertEqual(m, "unknown error")
        } else {
            XCTFail("expected errored")
        }

        XCTAssertEqual(lines[3].key, "page-00003")
        if case .errored(let m) = lines[3].result {
            XCTAssertEqual(m, "malformed result line")
        } else {
            XCTFail("expected errored")
        }
    }

    func test_fetchResults_downloads_via_alt_media() async throws {
        let body = #"""
        {"key":"page-00000","response":{"candidates":[]}}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 200, body: body)])
        let client = makeClient(transport: mock)
        let lines = try await client.fetchResults(
            fileName: "files/results-xyz"
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].key, "page-00000")

        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].httpMethod, "GET")
        XCTAssertTrue(
            sent[0].url?.absoluteString
                .contains("/download/v1beta/files/results-xyz:download") == true
        )
        XCTAssertEqual(
            sent[0].url?.query?.contains("alt=media"), true
        )
    }

    // MARK: - errors

    func test_error_mapping_400_returns_invalidRequest_with_message() async throws {
        let body = #"""
        {"error":{"code":400,"message":"missing batch.display_name"}}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 400, body: body)])
        let client = makeClient(transport: mock)
        do {
            _ = try await client.status(name: "batches/abc")
            XCTFail("expected throw")
        } catch GeminiBatchError.invalidRequest(let m) {
            XCTAssertEqual(m, "missing batch.display_name")
        }
    }

    func test_error_mapping_401_returns_auth_failed() async throws {
        let mock = MockTransport(steps: [.init(status: 401, body: Data())])
        let client = makeClient(transport: mock)
        do {
            _ = try await client.status(name: "batches/abc")
            XCTFail("expected throw")
        } catch GeminiBatchError.authenticationFailed {
            // expected
        }
    }

    func test_missing_api_key_throws_before_network() async throws {
        let mock = MockTransport(steps: [])
        let client = GeminiBatchAPIClient(
            config: .init(),
            transport: mock,
            apiKeyProvider: { nil },
            sleeper: { _ in }
        )
        do {
            _ = try await client.status(name: "batches/abc")
            XCTFail("expected throw")
        } catch GeminiBatchError.missingAPIKey {
            // expected
        }
        let count = await mock.sentRequests.count
        XCTAssertEqual(count, 0)
    }
}
