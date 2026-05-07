import XCTest
import CoreGraphics
import AI
import Document
import OCR
@testable import Pipeline

/// `ClaudeTableExtractor` against a mocked `AnthropicTransport`.
/// Covers the JSON-grid parser, the wire shape (image + prompt),
/// budget enforcement, and the degenerate-output / refusal paths
/// that drive fallback to the Surya / heuristic extractors.
final class ClaudeTableExtractorTests: XCTestCase {

    // MARK: - Mock transport

    actor MockTransport: AnthropicTransport {
        struct Step {
            var status: Int
            var body: Data
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
                httpVersion: "HTTP/1.1", headerFields: [:]
            )!
            return (step.body, response)
        }
    }

    // MARK: - Helpers

    private func makeImage(width: Int = 200, height: Int = 100) -> CGImage {
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
          "usage": {"input_tokens": 1500, "output_tokens": 600}
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
          "content": [{"type":"text","text":"I cannot help with that."}],
          "stop_reason": "refusal",
          "usage": {"input_tokens": 100, "output_tokens": 8}
        }
        """#
        return json.data(using: .utf8)!
    }

    private func makeExtractor(
        transport: any AnthropicTransport,
        budget: ClaudeCallBudget = ClaudeCallBudget(cap: 10)
    ) -> ClaudeTableExtractor {
        let client = AnthropicAPIClient(
            config: AnthropicAPIClient.Config(maxRetries: 0),
            transport: transport,
            apiKeyProvider: { "sk-test" },
            sleeper: { _ in }
        )
        return ClaudeTableExtractor(client: client, budget: budget)
    }

    /// Runs `extract` against a region that fills most of the page
    /// (so the crop succeeds) and returns the rows + the captured
    /// network requests.
    private func runExtract(
        transport: any AnthropicTransport,
        budget: ClaudeCallBudget = ClaudeCallBudget(cap: 10),
        stagingDir: URL? = nil
    ) async -> [[TableCell]]? {
        let extractor = makeExtractor(transport: transport, budget: budget)
        let dir = stagingDir ?? FileManager.default.temporaryDirectory
        return await extractor.extract(
            pageImage: makeImage(),
            regionBox: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6),
            observations: [],
            stagingDir: dir,
            pageIndex: 0,
            regionIndex: 0
        )
    }

    // MARK: - parseRows (pure)

    func test_parseRows_decodes_basic_grid() {
        let raw = #"""
        {"rows":[
          [{"text":"Author","header":true,"rowspan":1,"colspan":1},
           {"text":"Year","header":true,"rowspan":1,"colspan":1}],
          [{"text":"Foucault","header":false,"rowspan":1,"colspan":1},
           {"text":"1971","header":false,"rowspan":1,"colspan":1}]
        ]}
        """#
        let rows = ClaudeTableExtractor.parseRows(from: raw)
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?[0].count, 2)
        XCTAssertEqual(rows?[0][0].isHeader, true)
        XCTAssertEqual(rows?[0][0].runs.first?.text, "Author")
        XCTAssertEqual(rows?[1][0].isHeader, false)
        XCTAssertEqual(rows?[1][1].runs.first?.text, "1971")
    }

    func test_parseRows_defaults_optional_fields() {
        // header / rowspan / colspan are optional in the JSON;
        // omitting them should default to false / 1 / 1.
        let raw = #"""
        {"rows":[
          [{"text":"a"},{"text":"b"}],
          [{"text":"c"},{"text":"d"}]
        ]}
        """#
        let rows = ClaudeTableExtractor.parseRows(from: raw)
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?[0][0].isHeader, false)
        XCTAssertEqual(rows?[0][0].rowspan, 1)
        XCTAssertEqual(rows?[0][0].colspan, 1)
    }

    func test_parseRows_preserves_merged_cell_spans() {
        let raw = #"""
        {"rows":[
          [{"text":"Header","header":true,"colspan":2}],
          [{"text":"a"},{"text":"b"}]
        ]}
        """#
        let rows = ClaudeTableExtractor.parseRows(from: raw)
        XCTAssertEqual(rows?[0].count, 1)
        XCTAssertEqual(rows?[0][0].colspan, 2)
        XCTAssertEqual(rows?[1].count, 2)
    }

    func test_parseRows_strips_code_fence() {
        let raw = """
            ```json
            {"rows":[[{"text":"a"},{"text":"b"}],[{"text":"c"},{"text":"d"}]]}
            ```
            """
        let rows = ClaudeTableExtractor.parseRows(from: raw)
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?[0][0].runs.first?.text, "a")
    }

    func test_parseRows_returns_nil_for_empty_rows() {
        // The prompt instructs the model to return `{"rows":[]}`
        // when the image isn't a table — caller falls back.
        let raw = #"{"rows":[]}"#
        XCTAssertNil(ClaudeTableExtractor.parseRows(from: raw))
    }

    func test_parseRows_returns_nil_for_malformed_json() {
        XCTAssertNil(ClaudeTableExtractor.parseRows(from: "not json"))
        XCTAssertNil(ClaudeTableExtractor.parseRows(from: "{}"))
        XCTAssertNil(ClaudeTableExtractor.parseRows(from: ""))
    }

    func test_parseRows_clamps_negative_or_zero_spans_to_one() {
        // A misbehaving model could return rowspan/colspan ≤ 0;
        // the parser clamps to 1 rather than emitting bad HTML.
        let raw = #"""
        {"rows":[
          [{"text":"a","rowspan":0,"colspan":-1},{"text":"b"}],
          [{"text":"c"},{"text":"d"}]
        ]}
        """#
        let rows = ClaudeTableExtractor.parseRows(from: raw)
        XCTAssertEqual(rows?[0][0].rowspan, 1)
        XCTAssertEqual(rows?[0][0].colspan, 1)
    }

    // MARK: - extract (live mocked)

    /// JSON the model would return as the `text` field in its
    /// response. Plain Swift string with literal `"` so
    /// `successBody`'s `\"` escaping produces the right wire shape;
    /// raw strings with `\"` would double-escape and break the
    /// inner JSON parse.
    private static let basicGridJSON =
        "{\"rows\":[[{\"text\":\"a\"},{\"text\":\"b\"}],[{\"text\":\"c\"},{\"text\":\"d\"}]]}"

    func test_extract_returns_grid_on_clean_response() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: Self.basicGridJSON))
        ])
        let rows = await runExtract(transport: mock)
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?[0][0].runs.first?.text, "a")
        XCTAssertEqual(rows?[1][1].runs.first?.text, "d")
    }

    func test_extract_returns_nil_on_below_floor_grid() async {
        // 1×1 grid is below the 2×2 floor that the heuristic + Surya
        // path also enforce; caller falls back rather than emit a
        // degenerate <table>.
        let raw = "{\"rows\":[[{\"text\":\"only\"}]]}"
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: raw))
        ])
        let rows = await runExtract(transport: mock)
        XCTAssertNil(rows)
    }

    func test_extract_returns_nil_on_refusal() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: refusalBody())
        ])
        let rows = await runExtract(transport: mock)
        XCTAssertNil(rows)
    }

    func test_extract_returns_nil_on_api_error() async {
        let errorJSON = #"""
        {"type":"error","error":{"type":"authentication_error","message":"bad key"}}
        """#.data(using: .utf8)!
        let mock = MockTransport(steps: [.init(status: 401, body: errorJSON)])
        let rows = await runExtract(transport: mock)
        XCTAssertNil(rows)
    }

    // MARK: - Wire shape

    func test_request_includes_base64_image_block() async throws {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: Self.basicGridJSON))
        ])
        _ = await runExtract(transport: mock)
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

    func test_thinking_is_disabled() async throws {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: Self.basicGridJSON))
        ])
        _ = await runExtract(transport: mock)
        let sent = await mock.sentRequests
        let body = try JSONSerialization.jsonObject(
            with: sent[0].httpBody!
        ) as! [String: Any]
        let thinking = body["thinking"] as! [String: Any]
        XCTAssertEqual(thinking["type"] as? String, "disabled")
    }

    // MARK: - Budget enforcement

    func test_extract_consumes_one_budget_call_on_success() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: Self.basicGridJSON))
        ])
        let budget = ClaudeCallBudget(cap: 5)
        _ = await runExtract(transport: mock, budget: budget)
        let consumed = await budget.consumed
        XCTAssertEqual(consumed, 1)
    }

    func test_extract_returns_nil_when_budget_exhausted() async {
        let mock = MockTransport(steps: [])  // any call would error
        let exhausted = ClaudeCallBudget(cap: 0)
        let rows = await runExtract(transport: mock, budget: exhausted)
        XCTAssertNil(rows)
        let sent = await mock.sentRequests
        XCTAssertTrue(sent.isEmpty,
                      "Budget check should fire before network call")
    }
}
