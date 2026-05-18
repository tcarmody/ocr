import XCTest
@testable import AI

/// `GeminiEmbeddingBackend` smoke tests — focus on the
/// deterministic helpers (retry-delay parsers + duration parser)
/// rather than the HTTP path, which would need a live key.
final class GeminiEmbeddingBackendTests: XCTestCase {

    // MARK: - parseDurationString

    func test_parse_integer_seconds() {
        XCTAssertEqual(GeminiEmbeddingBackend.parseDurationString("16s"), 16)
    }

    func test_parse_fractional_seconds() {
        let parsed = GeminiEmbeddingBackend.parseDurationString("16.120805818s")
        XCTAssertEqual(parsed ?? 0, 16.120805818, accuracy: 1e-6)
    }

    func test_parse_handles_whitespace() {
        XCTAssertEqual(GeminiEmbeddingBackend.parseDurationString(" 5s "), 5)
    }

    func test_parse_rejects_minute_form() {
        // `RetryInfo.retryDelay` in the embedding API only emits
        // seconds; explicitly reject other shapes so a future
        // protocol change is loud.
        XCTAssertNil(GeminiEmbeddingBackend.parseDurationString("1m"))
        XCTAssertNil(GeminiEmbeddingBackend.parseDurationString("500ms"))
    }

    func test_parse_rejects_negative() {
        XCTAssertNil(GeminiEmbeddingBackend.parseDurationString("-1s"))
    }

    // MARK: - retryAfterSecondsFromBody

    func test_body_parser_reads_structured_retry_info() {
        let body = """
        {
          "error": {
            "code": 429,
            "status": "RESOURCE_EXHAUSTED",
            "message": "You exceeded your current quota.",
            "details": [{
              "@type": "type.googleapis.com/google.rpc.RetryInfo",
              "retryDelay": "16.120805818s"
            }]
          }
        }
        """
        let result = GeminiEmbeddingBackend.retryAfterSecondsFromBody(
            data: Data(body.utf8)
        )
        XCTAssertEqual(result ?? 0, 16.120805818, accuracy: 1e-6)
    }

    func test_body_parser_falls_back_to_message_regex() {
        // Missing RetryInfo detail — fall back to the message
        // regex that parses Google's standard phrasing.
        let body = """
        {
          "error": {
            "code": 429,
            "status": "RESOURCE_EXHAUSTED",
            "message": "Quota exceeded. Please retry in 12.5s. Details elided."
          }
        }
        """
        let result = GeminiEmbeddingBackend.retryAfterSecondsFromBody(
            data: Data(body.utf8)
        )
        XCTAssertEqual(result ?? 0, 12.5, accuracy: 1e-6)
    }

    func test_body_parser_returns_nil_when_no_retry_hint() {
        let body = """
        {"error": {"code": 500, "message": "internal server error"}}
        """
        XCTAssertNil(GeminiEmbeddingBackend.retryAfterSecondsFromBody(
            data: Data(body.utf8)
        ))
    }

    func test_body_parser_returns_nil_on_non_json() {
        XCTAssertNil(GeminiEmbeddingBackend.retryAfterSecondsFromBody(
            data: Data("not json".utf8)
        ))
    }
}
