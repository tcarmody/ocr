import XCTest
import CoreGraphics
import AI
import Document
import OCR
@testable import Pipeline

/// `ClaudeOCREngine` against a mocked `AnthropicTransport`. No network
/// calls. Verifies the wire shape (image is sent as base64 PNG, system
/// prompt is hardcoded, language hints land in the user turn), budget
/// enforcement, and refusal handling.
final class ClaudeOCREngineTests: XCTestCase {

    // MARK: - Mock transport

    /// Transport that returns canned responses queue-style. Captures
    /// every URLRequest body so tests can assert on the wire shape.
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
                throw NSError(domain: "MockTransport", code: 0)
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

    // MARK: - Helpers

    private func makeImage(width: Int = 100, height: Int = 50) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: info
        )!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func successBody(text: String) -> Data {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = #"""
        {
          "id": "msg_test",
          "type": "message",
          "role": "assistant",
          "model": "claude-sonnet-4-6",
          "content": [{"type":"text","text":"\#(escaped)"}],
          "stop_reason": "end_turn",
          "usage": {"input_tokens": 100, "output_tokens": 20}
        }
        """#
        return json.data(using: .utf8)!
    }

    private func refusalBody() -> Data {
        let json = #"""
        {
          "id": "msg_test",
          "type": "message",
          "role": "assistant",
          "model": "claude-sonnet-4-6",
          "content": [{"type":"text","text":"I can't help with that."}],
          "stop_reason": "refusal",
          "usage": {"input_tokens": 100, "output_tokens": 8}
        }
        """#
        return json.data(using: .utf8)!
    }

    private func makeEngine(
        transport: any AnthropicTransport,
        budget: CloudCallBudget = CloudCallBudget(cap: 10)
    ) -> ClaudeOCREngine {
        let client = AnthropicAPIClient(
            config: AnthropicAPIClient.Config(maxRetries: 0),
            transport: transport,
            apiKeyProvider: { "sk-test" },
            sleeper: { _ in },
            rateLimiter: nil
        )
        return ClaudeOCREngine(client: client, budget: budget)
    }

    // MARK: - Tests

    func test_successful_call_returns_one_observation_with_claude_source() async throws {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: "δικαιοσύνη"))
        ])
        let engine = makeEngine(transport: mock)
        let result = try await engine.recognize(
            image: makeImage(),
            hints: OCRHints(languages: [.grc])
        )
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertEqual(result.observations[0].source, .claude)
        XCTAssertEqual(result.observations[0].text, "δικαιοσύνη")
        // Bbox is the full input image in normalized coords.
        XCTAssertEqual(result.observations[0].box, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func test_request_includes_base64_image_block() async throws {
        let mock = MockTransport(steps: [.init(status: 200, body: successBody(text: "ok"))])
        let engine = makeEngine(transport: mock)
        _ = try await engine.recognize(image: makeImage(), hints: OCRHints())

        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 1)
        let body = try JSONSerialization.jsonObject(
            with: sent[0].httpBody!
        ) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let userContent = messages[0]["content"] as! [[String: Any]]
        XCTAssertEqual(userContent.count, 2)
        XCTAssertEqual(userContent[0]["type"] as? String, "image")
        let source = userContent[0]["source"] as! [String: Any]
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertNotNil(source["data"] as? String)
        XCTAssertEqual(userContent[1]["type"] as? String, "text")
    }

    func test_request_carries_language_hint_in_user_turn() async throws {
        let mock = MockTransport(steps: [.init(status: 200, body: successBody(text: "ok"))])
        let engine = makeEngine(transport: mock)
        _ = try await engine.recognize(
            image: makeImage(),
            hints: OCRHints(languages: [.grc, .en])
        )
        let sent = await mock.sentRequests
        let body = try JSONSerialization.jsonObject(
            with: sent[0].httpBody!
        ) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let userContent = messages[0]["content"] as! [[String: Any]]
        let userText = userContent[1]["text"] as! String
        XCTAssertTrue(userText.contains("grc"))
        XCTAssertTrue(userText.contains("en"))
    }

    func test_thinking_is_disabled() async throws {
        let mock = MockTransport(steps: [.init(status: 200, body: successBody(text: "ok"))])
        let engine = makeEngine(transport: mock)
        _ = try await engine.recognize(image: makeImage(), hints: OCRHints())
        let sent = await mock.sentRequests
        let body = try JSONSerialization.jsonObject(
            with: sent[0].httpBody!
        ) as! [String: Any]
        let thinking = body["thinking"] as! [String: Any]
        XCTAssertEqual(thinking["type"] as? String, "disabled")
    }

    // MARK: - Budget enforcement

    func test_budget_exhausted_throws_before_network_call() async {
        let mock = MockTransport(steps: [])  // any call would hit "queue exhausted"
        let exhausted = CloudCallBudget(cap: 0)
        let engine = makeEngine(transport: mock, budget: exhausted)
        do {
            _ = try await engine.recognize(image: makeImage(), hints: OCRHints())
            XCTFail("Expected budget exhaustion to throw")
        } catch ClaudeOCREngine.ClaudeOCRError.budgetExhausted {
            // Expected. No network calls should have happened.
            let sent = await mock.sentRequests
            XCTAssertTrue(sent.isEmpty,
                          "Budget check should fire before network call")
        } catch {
            XCTFail("Expected .budgetExhausted, got \(error)")
        }
    }

    func test_budget_consumes_exactly_one_per_successful_call() async throws {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: "a")),
            .init(status: 200, body: successBody(text: "b")),
        ])
        let budget = CloudCallBudget(cap: 5)
        let engine = makeEngine(transport: mock, budget: budget)
        _ = try await engine.recognize(image: makeImage(), hints: OCRHints())
        _ = try await engine.recognize(image: makeImage(), hints: OCRHints())
        let consumed = await budget.consumed
        XCTAssertEqual(consumed, 2)
    }

    // MARK: - Refusal + empty handling

    func test_refusal_throws_emptyResponse() async {
        let mock = MockTransport(steps: [.init(status: 200, body: refusalBody())])
        let engine = makeEngine(transport: mock)
        do {
            _ = try await engine.recognize(image: makeImage(), hints: OCRHints())
            XCTFail("Expected refusal to surface as emptyResponse")
        } catch ClaudeOCREngine.ClaudeOCRError.emptyResponse {
            // Expected.
        } catch {
            XCTFail("Expected .emptyResponse, got \(error)")
        }
    }

    // MARK: - Underlying API errors

    func test_api_error_is_wrapped_as_underlying() async {
        let errorJSON = #"""
        {"type":"error","error":{"type":"authentication_error","message":"bad key"}}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 401, body: errorJSON)])
        let engine = makeEngine(transport: mock)
        do {
            _ = try await engine.recognize(image: makeImage(), hints: OCRHints())
            XCTFail("Expected authentication failure to throw")
        } catch ClaudeOCREngine.ClaudeOCRError.underlying(let inner) {
            guard let typed = inner as? AnthropicAPIError,
                  case .authenticationFailed = typed else {
                XCTFail("Expected wrapped .authenticationFailed, got \(inner)")
                return
            }
        } catch {
            XCTFail("Expected .underlying wrapping, got \(error)")
        }
    }
}
