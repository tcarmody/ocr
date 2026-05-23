import XCTest
import CoreGraphics
import AI
import Document
import OCR
@testable import Pipeline

/// `ClaudePostProcessor` tests — same `MockTransport` pattern as
/// `ClaudeOCREngineTests`. Verifies trigger gating, prompt shape,
/// guardrail integration, refusal handling, and budget bookkeeping.
final class ClaudePostProcessorTests: XCTestCase {

    // MARK: - Mock transport (same shape as ClaudeOCREngineTests)

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
                url: request.url!,
                statusCode: step.status,
                httpVersion: "HTTP/1.1",
                headerFields: step.headers
            )!
            return (step.body, response)
        }
    }

    // MARK: - Helpers

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
          "model": "claude-haiku-4-5",
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
          "model": "claude-haiku-4-5",
          "content": [{"type":"text","text":"I can't help with that."}],
          "stop_reason": "refusal",
          "usage": {"input_tokens": 50, "output_tokens": 10}
        }
        """#
        return json.data(using: .utf8)!
    }

    private func makeProcessor(
        transport: any AnthropicTransport,
        budget: CloudCallBudget = CloudCallBudget(cap: 10),
        triggerThreshold: Double = 0.6,
        minCharsToProcess: Int = 30
    ) -> ClaudePostProcessor {
        let client = AnthropicAPIClient(
            config: AnthropicAPIClient.Config(maxRetries: 0),
            transport: transport,
            apiKeyProvider: { "sk-test" },
            sleeper: { _ in },
            rateLimiter: nil
        )
        return ClaudePostProcessor(
            client: client,
            budget: budget,
            triggerThreshold: triggerThreshold,
            minCharsToProcess: minCharsToProcess
        )
    }

    /// Single-char-heavy gibberish — looks like the OCR over-split a
    /// region into glyph-by-glyph tokens. Score drops to ~0 because
    /// `singleCharRatio == 1.0`. Length is ≥ 30 chars so it clears
    /// `OCRChangeGuardrail.priorMinLengthForGuardrail` and meaningful
    /// guardrail checks run on the response.
    private let lowQualityText =
        "a b c d e f g h i j k l m n o p q r s t u v w x y z 1 2 3 4 5"

    /// Clean English prose — scores comfortably above 0.6.
    private let highQualityText = """
        This is a paragraph of clean English prose with several proper \
        words, normal punctuation, and a length sufficient to give the \
        language recognizer something solid to work with.
        """

    // MARK: - Trigger gate

    func test_short_text_below_minChars_is_skipped_without_api_call() async {
        let mock = MockTransport(steps: [])
        let p = makeProcessor(transport: mock, minCharsToProcess: 30)
        let result = await p.correct(text: "Short text.", languages: [.en])
        XCTAssertNil(result)
        let sent = await mock.sentRequests
        XCTAssertTrue(sent.isEmpty)
    }

    func test_clean_text_above_threshold_is_skipped_without_api_call() async {
        let mock = MockTransport(steps: [])
        let p = makeProcessor(transport: mock)
        let result = await p.correct(text: highQualityText, languages: [.en])
        XCTAssertNil(result)
        let sent = await mock.sentRequests
        XCTAssertTrue(sent.isEmpty,
                      "High-quality text should never reach the network")
    }

    func test_low_quality_text_below_threshold_triggers_api_call() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: lowQualityText))
        ])
        let p = makeProcessor(transport: mock)
        let result = await p.correct(text: lowQualityText, languages: [.en])
        XCTAssertNotNil(result)
        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 1)
    }

    // MARK: - Budget enforcement

    func test_budget_exhausted_returns_nil_without_api_call() async {
        let mock = MockTransport(steps: [])
        let exhausted = CloudCallBudget(cap: 0)
        let p = makeProcessor(transport: mock, budget: exhausted)
        let result = await p.correct(text: lowQualityText, languages: [.en])
        XCTAssertNil(result)
        let sent = await mock.sentRequests
        XCTAssertTrue(sent.isEmpty)
    }

    func test_budget_consumes_one_call_per_correction() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: lowQualityText))
        ])
        let budget = CloudCallBudget(cap: 5)
        let p = makeProcessor(transport: mock, budget: budget)
        _ = await p.correct(text: lowQualityText, languages: [.en])
        let consumed = await budget.consumed
        XCTAssertEqual(consumed, 1)
    }

    func test_budget_records_usage_per_model() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: lowQualityText))
        ])
        let budget = CloudCallBudget(cap: 5)
        let p = makeProcessor(transport: mock, budget: budget)
        _ = await p.correct(text: lowQualityText, languages: [.en])
        let usage = await budget.modelUsage[.haiku4_5]
        XCTAssertEqual(usage?.inputTokens, 100)
        XCTAssertEqual(usage?.outputTokens, 20)
    }

    // MARK: - Prompt shape

    func test_request_carries_language_hint_in_user_turn() async throws {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: lowQualityText))
        ])
        let p = makeProcessor(transport: mock)
        _ = await p.correct(text: lowQualityText, languages: [.grc, .la])
        let sent = await mock.sentRequests
        let body = try JSONSerialization.jsonObject(
            with: sent[0].httpBody!
        ) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        // User content is a plain string for passages mode, not blocks.
        let userText = messages[0]["content"] as! String
        XCTAssertTrue(userText.contains("grc"),
                      "User turn must carry the BCP-47 language code")
        XCTAssertTrue(userText.contains("la"))
        XCTAssertTrue(userText.contains("OCR text to correct"))
    }

    func test_request_uses_haiku_model_and_disables_thinking() async throws {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: lowQualityText))
        ])
        let p = makeProcessor(transport: mock)
        _ = await p.correct(text: lowQualityText, languages: [.en])
        let sent = await mock.sentRequests
        let body = try JSONSerialization.jsonObject(
            with: sent[0].httpBody!
        ) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5")
        let thinking = body["thinking"] as! [String: Any]
        XCTAssertEqual(thinking["type"] as? String, "disabled")
    }

    func test_system_prompt_constrains_to_character_corrections() async throws {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: lowQualityText))
        ])
        let p = makeProcessor(transport: mock)
        _ = await p.correct(text: lowQualityText, languages: [.en])
        let sent = await mock.sentRequests
        let body = try JSONSerialization.jsonObject(
            with: sent[0].httpBody!
        ) as! [String: Any]
        // The system field is now `[{type: "text", text: ..., cache_control: ...}]`
        // — `.cached(...)` was added in the E-Cache-Audit pass so the
        // prompt is auto-cached for prefix reuse across calls.
        let blocks = body["system"] as! [[String: Any]]
        XCTAssertEqual(blocks.count, 1)
        let system = blocks[0]["text"] as! String
        XCTAssertTrue(system.contains("OCR"))
        XCTAssertTrue(system.contains("ligature"),
                      "System prompt should describe the kinds of edits we want")
        XCTAssertTrue(system.contains("Do NOT"),
                      "System prompt must explicitly prohibit rewrites/translations")
        // Cache-control breakpoint must be present and ephemeral.
        let cc = blocks[0]["cache_control"] as! [String: Any]
        XCTAssertEqual(cc["type"] as? String, "ephemeral")
    }

    // MARK: - Guardrail integration

    func test_accepted_correction_returns_result_marked_accepted() async {
        // Original is gibberish (low score); response is the same
        // text — no script drift, no length blow-up. Guardrail accepts.
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: lowQualityText))
        ])
        let p = makeProcessor(transport: mock)
        let result = await p.correct(text: lowQualityText, languages: [.en])
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.accepted ?? false)
        XCTAssertNil(result?.rejectionReason)
    }

    func test_script_drift_rejected_and_original_returned() async {
        // Original is Latin gibberish; "correction" is Cyrillic — that's
        // a translation, not a transcription. Guardrail rejects.
        let cyrillic = "это полностью другое предложение совсем не похожее на оригинал текста"
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: cyrillic))
        ])
        let p = makeProcessor(transport: mock)
        let result = await p.correct(text: lowQualityText, languages: [.en])
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.accepted ?? true)
        XCTAssertEqual(result?.rejectionReason, .scriptDrift)
        // Caller-friendly: `corrected` carries the original on reject
        // so callers can use the result uniformly.
        XCTAssertEqual(
            result?.corrected,
            lowQualityText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func test_length_explosion_is_rejected() async {
        // Hallucinated expansion — model returned 5× the original length.
        let exploded = String(repeating: lowQualityText + " ", count: 6)
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: exploded))
        ])
        let p = makeProcessor(transport: mock)
        let result = await p.correct(text: lowQualityText, languages: [.en])
        XCTAssertEqual(result?.accepted, false)
        XCTAssertEqual(result?.rejectionReason, .lengthExplosion)
    }

    // MARK: - Refusal + parsing

    func test_refusal_returns_nil() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: refusalBody())
        ])
        let p = makeProcessor(transport: mock)
        let result = await p.correct(text: lowQualityText, languages: [.en])
        XCTAssertNil(result)
    }

    func test_empty_response_returns_nil() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: ""))
        ])
        let p = makeProcessor(transport: mock)
        let result = await p.correct(text: lowQualityText, languages: [.en])
        XCTAssertNil(result)
    }

    // MARK: - Vision mode

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

    func test_vision_mode_without_image_skips_without_api_call() async {
        let mock = MockTransport(steps: [])
        let p = makeProcessor(transport: mock)
        let result = await p.correct(
            text: lowQualityText,
            languages: [.en],
            mode: .vision,
            regionImage: nil
        )
        XCTAssertNil(result, "Vision mode should refuse without an image")
        let sent = await mock.sentRequests
        XCTAssertTrue(sent.isEmpty)
    }

    func test_vision_mode_request_includes_image_block() async throws {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: lowQualityText))
        ])
        let p = makeProcessor(transport: mock)
        _ = await p.correct(
            text: lowQualityText,
            languages: [.en],
            mode: .vision,
            regionImage: makeImage()
        )
        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 1)
        let body = try JSONSerialization.jsonObject(
            with: sent[0].httpBody!
        ) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        // Vision mode → content is an array of blocks, not a string.
        let userContent = messages[0]["content"] as! [[String: Any]]
        XCTAssertEqual(userContent.count, 2)
        XCTAssertEqual(userContent[0]["type"] as? String, "image")
        let source = userContent[0]["source"] as! [String: Any]
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertNotNil(source["data"] as? String)
        XCTAssertEqual(userContent[1]["type"] as? String, "text")
    }

    func test_passages_mode_request_uses_plain_string_content() async throws {
        // Default mode (.passages) keeps the lighter wire shape — a
        // plain string under content, not an array of blocks.
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: lowQualityText))
        ])
        let p = makeProcessor(transport: mock)
        _ = await p.correct(text: lowQualityText, languages: [.en])
        let sent = await mock.sentRequests
        let body = try JSONSerialization.jsonObject(
            with: sent[0].httpBody!
        ) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertTrue(messages[0]["content"] is String,
                      "Passages mode should send a string, not blocks")
    }

    // MARK: - Misc

    func test_code_fence_wrapped_response_is_unwrapped() {
        // Haiku occasionally wraps long passages in triple-backtick
        // fences despite the system prompt asking for plain text. The
        // parser should strip the outer fences.
        let fenced = "```\nsome corrected text\n```"
        XCTAssertEqual(
            ClaudePostProcessor.parseCorrectedText(from: fenced),
            "some corrected text"
        )
        let withLanguage = "```text\nstill the same body\n```"
        XCTAssertEqual(
            ClaudePostProcessor.parseCorrectedText(from: withLanguage),
            "still the same body"
        )
        // No fences → passes through trimmed.
        XCTAssertEqual(
            ClaudePostProcessor.parseCorrectedText(from: "  hello  "),
            "hello"
        )
        // Empty after stripping → nil.
        XCTAssertNil(
            ClaudePostProcessor.parseCorrectedText(from: "```\n\n```")
        )
    }
}
