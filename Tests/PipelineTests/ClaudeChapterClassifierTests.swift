import XCTest
import AI
import Document
@testable import Pipeline

/// `ClaudeChapterClassifier` tests — pure helpers (normalize,
/// makeContext, openingText) plus a few prompt-shape assertions
/// against a mocked transport.
final class ClaudeChapterClassifierTests: XCTestCase {

    // MARK: - Mock transport (same shape as ClaudePostProcessorTests)

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

    private func successBody(text: String) -> Data {
        let json = #"""
        {
          "id": "msg_test",
          "type": "message",
          "role": "assistant",
          "model": "claude-haiku-4-5",
          "content": [{"type":"text","text":"\#(text)"}],
          "stop_reason": "end_turn",
          "usage": {"input_tokens": 200, "output_tokens": 5}
        }
        """#
        return json.data(using: .utf8)!
    }

    private func makeClassifier(
        transport: any AnthropicTransport,
        budget: CloudCallBudget = CloudCallBudget(cap: 10)
    ) -> ClaudeChapterClassifier {
        let client = AnthropicAPIClient(
            config: AnthropicAPIClient.Config(maxRetries: 0),
            transport: transport,
            apiKeyProvider: { "sk-test" },
            sleeper: { _ in },
            rateLimiter: nil
        )
        return ClaudeChapterClassifier(client: client, budget: budget)
    }

    // MARK: - normalize

    func test_normalize_accepts_clean_label() {
        XCTAssertEqual(ClaudeChapterClassifier.normalize("chapter"), "chapter")
        XCTAssertEqual(ClaudeChapterClassifier.normalize("bibliography"), "bibliography")
    }

    func test_normalize_strips_whitespace_and_punctuation() {
        XCTAssertEqual(ClaudeChapterClassifier.normalize("  chapter.\n"), "chapter")
        XCTAssertEqual(ClaudeChapterClassifier.normalize("\"chapter\""), "chapter")
    }

    func test_normalize_lowercases() {
        XCTAssertEqual(ClaudeChapterClassifier.normalize("Bibliography"), "bibliography")
        XCTAssertEqual(ClaudeChapterClassifier.normalize("CHAPTER"), "chapter")
    }

    func test_normalize_rejects_unknown_label() {
        // The closed label set excludes "body", "summary", "chap"
        // — those should fall through as nil rather than guess.
        XCTAssertNil(ClaudeChapterClassifier.normalize("body"))
        XCTAssertNil(ClaudeChapterClassifier.normalize("summary"))
        XCTAssertNil(ClaudeChapterClassifier.normalize("chap"))
        XCTAssertNil(ClaudeChapterClassifier.normalize(""))
    }

    // MARK: - openingText

    func test_openingText_collects_until_max() {
        let chapter = Chapter(
            title: "Body",
            blocks: [
                .heading(level: 1, runs: [InlineRun("The Beginning")]),
                .paragraph(runs: [InlineRun("Once upon a time there was a small printer.")]),
                .paragraph(runs: [InlineRun("It produced books all day long.")]),
            ]
        )
        let opening = ClaudeChapterClassifier.openingText(of: chapter, maxChars: 50)
        XCTAssertLessThanOrEqual(opening.count, 50)
        XCTAssertTrue(opening.hasPrefix("The Beginning"))
    }

    func test_openingText_skips_non_text_blocks() {
        // Figure / table / anchor blocks contribute no text — the
        // collected output should jump straight to the paragraphs.
        let chapter = Chapter(
            title: nil,
            blocks: [
                .anchor(id: "hu-page-0", label: "Page 1"),
                .figure(assetId: "fig-001", alt: "Figure 1", caption: []),
                .paragraph(runs: [InlineRun("Real text.")]),
            ]
        )
        XCTAssertEqual(
            ClaudeChapterClassifier.openingText(of: chapter, maxChars: 100),
            "Real text."
        )
    }

    // MARK: - makeContext

    func test_makeContext_includes_title_and_opening() {
        let chapter = Chapter(
            title: "Acknowledgments",
            blocks: [.paragraph(runs: [InlineRun("Many thanks to all contributors.")])]
        )
        let context = ClaudeChapterClassifier.makeContext(from: chapter)
        XCTAssertTrue(context.contains("Acknowledgments"))
        XCTAssertTrue(context.contains("Many thanks"))
    }

    func test_makeContext_handles_missing_title() {
        let chapter = Chapter(
            title: nil,
            blocks: [.paragraph(runs: [InlineRun("Body text.")])]
        )
        let context = ClaudeChapterClassifier.makeContext(from: chapter)
        XCTAssertTrue(context.contains("(none)"))
        XCTAssertTrue(context.contains("Body text."))
    }

    // MARK: - classify (live mocked)

    func test_classify_returns_label_on_clean_response() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: "appendix"))
        ])
        let classifier = makeClassifier(transport: mock)
        let chapter = Chapter(
            title: "Appendix A: Source Notes",
            blocks: [.paragraph(runs: [InlineRun("This appendix lists primary sources.")])]
        )
        let label = await classifier.classify(chapter: chapter)
        XCTAssertEqual(label, "appendix")
    }

    func test_classify_handles_punctuated_response() async {
        // Even when the system prompt forbids punctuation, the model
        // sometimes emits "chapter." The classifier normalizes before
        // validating.
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: "Chapter."))
        ])
        let classifier = makeClassifier(transport: mock)
        let label = await classifier.classify(
            chapter: Chapter(title: "1. The Origins")
        )
        XCTAssertEqual(label, "chapter")
    }

    func test_classify_returns_nil_for_unknown_label() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: "main_text"))
        ])
        let classifier = makeClassifier(transport: mock)
        let label = await classifier.classify(
            chapter: Chapter(title: "Body")
        )
        XCTAssertNil(label, "Unknown labels should not be guessed")
    }

    func test_classify_consumes_one_budget_call() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(text: "chapter"))
        ])
        let budget = CloudCallBudget(cap: 5)
        let classifier = makeClassifier(transport: mock, budget: budget)
        _ = await classifier.classify(chapter: Chapter(title: "Test"))
        let consumed = await budget.consumed
        XCTAssertEqual(consumed, 1)
    }

    func test_classify_returns_nil_when_budget_exhausted() async {
        let mock = MockTransport(steps: [])
        let exhausted = CloudCallBudget(cap: 0)
        let classifier = makeClassifier(transport: mock, budget: exhausted)
        let label = await classifier.classify(chapter: Chapter(title: "Test"))
        XCTAssertNil(label)
        let sent = await mock.sentRequests
        XCTAssertTrue(sent.isEmpty)
    }
}
