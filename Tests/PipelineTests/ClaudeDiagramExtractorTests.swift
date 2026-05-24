import XCTest
import CoreGraphics
import AI
import Document
import OCR
@testable import Pipeline

/// `ClaudeDiagramExtractor` (P-Diagram-Description Tier 1): pure
/// sanitize + parse logic + end-to-end mock-transport paths covering
/// success, refusal, caption-aware prompt, and the preamble-strip
/// heuristic. Mirrors `ClaudeMathExtractorTests` so the MockTransport
/// pattern is reused.
final class ClaudeDiagramExtractorTests: XCTestCase {

    // MARK: - Mock transport (mirrors ClaudeMathExtractorTests)

    actor MockTransport: AnthropicTransport {
        struct Step {
            var status: Int
            var body: Data
        }
        private var queue: [Step]
        private(set) var sentRequests: [URLRequest] = []
        private(set) var sentBodies: [Data] = []

        init(steps: [Step]) { self.queue = steps }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            sentRequests.append(request)
            if let body = request.httpBody {
                sentBodies.append(body)
            }
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
          "usage": {"input_tokens": 1500, "output_tokens": 30}
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
          "content": [{"type":"text","text":"I cannot describe this image."}],
          "stop_reason": "refusal",
          "usage": {"input_tokens": 100, "output_tokens": 8}
        }
        """#
        return json.data(using: .utf8)!
    }

    private func runExtract(
        transport: any AnthropicTransport,
        budget: CloudCallBudget = CloudCallBudget(cap: 10),
        captionText: String? = nil
    ) async -> DiagramExtractionResult? {
        let client = AnthropicAPIClient(
            config: AnthropicAPIClient.Config(maxRetries: 0),
            transport: transport,
            apiKeyProvider: { "sk-test" },
            sleeper: { _ in },
            rateLimiter: nil
        )
        let extractor = ClaudeDiagramExtractor(client: client, budget: budget)
        // P-Diagram-Description Option B refactor: the extractor
        // now takes the pre-cropped figure image directly — the
        // post-cascade phase feeds it the bytes that
        // `FigureExtractor` already produced, decoded back to a
        // CGImage.
        return await extractor.extract(
            figureImage: makeImage(),
            captionText: captionText,
            languages: [BCP47("en")],
            pageIndex: 0,
            regionIndex: 0
        )
    }

    // MARK: - parseResponse (pure)

    func test_parse_returns_alt_text_for_plain_response() {
        let raw = "Marriage market supply-demand chart with population on x-axis"
        let result = ClaudeDiagramExtractor.parseResponse(raw)
        XCTAssertEqual(result?.altText, raw)
    }

    func test_parse_returns_nil_for_empty_response() {
        XCTAssertNil(ClaudeDiagramExtractor.parseResponse(""))
        XCTAssertNil(ClaudeDiagramExtractor.parseResponse("   \n  "))
    }

    func test_parse_returns_nil_for_refusal_prefixes() {
        // The model is supposed to return empty when it can't
        // describe the image; defensive guard catches the cases
        // where it slips in a refusal phrase instead.
        XCTAssertNil(
            ClaudeDiagramExtractor.parseResponse("I cannot describe this image")
        )
        XCTAssertNil(
            ClaudeDiagramExtractor.parseResponse("Sorry, the image is unclear")
        )
        XCTAssertNil(
            ClaudeDiagramExtractor.parseResponse("Unable to determine subject")
        )
    }

    func test_parse_strips_common_preambles() {
        // The system prompt forbids "This image shows…" / "The
        // figure depicts…" preambles, but models occasionally
        // emit them anyway. Strip + recapitalize.
        XCTAssertEqual(
            ClaudeDiagramExtractor.parseResponse(
                "This image shows a bar chart of marriage rates"
            )?.altText,
            "A bar chart of marriage rates"
        )
        XCTAssertEqual(
            ClaudeDiagramExtractor.parseResponse(
                "The figure depicts a scatter plot"
            )?.altText,
            "A scatter plot"
        )
    }

    func test_parse_strips_outer_code_fence() {
        let raw = """
            ```
            Bar chart with two categories
            ```
            """
        XCTAssertEqual(
            ClaudeDiagramExtractor.parseResponse(raw)?.altText,
            "Bar chart with two categories"
        )
    }

    func test_parse_caps_long_alt_text_at_120_chars() {
        // Defensive cap so a runaway response doesn't produce
        // multi-sentence alt text that screen readers churn
        // through.
        let long = String(repeating: "A", count: 200)
        let result = ClaudeDiagramExtractor.parseResponse(long)
        XCTAssertEqual(result?.altText.count, 118)  // 117 + ellipsis
        XCTAssertTrue(result?.altText.hasSuffix("…") ?? false)
    }

    // MARK: - Tier 2 (description)

    func test_parse_returns_both_alt_and_description_when_separator_present() {
        let raw = """
            Bar chart of marriage rates
            ---DESCRIPTION---
            A vertical bar chart with five categories on the x-axis labeled 1950 through 1990, showing marriage rates per 1000 population declining from ~22 to ~10.
            """
        let result = ClaudeDiagramExtractor.parseResponse(raw)
        XCTAssertEqual(result?.altText, "Bar chart of marriage rates")
        XCTAssertNotNil(result?.description)
        XCTAssertTrue(result?.description?.contains("five categories") ?? false)
    }

    func test_parse_tolerates_separator_without_surrounding_newlines() {
        let raw = "Scatter plot of wages---DESCRIPTION---Two-axis scatter with male and female populations."
        let result = ClaudeDiagramExtractor.parseResponse(raw)
        XCTAssertEqual(result?.altText, "Scatter plot of wages")
        XCTAssertEqual(
            result?.description,
            "Two-axis scatter with male and female populations."
        )
    }

    func test_parse_alt_only_when_separator_absent() {
        // Defensive: a response without the Tier-2 separator
        // (older prompt cache, partial response) still surfaces
        // alt text. Description stays nil; XHTML writer just
        // doesn't emit an aside.
        let raw = "Photograph of a stone arch"
        let result = ClaudeDiagramExtractor.parseResponse(raw)
        XCTAssertEqual(result?.altText, "Photograph of a stone arch")
        XCTAssertNil(result?.description)
    }

    func test_parse_caps_long_description_at_500_chars() {
        let raw = "Chart\n---DESCRIPTION---\n" + String(repeating: "B", count: 700)
        let result = ClaudeDiagramExtractor.parseResponse(raw)
        XCTAssertEqual(result?.description?.count, 498)  // 497 + ellipsis
        XCTAssertTrue(result?.description?.hasSuffix("…") ?? false)
    }

    func test_parse_description_strips_preamble() {
        let raw = """
            Bar chart
            ---DESCRIPTION---
            This figure depicts a bar chart with five categories.
            """
        let result = ClaudeDiagramExtractor.parseResponse(raw)
        XCTAssertEqual(
            result?.description,
            "A bar chart with five categories."
        )
    }

    // MARK: - Tier 3 (labels)

    func test_parse_extracts_labels_with_bullet_prefix() {
        let raw = """
            Anatomical illustration of human heart
            ---DESCRIPTION---
            A cross-section view showing the four chambers and major vessels.
            ---LABELS---
            - left atrium
            - right atrium
            - aorta
            - pulmonary artery
            """
        let result = ClaudeDiagramExtractor.parseResponse(raw)
        XCTAssertEqual(result?.labels, [
            "left atrium", "right atrium", "aorta", "pulmonary artery"
        ])
    }

    func test_parse_extracts_labels_without_bullet() {
        // Defensive: model might forget the bullet prefix.
        let raw = """
            Bar chart
            ---DESCRIPTION---
            Two-axis chart.
            ---LABELS---
            x-axis
            y-axis
            origin
            """
        let result = ClaudeDiagramExtractor.parseResponse(raw)
        XCTAssertEqual(result?.labels, ["x-axis", "y-axis", "origin"])
    }

    func test_parse_drops_blank_and_overlong_label_lines() {
        // Empty lines and lines >80 chars get filtered — runaway
        // content is more likely a parse artifact than a real
        // label.
        let raw = """
            Chart
            ---DESCRIPTION---
            Desc.
            ---LABELS---
            - good label

