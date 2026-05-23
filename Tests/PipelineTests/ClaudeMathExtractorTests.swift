import XCTest
import CoreGraphics
import AI
@testable import Pipeline

/// `ClaudeMathExtractor` (P-Math-Cascade): pure sanitize logic +
/// end-to-end mock-transport paths covering success, refusal, and
/// non-math response fallback. Mirrors `ClaudeTableExtractorTests`
/// so the same MockTransport + body helpers are reused.
final class ClaudeMathExtractorTests: XCTestCase {

    // MARK: - Mock transport (mirrors ClaudeTableExtractorTests)

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

    private func runExtract(
        transport: any AnthropicTransport,
        budget: CloudCallBudget = CloudCallBudget(cap: 10)
    ) async -> String? {
        let client = AnthropicAPIClient(
            config: AnthropicAPIClient.Config(maxRetries: 0),
            transport: transport,
            apiKeyProvider: { "sk-test" },
            sleeper: { _ in },
            rateLimiter: nil
        )
        let extractor = ClaudeMathExtractor(client: client, budget: budget)
        return await extractor.extract(
            pageImage: makeImage(),
            regionBox: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6),
            stagingDir: FileManager.default.temporaryDirectory,
            pageIndex: 0,
            regionIndex: 0
        )
    }

    // MARK: - sanitizeMathML (pure)

    func test_sanitize_returns_input_when_already_starts_with_math_tag() {
        let raw = "<math display=\"block\" xmlns=\"http://www.w3.org/1998/Math/MathML\"><mi>x</mi></math>"
        XCTAssertEqual(ClaudeMathExtractor.sanitizeMathML(raw), raw)
    }

    func test_sanitize_strips_outer_code_fence() {
        let raw = """
            ```xml
            <math xmlns="http://www.w3.org/1998/Math/MathML"><mi>y</mi></math>
            ```
            """
        let cleaned = ClaudeMathExtractor.sanitizeMathML(raw)
        XCTAssertEqual(
            cleaned,
            "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mi>y</mi></math>"
        )
    }

    func test_sanitize_returns_nil_for_empty_response() {
        XCTAssertNil(ClaudeMathExtractor.sanitizeMathML(""))
        XCTAssertNil(ClaudeMathExtractor.sanitizeMathML("   \n  "))
    }

    func test_sanitize_returns_nil_for_non_math_prose() {
        // The system prompt instructs the model to return "" when
        // the image isn't a formula; defensively the sanitizer
        // also rejects any stray prose that didn't start with
        // <math, so a chatty refusal-style "Sorry, that's not a
        // formula" doesn't pollute the chapter XHTML.
        XCTAssertNil(
            ClaudeMathExtractor.sanitizeMathML("Sorry, that's not a formula.")
        )
    }

    func test_sanitize_returns_nil_for_html_lookalike_without_math_prefix() {
        // Defensive: even if the model wraps the math in a span,
        // we reject because the chapter writer would emit the
        // raw markup verbatim and a `<span>` (or any non-`<math>`
        // root) could break the chapter's XHTML well-formedness.
        XCTAssertNil(
            ClaudeMathExtractor.sanitizeMathML(
                "<span class=\"math\"><math><mi>z</mi></math></span>"
            )
        )
    }

    // MARK: - End-to-end with mock transport

    func test_extract_returns_mathml_on_success() async {
        let mathML = "<math display=\"block\" xmlns=\"http://www.w3.org/1998/Math/MathML\"><mrow><mi>E</mi><mo>=</mo><mi>m</mi><msup><mi>c</mi><mn>2</mn></msup></mrow></math>"
        let transport = MockTransport(steps: [
            .init(status: 200, body: successBody(text: mathML)),
        ])
        let result = await runExtract(transport: transport)
        XCTAssertEqual(result, mathML)
    }

    func test_extract_returns_nil_on_refusal() async {
        let transport = MockTransport(steps: [
            .init(status: 200, body: refusalBody()),
        ])
        let result = await runExtract(transport: transport)
        XCTAssertNil(result)
    }

    func test_extract_returns_nil_when_model_returns_empty() async {
        // Per the system prompt, the model returns the empty
        // string when the image isn't a formula. The caller
        // treats nil/empty as "fall back to the raster figure".
        let transport = MockTransport(steps: [
            .init(status: 200, body: successBody(text: "")),
        ])
        let result = await runExtract(transport: transport)
        XCTAssertNil(result)
    }

    func test_extract_returns_nil_when_response_is_not_mathml() async {
        // Defensive: a chatty model reply that ignores the
        // structural instructions doesn't pollute the chapter.
        let transport = MockTransport(steps: [
            .init(status: 200, body: successBody(
                text: "I see a quadratic formula but cannot transcribe it."
            )),
        ])
        let result = await runExtract(transport: transport)
        XCTAssertNil(result)
    }

    func test_extract_returns_nil_when_budget_exhausted() async {
        // budget cap 0 means no calls available — extractor
        // bails before any network request.
        let transport = MockTransport(steps: [])
        let result = await runExtract(
            transport: transport,
            budget: CloudCallBudget(cap: 0)
        )
        XCTAssertNil(result)
        let sent = await transport.sentRequests
        XCTAssertEqual(sent.count, 0)
    }
}
