import XCTest
import AI
import Document
@testable import Pipeline

/// `ClaudeCoherenceAnalyzer` — pure helpers (digest, parse,
/// guardrail, apply) plus a few prompt-shape assertions against
/// a mocked transport.
final class ClaudeCoherenceAnalyzerTests: XCTestCase {

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
          "usage": {"input_tokens": 800, "output_tokens": 80}
        }
        """#
        return json.data(using: .utf8)!
    }

    private func makeAnalyzer(
        transport: any AnthropicTransport,
        budget: ClaudeCallBudget = ClaudeCallBudget(cap: 5)
    ) -> ClaudeCoherenceAnalyzer {
        let client = AnthropicAPIClient(
            config: AnthropicAPIClient.Config(maxRetries: 0),
            transport: transport,
            apiKeyProvider: { "sk-test" },
            sleeper: { _ in }
        )
        return ClaudeCoherenceAnalyzer(client: client, budget: budget)
    }

    // MARK: - parse

    func test_parse_decodes_suggestion_list() {
        let raw = #"""
        {"suggestions":[
          {"wrong":"Schafer","right":"Schäfer"},
          {"wrong":"rnoon","right":"moon"}
        ]}
        """#
        let s = ClaudeCoherenceAnalyzer.parse(raw)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].wrong, "Schafer")
        XCTAssertEqual(s[0].right, "Schäfer")
    }

    func test_parse_handles_empty_list() {
        XCTAssertEqual(
            ClaudeCoherenceAnalyzer.parse(#"{"suggestions":[]}"#),
            []
        )
    }

    func test_parse_strips_code_fence() {
        let raw = """
            ```json
            {"suggestions":[{"wrong":"a","right":"b"}]}
            ```
            """
        XCTAssertEqual(ClaudeCoherenceAnalyzer.parse(raw).count, 1)
    }

    func test_parse_returns_empty_for_malformed_json() {
        XCTAssertEqual(ClaudeCoherenceAnalyzer.parse("not json"), [])
        XCTAssertEqual(ClaudeCoherenceAnalyzer.parse(""), [])
    }

    // MARK: - shouldApply guardrails

    private let docWithThreeSchafers = """
        Schafer arrived at noon. The room was silent.
        Schafer paused, considering. Then Schafer spoke.
        """

    func test_shouldApply_accepts_recurring_diacritic_fix() {
        let s = ClaudeCoherenceAnalyzer.Suggestion(
            wrong: "Schafer", right: "Schäfer"
        )
        XCTAssertTrue(ClaudeCoherenceAnalyzer.shouldApply(
            suggestion: s, in: docWithThreeSchafers
        ))
    }

    func test_shouldApply_rejects_below_min_occurrences() {
        // Only 2 instances — below the 3-occurrence floor.
        let doc = "Schafer arrived. Schafer paused."
        let s = ClaudeCoherenceAnalyzer.Suggestion(
            wrong: "Schafer", right: "Schäfer"
        )
        XCTAssertFalse(ClaudeCoherenceAnalyzer.shouldApply(
            suggestion: s, in: doc
        ))
    }

    func test_shouldApply_rejects_when_replacement_already_present() {
        // Mixed-correctness document — `Schäfer` already appears,
        // so a global "Schafer → Schäfer" rewrite would be wrong
        // on the passages that author deliberately spelled
        // differently (or that earlier OCR caught correctly).
        let doc = """
            Schäfer arrived. Schafer paused. Schafer left.
            Schafer returned later.
            """
        let s = ClaudeCoherenceAnalyzer.Suggestion(
            wrong: "Schafer", right: "Schäfer"
        )
        XCTAssertFalse(ClaudeCoherenceAnalyzer.shouldApply(
            suggestion: s, in: doc
        ))
    }

    func test_shouldApply_rejects_extreme_length_jumps() {
        // Likely hallucination: `right` is < 50% the length of
        // `wrong` — Haiku probably guessed a totally different
        // word.
        let s = ClaudeCoherenceAnalyzer.Suggestion(
            wrong: "Constantinople", right: "C"
        )
        let doc = String(repeating: "Constantinople ", count: 5)
        XCTAssertFalse(ClaudeCoherenceAnalyzer.shouldApply(
            suggestion: s, in: doc
        ))
    }

    func test_shouldApply_rejects_empty_or_equal() {
        let doc = "abc abc abc"
        XCTAssertFalse(ClaudeCoherenceAnalyzer.shouldApply(
            suggestion: .init(wrong: "abc", right: ""), in: doc
        ))
        XCTAssertFalse(ClaudeCoherenceAnalyzer.shouldApply(
            suggestion: .init(wrong: "", right: "x"), in: doc
        ))
        XCTAssertFalse(ClaudeCoherenceAnalyzer.shouldApply(
            suggestion: .init(wrong: "abc", right: "abc"), in: doc
        ))
    }

    // MARK: - applyWithGuardrails

    private func makeChapters(text: String) -> [Chapter] {
        [Chapter(title: "Test", blocks: [
            .heading(level: 1, runs: [InlineRun(text)]),
            .paragraph(runs: [InlineRun(text)]),
            .paragraph(runs: [InlineRun(text)]),
        ])]
    }

    func test_apply_rewrites_text_across_runs() {
        let chapters = makeChapters(text: "Schafer arrived")
        // Three blocks × text "Schafer arrived" each = 3 occurrences.
        let suggestions = [
            ClaudeCoherenceAnalyzer.Suggestion(
                wrong: "Schafer", right: "Schäfer"
            ),
        ]
        let updated = ClaudeCoherenceAnalyzer.applyWithGuardrails(
            suggestions: suggestions, to: chapters
        )
        for block in updated[0].blocks {
            switch block {
            case .heading(_, let runs), .paragraph(let runs):
                XCTAssertEqual(runs.first?.text, "Schäfer arrived")
            default: continue
            }
        }
    }

    func test_apply_skips_rejected_suggestions() {
        let chapters = makeChapters(text: "Schafer arrived")
        // Only one suggestion is acceptable; the other has length
        // ratio out of bounds.
        let suggestions = [
            ClaudeCoherenceAnalyzer.Suggestion(
                wrong: "Schafer", right: "Schäfer"
            ),
            ClaudeCoherenceAnalyzer.Suggestion(
                wrong: "arrived", right: "x"  // rejected
            ),
        ]
        let updated = ClaudeCoherenceAnalyzer.applyWithGuardrails(
            suggestions: suggestions, to: chapters
        )
        guard case .heading(_, let runs) = updated[0].blocks[0] else {
            XCTFail("expected heading"); return
        }
        XCTAssertEqual(runs.first?.text, "Schäfer arrived",
            "accepted suggestion applied; rejected one didn't")
    }

    func test_apply_returns_input_when_all_suggestions_rejected() {
        let chapters = makeChapters(text: "Foo bar")
        let suggestions = [
            ClaudeCoherenceAnalyzer.Suggestion(wrong: "Foo", right: "Foo"),  // equal
        ]
        let updated = ClaudeCoherenceAnalyzer.applyWithGuardrails(
            suggestions: suggestions, to: chapters
        )
        XCTAssertEqual(updated, chapters)
    }

    func test_apply_preserves_run_metadata() {
        let chapters = [Chapter(title: "Test", blocks: [
            .paragraph(runs: [
                InlineRun("Schafer", language: .de, noterefId: "fn-1"),
                InlineRun(" arrived", language: .en),
            ]),
            .paragraph(runs: [InlineRun("Schafer paused.")]),
            .paragraph(runs: [InlineRun("Schafer left.")]),
        ])]
        let suggestions = [
            ClaudeCoherenceAnalyzer.Suggestion(
                wrong: "Schafer", right: "Schäfer"
            ),
        ]
        let updated = ClaudeCoherenceAnalyzer.applyWithGuardrails(
            suggestions: suggestions, to: chapters
        )
        guard case .paragraph(let runs) = updated[0].blocks[0] else {
            XCTFail("expected paragraph"); return
        }
        XCTAssertEqual(runs[0].text, "Schäfer")
        XCTAssertEqual(runs[0].language, .de)
        XCTAssertEqual(runs[0].noterefId, "fn-1")
        XCTAssertEqual(runs[1].text, " arrived")
        XCTAssertEqual(runs[1].language, .en)
    }

    func test_apply_rewrites_chapter_title() {
        // Coherence rewrites should reach into the chapter title
        // too — if the title carries the misread name, it'll
        // appear in the nav and be visible.
        let chapters = [Chapter(title: "Schafer's Journey", blocks: [
            .paragraph(runs: [InlineRun("Schafer left.")]),
            .paragraph(runs: [InlineRun("Schafer returned.")]),
            .paragraph(runs: [InlineRun("Schafer paused.")]),
        ])]
        let suggestions = [
            ClaudeCoherenceAnalyzer.Suggestion(
                wrong: "Schafer", right: "Schäfer"
            ),
        ]
        let updated = ClaudeCoherenceAnalyzer.applyWithGuardrails(
            suggestions: suggestions, to: chapters
        )
        XCTAssertEqual(updated[0].title, "Schäfer's Journey")
    }

    // MARK: - buildDigest

    func test_buildDigest_includes_chapter_title_brackets() {
        let chapters = [
            Chapter(title: "Origins", blocks: [
                .paragraph(runs: [InlineRun("Body of chapter one.")]),
            ]),
            Chapter(title: "Aftermath", blocks: [
                .paragraph(runs: [InlineRun("Body of chapter two.")]),
            ]),
        ]
        let digest = ClaudeCoherenceAnalyzer.buildDigest(chapters: chapters)
        XCTAssertTrue(digest.contains("[Origins]"))
        XCTAssertTrue(digest.contains("[Aftermath]"))
        XCTAssertTrue(digest.contains("chapter one"))
        XCTAssertTrue(digest.contains("chapter two"))
    }

    func test_buildDigest_caps_per_chapter_body() {
        let bigBody = String(repeating: "x ", count: 500)  // 1000 chars
        let chapters = [Chapter(title: "Big", blocks: [
            .paragraph(runs: [InlineRun(bigBody)]),
        ])]
        let digest = ClaudeCoherenceAnalyzer.buildDigest(
            chapters: chapters, maxChars: 8000
        )
        // 200-char per-chapter cap means we should see far less
        // than the full 1000-char body.
        XCTAssertLessThan(digest.count, 250)
    }

    // MARK: - analyze (live mocked)

    func test_analyze_returns_suggestions_on_clean_response() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(jsonText:
                #"{"suggestions":[{"wrong":"Schafer","right":"Schäfer"}]}"#))
        ])
        let chapters = [Chapter(title: "x", blocks: [
            .paragraph(runs: [InlineRun(String(repeating: "filler ", count: 50))])
        ])]
        let s = await makeAnalyzer(transport: mock).analyze(chapters: chapters)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].wrong, "Schafer")
    }

    func test_analyze_returns_empty_for_short_digest() async {
        // Below 200-char floor — skip the call.
        let mock = MockTransport(steps: [])
        let chapters = [Chapter(title: "x", blocks: [
            .paragraph(runs: [InlineRun("short")])
        ])]
        let s = await makeAnalyzer(transport: mock).analyze(chapters: chapters)
        XCTAssertEqual(s, [])
        let sent = await mock.sentRequests
        XCTAssertTrue(sent.isEmpty)
    }

    func test_analyze_consumes_one_budget_call_on_real_input() async {
        let mock = MockTransport(steps: [
            .init(status: 200, body: successBody(jsonText:
                #"{"suggestions":[]}"#))
        ])
        let budget = ClaudeCallBudget(cap: 5)
        let chapters = [Chapter(title: "x", blocks: [
            .paragraph(runs: [InlineRun(String(repeating: "filler ", count: 50))])
        ])]
        _ = await makeAnalyzer(transport: mock, budget: budget).analyze(chapters: chapters)
        let consumed = await budget.consumed
        XCTAssertEqual(consumed, 1)
    }
}
