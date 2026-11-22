import XCTest
import AI
@testable import Pipeline

/// Wire-layer tests for LandingAI's ADE Gen2 parse API (DPT-3 Pro).
/// No network: request shape, response decoding, markdown cleanup and
/// cost recording.
final class LandingAIParseTests: XCTestCase {

    // MARK: - Request

    func test_request_targets_gen2_parse_with_dpt3_pro() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let request = LandingAIParse.makeRequest(
            baseURL: LandingAIParse.defaultBaseURL,
            apiKey: "test-key",
            model: LandingAIParse.defaultModel,
            png: png, filename: "region.png", timeout: 30
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.ade.landing.ai/v2/parse")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Content-Type")?
                .hasPrefix("multipart/form-data; boundary=") ?? false
        )
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\ndpt-3-pro-latest\r\n"))
        XCTAssertTrue(body.contains(
            "name=\"options\"\r\n\r\n{\"blocks\":{\"table\":{\"format\":\"markdown\"}}}\r\n"
        ))
        XCTAssertTrue(body.contains("name=\"document\"; filename=\"region.png\""))
        XCTAssertTrue(body.contains("Content-Type: image/png"))
    }

    func test_eu_base_url() {
        let request = LandingAIParse.makeRequest(
            baseURL: LandingAIParse.euBaseURL, apiKey: "k",
            model: LandingAIParse.defaultModel, png: Data(),
            filename: "p.png", timeout: 30
        )
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.ade.eu-west-1.landing.ai/v2/parse"
        )
    }

    func test_engines_default_to_gen2_dpt3_pro() {
        let budget = CloudCallBudget(cap: 1)
        let doc = LandingAIDocumentEngine(apiKeyProvider: { "k" }, budget: budget)
        XCTAssertEqual(doc.baseURL, LandingAIParse.defaultBaseURL)
        XCTAssertEqual(doc.model, "dpt-3-pro-latest")
        let table = LandingAITableExtractor(apiKeyProvider: { "k" }, budget: budget)
        XCTAssertEqual(table.baseURL, LandingAIParse.defaultBaseURL)
        XCTAssertEqual(table.model, "dpt-3-pro-latest")
    }

    // MARK: - Response

    func test_decodes_gen2_response_markdown_and_billing() throws {
        let json = #"""
        {
          "markdown": "# Title\n\nBody text.\n\n<!-- doc_id=job_123 -->",
          "metadata": {
            "job_id": "job_123",
            "model_version": "dpt-3-pro-20260710",
            "page_count": 1,
            "output_markdown_chars": 40,
            "range_units": "unicode_codepoints",
            "failed_pages": [],
            "duration_ms": 900,
            "billing": {"service_tier": "priority", "total_credits": 1.1}
          },
          "structure": {"type": "document", "children": []}
        }
        """#
        let r = try LandingAIParse.decode(Data(json.utf8))
        XCTAssertEqual(r.metadata?.modelVersion, "dpt-3-pro-20260710")
        XCTAssertEqual(r.metadata?.failedPages, [])
        XCTAssertEqual(r.metadata?.billing?.totalCredits, 1.1)
        XCTAssertEqual(LandingAIParse.cleanMarkdown(r.markdown ?? ""), "# Title\n\nBody text.")
    }

    func test_decodes_minimal_body() throws {
        let r = try LandingAIParse.decode(Data(#"{"markdown": "x"}"#.utf8))
        XCTAssertEqual(r.markdown, "x")
        XCTAssertNil(r.metadata)
    }

    // MARK: - Markdown cleanup

    func test_clean_strips_figures_comments_and_page_breaks() {
        let raw = """
        Intro paragraph.

        <figure type="CHART"><description>Bar chart of revenue</description></figure>

        | a | b |
        |---|---|
        | 1 | 2 |
        <!-- PAGE BREAK -->
        Next page.
        <figure type="DIAGRAM">
        Label text
        <description>Flow</description>
        </figure>
        <!-- doc_id=abc -->
        """
        let cleaned = LandingAIParse.cleanMarkdown(raw)
        XCTAssertFalse(cleaned.contains("<figure"))
        XCTAssertFalse(cleaned.contains("<!--"))
        XCTAssertFalse(cleaned.contains("Bar chart"))
        XCTAssertFalse(cleaned.contains("\n\n\n"))
        XCTAssertTrue(cleaned.hasPrefix("Intro paragraph."))
        XCTAssertTrue(cleaned.contains("| a | b |\n|---|---|\n| 1 | 2 |"))
        XCTAssertTrue(cleaned.hasSuffix("Next page."))
    }

    func test_cleaned_markdown_still_parses_pipe_table() {
        let raw = "Caption\n\n| h1 | h2 |\n|----|----|\n| a | b |\n\n<!-- doc_id=x -->"
        let rows = LandingAITableExtractor.parseMarkdownTable(
            LandingAIParse.cleanMarkdown(raw)
        )
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?.first?.first?.isHeader, true)
    }

    // MARK: - Cost

    func test_usage_records_billed_credits_in_tenths() {
        let r = LandingAIParse.Response(
            markdown: "x",
            metadata: .init(modelVersion: nil, failedPages: nil,
                            billing: .init(totalCredits: 2.5))
        )
        let usage = LandingAIParse.usage(for: r)
        XCTAssertEqual(usage.outputTokens, 25)
        XCTAssertEqual(usage.inputTokens, 0)
        // Float noise: 1.1 credits × 10 = 11.000…02 must stay 11.
        let noisy = LandingAIParse.Response(
            markdown: "x",
            metadata: .init(modelVersion: nil, failedPages: nil,
                            billing: .init(totalCredits: 1.1))
        )
        XCTAssertEqual(LandingAIParse.usage(for: noisy).outputTokens, 11)
        XCTAssertEqual(
            CloudModel.landingAIDPT3Pro.pricing.cost(for: usage), 0.025, accuracy: 1e-9
        )
    }

    func test_usage_falls_back_to_published_rate_without_billing() {
        // 1 credit/page + 0.5 per 1,000 chars: 3,000 chars → 2.5 credits.
        let r = LandingAIParse.Response(
            markdown: String(repeating: "a", count: 3000), metadata: nil
        )
        XCTAssertEqual(LandingAIParse.usage(for: r).outputTokens, 25)
        // Rounded up to 0.1 credit: 10 chars → 1.005 → 1.1 credits.
        let small = LandingAIParse.Response(
            markdown: String(repeating: "a", count: 10), metadata: nil
        )
        XCTAssertEqual(LandingAIParse.usage(for: small).outputTokens, 11)
    }

    func test_dpt3_pro_pricing_is_a_tenth_of_a_cent_per_token() {
        let p = CloudModel.landingAIDPT3Pro.pricing
        XCTAssertEqual(p.inputPerMTok, 0)
        XCTAssertEqual(p.outputPerMTok, 1000)
        // Gen1 rate still prices old persisted usage.
        XCTAssertEqual(CloudModel.landingAIDocumentExtraction.pricing.outputPerMTok, 30000)
    }

    func test_cost_estimator_splits_region_and_page_rates() {
        XCTAssertEqual(CostEstimator.costPerCall(.landingAIDocumentOCR), 0.013, accuracy: 1e-9)
        XCTAssertEqual(CostEstimator.costPerCall(.landingAIPageOCR), 0.025, accuracy: 1e-9)
    }
}
