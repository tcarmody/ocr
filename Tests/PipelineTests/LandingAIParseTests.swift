import XCTest
import AI
import Document
import OCR
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
        // HTML tables stay on (the default); per-line atomic
        // grounding is turned off.
        XCTAssertTrue(body.contains(
            "name=\"options\"\r\n\r\n{\"atomic_grounding\":false}\r\n"
        ))
        XCTAssertFalse(body.contains("\"format\""))
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

    // MARK: - Structure tree

    /// Gen2 response for one image: a heading, a body paragraph, a
    /// marginalia page number, a figure, and a table whose header has
    /// two merged-down cells and one merged-across cell. Ranges are
    /// code-point offsets into `markdown`, which starts with a
    /// non-BMP character so byte/UTF-16 offsets would be wrong.
    static let structuredJSON: String = {
        let heading = "# 𝔄 Title"
        let body = "Body with **bold** text."
        let page = "12"
        let figure = #"<figure type="CHART"><description>x</description></figure>"#
        let cells = ["Name", "Score", "Q1", "Q2", "Ann &amp; Bo", "3", "4"]
        var md = ""
        var ranges: [(Int, Int)] = []
        func add(_ s: String) {
            let start = md.unicodeScalars.count
            md += s
            ranges.append((start, md.unicodeScalars.count))
        }
        add(heading); md += "\n\n"
        add(body); md += "\n\n"
        add(page); md += "\n\n"
        add(figure); md += "\n\n"
        let tableStart = md.unicodeScalars.count
        md += "<table>\n<tr><td rowspan=\"2\">"
        add(cells[0]); md += "</td><td colspan=\"2\">"
        add(cells[1]); md += "</td></tr>\n<tr><td>"
        add(cells[2]); md += "</td><td>"
        add(cells[3]); md += "</td></tr>\n<tr><td>"
        add(cells[4]); md += "</td><td>"
        add(cells[5]); md += "</td><td>"
        add(cells[6]); md += "</td></tr>\n</table>"
        let tableEnd = md.unicodeScalars.count
        md += "\n\n<!-- doc_id=j -->"
        func g(_ i: Int, box: String = #""box":{"xmin":0.1,"ymin":0.2,"xmax":0.9,"ymax":0.3}"#) -> String {
            #"{"page":1,"range":{"start":\#(ranges[i].0),"end":\#(ranges[i].1)},\#(box)}"#
        }
        func cell(_ i: Int, row: Int, col: Int, rs: Int = 1, cs: Int = 1) -> String {
            #"{"type":"table_cell","id":"table_cell-\#(i)","grounding":\#(g(i + 4)),"row":\#(row),"col":\#(col),"rowspan":\#(rs),"colspan":\#(cs)}"#
        }
        let tableChildren = [
            cell(0, row: 0, col: 0, rs: 2), cell(1, row: 0, col: 1, cs: 2),
            cell(2, row: 1, col: 1), cell(3, row: 1, col: 2),
            cell(4, row: 2, col: 0), cell(5, row: 2, col: 1), cell(6, row: 2, col: 2),
        ].joined(separator: ",")
        let blocks = [
            #"{"type":"text","id":"text-0","grounding":\#(g(0))}"#,
            #"{"type":"text","id":"text-1","grounding":\#(g(1))}"#,
            #"{"type":"marginalia","id":"marginalia-0","grounding":\#(g(2))}"#,
            #"{"type":"figure","id":"figure-0","grounding":\#(g(3))}"#,
            #"{"type":"table","id":"table-0","grounding":{"page":1,"range":{"start":\#(tableStart),"end":\#(tableEnd)},"box":{"xmin":0,"ymin":0.5,"xmax":1,"ymax":0.9}},"children":[\#(tableChildren)]}"#,
        ].joined(separator: ",")
        let mdJSON = String(
            data: try! JSONEncoder().encode(md), encoding: .utf8
        )!
        return #"""
        {"markdown": \#(mdJSON),
         "metadata": {"model_version":"dpt-3-pro-20260710","failed_pages":[],
                      "billing":{"service_tier":"priority","total_credits":1.2}},
         "structure": {"type":"document","children":[
           {"type":"page","status":"ok",
            "grounding":{"page":1,"range":{"start":0,"end":0},"box":{"xmin":0,"ymin":0,"xmax":1,"ymax":1}},
            "children":[\#(blocks)]}]}}
        """#
    }()

    func structured() throws -> LandingAIParse.Response {
        try LandingAIParse.decode(Data(Self.structuredJSON.utf8))
    }

    func test_decodes_structure_tree_and_slices_by_code_points() throws {
        let r = try structured()
        XCTAssertEqual(r.blocks.map(\.type), ["text", "text", "marginalia", "figure", "table"])
        XCTAssertEqual(r.text(of: r.blocks[0]), "# 𝔄 Title")
        XCTAssertEqual(r.text(of: r.blocks[1]), "Body with **bold** text.")
        XCTAssertEqual(r.blocks[4].children?.count, 7)
    }

    func test_failed_pages_are_skipped() throws {
        let json = #"""
        {"markdown":"","structure":{"type":"document","children":[
          {"type":"page","status":"failed","children":[]}]}}
        """#
        let r = try LandingAIParse.decode(Data(json.utf8))
        XCTAssertTrue(r.blocks.isEmpty)
    }

    func test_slice_clamps_bad_ranges() {
        let r = LandingAIParse.Response(markdown: "abc", metadata: nil)
        XCTAssertEqual(r.slice(.init(start: 1, end: 99)), "bc")
        XCTAssertEqual(r.slice(.init(start: 5, end: 2)), "")
        XCTAssertEqual(r.slice(nil), "")
    }

    func test_table_rows_keep_merged_cells_and_header_rows() throws {
        let r = try structured()
        let rows = LandingAIParse.tableRows(from: r.blocks[4], in: r)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.count), [2, 2, 3])
        XCTAssertEqual(rows[0][0].rowspan, 2)
        XCTAssertEqual(rows[0][1].colspan, 2)
        // Row 0's rowspan of 2 makes rows 0–1 the header.
        XCTAssertTrue(rows[0].allSatisfy(\.isHeader))
        XCTAssertTrue(rows[1].allSatisfy(\.isHeader))
        XCTAssertFalse(rows[2].contains(where: \.isHeader))
        XCTAssertEqual(rows[2][0].runs.map(\.text).joined(), "Ann & Bo")
        XCTAssertEqual(LandingAIParse.columnCount(rows), 3)
    }

    func test_parse_html_table_reads_spans_and_entities() {
        let html = """
        <table>
        <tr><td rowspan="2">Test Point</td><td colspan="2">Measured</td></tr>
        <tr><td>As Found</td><td>As Left</td></tr>
        <tr><td>TP&#45;1</td><td>0.000<br>V</td><td>&lt;1</td></tr>
        </table>
        """
        let rows = LandingAIParse.parseHTMLTable(html)
        XCTAssertEqual(rows?.count, 3)
        XCTAssertEqual(rows?[0][0].rowspan, 2)
        XCTAssertEqual(rows?[0][1].colspan, 2)
        XCTAssertEqual(rows?[1].first?.isHeader, true)
        XCTAssertEqual(rows?[2].first?.isHeader, false)
        XCTAssertEqual(rows?[2].map { $0.runs.map(\.text).joined() }, ["TP-1", "0.000 V", "<1"])
    }

    func test_parse_html_table_uses_th_when_present() {
        let html = "<table><tr><th>A</th><td>B</td></tr><tr><td>1</td><td>2</td></tr></table>"
        let rows = LandingAIParse.parseHTMLTable(html)
        XCTAssertEqual(rows?[0].map(\.isHeader), [true, false])
        XCTAssertEqual(rows?[1].map(\.isHeader), [false, false])
    }

    func test_parse_html_table_returns_nil_without_table() {
        XCTAssertNil(LandingAIParse.parseHTMLTable("no table here"))
    }

    func test_plain_text_flattens_html_table() {
        let text = LandingAIParse.plainText(
            "<table><tr><td>a</td><td>b</td></tr><tr><td>1 &amp; 2</td></tr></table>"
        )
        XCTAssertEqual(text, "a b\n1 & 2")
    }

    func test_decode_entities() {
        XCTAssertEqual(LandingAIParse.decodeEntities("a &amp; b &#x3B1; &#946; &bogus; &"),
                       "a & b α β &bogus; &")
    }

    // MARK: - Engines over the structure tree

    func test_region_observations_follow_structure_with_vision_boxes() throws {
        let r = try structured()
        let obs = LandingAIDocumentEngine.observations(from: r)
        // text, text, marginalia, table — the figure is dropped.
        XCTAssertEqual(obs.count, 4)
        XCTAssertEqual(obs[0].text, "# 𝔄 Title")
        XCTAssertEqual(obs[3].text, "Name Score\nQ1 Q2\nAnn & Bo 3 4")
        // Top-left (0.1, 0.2)–(0.9, 0.3) → Vision lower-left origin.
        XCTAssertEqual(obs[0].box.origin.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(obs[0].box.origin.y, 0.7, accuracy: 1e-9)
        XCTAssertEqual(obs[0].box.width, 0.8, accuracy: 1e-9)
        XCTAssertEqual(obs[0].box.height, 0.1, accuracy: 1e-9)
    }

    func test_region_observations_fall_back_to_flat_markdown() {
        let r = LandingAIParse.Response(
            markdown: "Just text.\n\n<!-- doc_id=x -->", metadata: nil
        )
        let obs = LandingAIDocumentEngine.observations(from: r)
        XCTAssertEqual(obs.map(\.text), ["Just text."])
        XCTAssertEqual(obs.first?.box, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func test_page_blocks_follow_structure_and_skip_marginalia_and_figures() throws {
        let r = try structured()
        let blocks = LandingAIPageOCREngine.blocks(from: r)
        XCTAssertEqual(blocks.count, 3)
        guard case .heading(let level, let hRuns) = blocks[0] else {
            return XCTFail("expected heading, got \(blocks[0])")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(hRuns.map(\.text).joined(), "𝔄 Title")
        guard case .paragraph(let pRuns) = blocks[1] else {
            return XCTFail("expected paragraph, got \(blocks[1])")
        }
        XCTAssertTrue(pRuns.contains { $0.text == "bold" && $0.isBold })
        guard case .table(let rows, _) = blocks[2] else {
            return XCTFail("expected table, got \(blocks[2])")
        }
        XCTAssertEqual(rows[0][0].rowspan, 2)
        XCTAssertEqual(rows[0][1].colspan, 2)
    }

    func test_page_blocks_fall_back_to_markdown_with_html_table() {
        let md = """
        Intro.

        <table>
        <tr><td colspan="2">Head</td></tr>
        <tr><td>a</td><td>b</td></tr>
        </table>

        <!-- doc_id=x -->
        """
        let blocks = LandingAIPageOCREngine.blocks(
            from: LandingAIParse.Response(markdown: md, metadata: nil)
        )
        XCTAssertEqual(blocks.count, 2)
        guard case .table(let rows, _) = blocks[1] else {
            return XCTFail("expected table, got \(blocks[1])")
        }
        XCTAssertEqual(rows[0][0].colspan, 2)
        XCTAssertEqual(rows[1].count, 2)
    }

    func test_table_extractor_prefers_structure_then_html_then_pipe() throws {
        let fromTree = LandingAITableExtractor.rows(from: try structured())
        XCTAssertEqual(fromTree?[0][0].rowspan, 2)

        let html = LandingAIParse.Response(
            markdown: "<table><tr><td colspan=\"2\">H</td></tr><tr><td>a</td><td>b</td></tr></table>",
            metadata: nil
        )
        XCTAssertEqual(LandingAITableExtractor.rows(from: html)?[0][0].colspan, 2)

        let pipe = LandingAIParse.Response(
            markdown: "| h1 | h2 |\n|----|----|\n| a | b |", metadata: nil
        )
        XCTAssertEqual(LandingAITableExtractor.rows(from: pipe)?.count, 2)

        XCTAssertNil(LandingAITableExtractor.rows(
            from: LandingAIParse.Response(markdown: "no table", metadata: nil)
        ))
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