            - \(String(repeating: "X", count: 100))
            - another good one
            """
        let result = ClaudeDiagramExtractor.parseResponse(raw)
        XCTAssertEqual(result?.labels, ["good label", "another good one"])
    }

    func test_parse_caps_label_count_at_12() {
        var rawLines: [String] = ["Chart", "---DESCRIPTION---", "Desc.", "---LABELS---"]
        for i in 1...20 { rawLines.append("- label \(i)") }
        let raw = rawLines.joined(separator: "\n")
        let result = ClaudeDiagramExtractor.parseResponse(raw)
        XCTAssertEqual(result?.labels.count, 12)
    }

    func test_parse_handles_empty_labels_section() {
        // Diagram with no visible in-image text — labels section
        // is empty (just the separator with nothing after).
        let raw = """
            Photograph of a stone arch
            ---DESCRIPTION---
            A weathered limestone arch in a desert landscape.
            ---LABELS---
            """
        let result = ClaudeDiagramExtractor.parseResponse(raw)
        XCTAssertTrue(result?.labels.isEmpty ?? false)
        XCTAssertNotNil(result?.description)
    }

    func test_parse_no_labels_separator_returns_empty_labels() {
        // Backwards compat with a Tier-2-only cached response.
        let raw = """
            Bar chart
            ---DESCRIPTION---
            Two-axis chart with five categories.
            """
        let result = ClaudeDiagramExtractor.parseResponse(raw)
        XCTAssertTrue(result?.labels.isEmpty ?? false)
        XCTAssertNotNil(result?.description)
    }

    // MARK: - End-to-end with mock transport

    func test_extract_returns_alt_text_on_success() async {
        let transport = MockTransport(steps: [
            .init(status: 200, body: successBody(
                text: "Anatomical illustration of human heart with chamber labels"
            )),
        ])
        let result = await runExtract(transport: transport)
        XCTAssertEqual(
            result?.altText,
            "Anatomical illustration of human heart with chamber labels"
        )
        XCTAssertNil(result?.description)
        XCTAssertTrue(result?.labels.isEmpty ?? true)
    }

    func test_extract_returns_nil_on_refusal() async {
        let transport = MockTransport(steps: [
            .init(status: 200, body: refusalBody()),
        ])
        let result = await runExtract(transport: transport)
        XCTAssertNil(result)
    }

    func test_extract_returns_nil_on_empty_response() async {
        let transport = MockTransport(steps: [
            .init(status: 200, body: successBody(text: "")),
        ])
        let result = await runExtract(transport: transport)
        XCTAssertNil(result)
    }

    func test_extract_returns_nil_when_budget_exhausted() async {
        let transport = MockTransport(steps: [])
        let result = await runExtract(
            transport: transport,
            budget: CloudCallBudget(cap: 0)
        )
        XCTAssertNil(result)
        let sent = await transport.sentRequests
        XCTAssertEqual(sent.count, 0)
    }

    // MARK: - Caption-aware prompt

    func test_caption_text_is_passed_in_user_turn_when_provided() async {
        // The caption text needs to reach the model so its
        // output stays consistent with the printed caption.
        let transport = MockTransport(steps: [
            .init(status: 200, body: successBody(text: "Bar chart of X")),
        ])
        _ = await runExtract(
            transport: transport,
            captionText: "Figure 3.1: Marriage market dynamics"
        )
        let bodies = await transport.sentBodies
        XCTAssertEqual(bodies.count, 1)
        let bodyText = String(data: bodies[0], encoding: .utf8) ?? ""
        XCTAssertTrue(bodyText.contains("Marriage market dynamics"),
            "expected caption text in request body; got:\n\(bodyText)")
    }

    func test_caption_text_absent_from_user_turn_when_nil() async {
        // Defensive: empty / nil captionText shouldn't insert
        // a "Printed caption:" header at all (the model would
        // treat that as a real but blank caption).
        let transport = MockTransport(steps: [
            .init(status: 200, body: successBody(text: "Bar chart")),
        ])
        _ = await runExtract(
            transport: transport, captionText: nil
        )
        let bodies = await transport.sentBodies
        let bodyText = String(data: bodies[0], encoding: .utf8) ?? ""
        XCTAssertFalse(bodyText.contains("Printed caption:"),
            "no caption header should appear when caption is nil")
    }
}
