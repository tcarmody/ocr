import XCTest
import AI
import Document
@testable import Pipeline

final class ClaudeMetadataExtractorTests: XCTestCase {

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

    private func successBody(jsonText: String) -> Data {
        // Embed `jsonText` as the model's text response — escape
        // the inner JSON's quotes for the outer JSON.
        let escaped = jsonText
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
          "usage": {"input_tokens": 200, "output_tokens": 80}
        }
        """#
        return json.data(using: .utf8)!
    }

    private func makeExtractor(
        transport: any AnthropicTransport,
        budget: ClaudeCallBudget = ClaudeCallBudget(cap: 5)
    ) -> ClaudeMetadataExtractor {
        let client = AnthropicAPIClient(
            config: AnthropicAPIClient.Config(maxRetries: 0),
            transport: transport,
            apiKeyProvider: { "sk-test" },
            sleeper: { _ in }
        )
        return ClaudeMetadataExtractor(client: client, budget: budget)
    }

    // MARK: - parse

    func test_parse_decodes_full_json() {
        let raw = """
            {"title":"The Origin of Species","author":"Charles Darwin","year":"1859","publisher":"John Murray","isbn":"978-0140439120"}
            """
        let r = ClaudeMetadataExtractor.parse(raw)
        XCTAssertEqual(r?.title, "The Origin of Species")
        XCTAssertEqual(r?.author, "Charles Darwin")
        XCTAssertEqual(r?.year, "1859")
        XCTAssertEqual(r?.publisher, "John Murray")
        XCTAssertEqual(r?.isbn, "9780140439120")
    }

    func test_parse_returns_nil_for_all_null_fields() {
        let raw = #"{"title":null,"author":null,"year":null,"publisher":null,"isbn":null}"#
        XCTAssertNil(ClaudeMetadataExtractor.parse(raw))
    }

    func test_parse_strips_code_fence() {
        let raw = """
            ```json
            {"title":"X","author":"Y","year":"2000","publisher":null,"isbn":null}
            ```
            """
        let r = ClaudeMetadataExtractor.parse(raw)
        XCTAssertEqual(r?.title, "X")
        XCTAssertEqual(r?.year, "2000")
    }

    func test_parse_returns_nil_for_malformed_json() {
        XCTAssertNil(ClaudeMetadataExtractor.parse("not json"))
        XCTAssertNil(ClaudeMetadataExtractor.parse(""))
    }

    func test_parse_normalizes_empty_strings_to_nil() {
        let raw = #"{"title":"  ","author":"","year":null,"publisher":null,"isbn":null}"#
        // Title whitespace, author empty, all else null → result is nil
        // (no fields survive normalization).
        XCTAssertNil(ClaudeMetadataExtractor.parse(raw))
    }

    // MARK: - normalizeYear

    func test_normalizeYear_extracts_4_digit_year() {
        XCTAssertEqual(ClaudeMetadataExtractor.normalizeYear("2003"), "2003")
        XCTAssertEqual(ClaudeMetadataExtractor.normalizeYear("© 2003"), "2003")
        XCTAssertEqual(ClaudeMetadataExtractor.normalizeYear("first published 2003 by"), "2003")
        XCTAssertEqual(ClaudeMetadataExtractor.normalizeYear("MMIII (2003)"), "2003")
    }

    func test_normalizeYear_returns_nil_for_non_year() {
        XCTAssertNil(ClaudeMetadataExtractor.normalizeYear(nil))
        XCTAssertNil(ClaudeMetadataExtractor.normalizeYear(""))
        XCTAssertNil(ClaudeMetadataExtractor.normalizeYear("MMIII"))
        XCTAssertNil(ClaudeMetadataExtractor.normalizeYear("99"))
    }

    // MARK: - normalizeISBN

    func test_normalizeISBN_strips_hyphens_and_spaces() {
        XCTAssertEqual(
            ClaudeMetadataExtractor.normalizeISBN("978-0-14-043912-0"),
            "9780140439120"
        )
        XCTAssertEqual(
            ClaudeMetadataExtractor.normalizeISBN("0 14 043912 X"),
            "014043912X"
        )
    }

    func test_normalizeISBN_uppercases_X_check_digit() {
        XCTAssertEqual(
            ClaudeMetadataExtractor.normalizeISBN("0-14-043912-x"),
            "014043912X"
        )
    }

    func test_normalizeISBN_rejects_wrong_length() {
        XCTAssertNil(ClaudeMetadataExtractor.normalizeISBN("12345"))
        XCTAssertNil(ClaudeMetadataExtractor.normalizeISBN("123456789012345"))
    }

    func test_normalizeISBN_rejects_non_digit_in_body() {
        XCTAssertNil(ClaudeMetadataExtractor.normalizeISBN("978abc0140439"))
    }

    // MARK: - sampleFrontMatter

    func test_sampleFrontMatter_pulls_text_from_first_chapters() {
        let chapters = [
            Chapter(title: "Front Matter", blocks: [
                .heading(level: 1, runs: [InlineRun("The Title")]),
                .paragraph(runs: [InlineRun("By A. Author")]),
                .paragraph(runs: [InlineRun("Publisher Press, 2003")]),
            ]),
            Chapter(title: "Chapter 1", blocks: [
                .paragraph(runs: [InlineRun("Body text starts here.")]),
            ]),
            Chapter(title: "Chapter 2", blocks: [
                .paragraph(runs: [InlineRun("Should not be included — past 2-chapter cap.")]),
            ]),
        ]
        let sample = ClaudeMetadataExtractor.sampleFrontMatter(
            from: chapters, maxChars: 4000
        )
        XCTAssertTrue(sample.contains("The Title"))
        XCTAssertTrue(sample.contains("A. Author"))
        XCTAssertTrue(sample.contains("Publisher Press, 2003"))
        XCTAssertTrue(sample.contains("Body text starts here."))
        XCTAssertFalse(sample.contains("past 2-chapter cap"),
            "must stop at 2-chapter boundary so deep body text doesn't pollute extraction")
    }

    func test_sampleFrontMatter_truncates_at_maxChars() {
        let big = String(repeating: "x ", count: 3000)  // 6000 chars
        let chapters = [Chapter(title: nil, blocks: [
            .paragraph(runs: [InlineRun(big)]),
        ])]
        let sample = ClaudeMetadataExtractor.sampleFrontMatter(
            from: chapters, maxChars: 1000
        )
        XCTAssertLessThanOrEqual(sample.count, 1000)
    }

    func test_sampleFrontMatter_skips_anchors_tables_figures() {
        let chapters = [Chapter(title: nil, blocks: [
            .anchor(id: "hu-page-0", label: "Page 1"),
            .table(rows: [], caption: []),
            .figure(assetId: "fig-1", alt: "f", caption: [InlineRun("caption text")]),
            .paragraph(runs: [InlineRun("real body")]),
        ])]
        let sample = ClaudeMetadataExtractor.sampleFrontMatter(
            from: chapters, maxChars: 4000
        )
        XCTAssertTrue(sample.contains("real body"))
        XCTAssertTrue(sample.contains("caption text"),
            "figure captions are body text and should be sampled")
        XCTAssertFalse(sample.contains("hu-page-0"))
    }

    // MARK: - extract (live mocked)

    func test_extract_returns_result_on_clean_response() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(jsonText:
                #"{"title":"X","author":"Y","year":"2000","publisher":"Z","isbn":null}"#))
        ])
        let r = await makeExtractor(transport: mock).extract(
            frontMatterText: String(repeating: "front matter content ", count: 10)
        )
        XCTAssertEqual(r?.title, "X")
        XCTAssertEqual(r?.author, "Y")
        XCTAssertEqual(r?.year, "2000")
        XCTAssertNil(r?.isbn)
    }

    func test_extract_returns_nil_for_short_input() async {
        // Below the 80-char floor — too little signal, skip the call.
        let mock = MockTransport(steps: [])
        let r = await makeExtractor(transport: mock).extract(
            frontMatterText: "tiny"
        )
        XCTAssertNil(r)
        let sent = await mock.sentRequests
        XCTAssertTrue(sent.isEmpty)
    }

    func test_extract_returns_nil_when_budget_exhausted() async {
        let mock = MockTransport(steps: [])
        let exhausted = ClaudeCallBudget(cap: 0)
        let r = await makeExtractor(transport: mock, budget: exhausted).extract(
            frontMatterText: String(repeating: "front matter content ", count: 10)
        )
        XCTAssertNil(r)
    }

    func test_extract_consumes_one_budget_call() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(jsonText:
                #"{"title":"X","author":null,"year":null,"publisher":null,"isbn":null}"#))
        ])
        let budget = ClaudeCallBudget(cap: 5)
        _ = await makeExtractor(transport: mock, budget: budget).extract(
            frontMatterText: String(repeating: "front matter content ", count: 10)
        )
        let consumed = await budget.consumed
        XCTAssertEqual(consumed, 1)
    }
}
