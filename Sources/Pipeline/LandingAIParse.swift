import Foundation
import AI
import Document

/// Shared wire layer for LandingAI's ADE Gen2 parse API (DPT-3),
/// used by `LandingAIDocumentEngine` (cascade region OCR + page OCR)
/// and `LandingAITableExtractor`.
///
/// Gen2 replaced the Gen1 `POST https://api.va.landing.ai/v1/ade/parse`
/// (DPT-2) with `POST https://api.ade.landing.ai/v2/parse`. The request
/// is still multipart/form-data with a `document` file part, a `model`
/// field and Bearer auth; the response is a redesign — `chunks`,
/// per-chunk markdown and the top-level `grounding` map are gone in
/// favour of a `structure` tree: document → pages → blocks (`text`,
/// `table` → `table_cell`, `figure`, `marginalia`, …) in reading order,
/// each with a `grounding` (page, a `[start, end)` code-point `range`
/// into the top-level `markdown`, and a top-left-origin 0–1 `box`).
/// Callers build their output from that tree — typed blocks, real
/// boxes, and table cells with `row` / `col` / `rowspan` / `colspan` —
/// and fall back to the flat `markdown` when it's missing.
///
/// Gen2 markdown differs from Gen1 in ways the callers care about:
///   * tables are HTML `<table>` markup (the default, kept because it
///     preserves merged cells); `parseHTMLTable` reads it when the
///     structure tree isn't available;
///   * figures render as `<figure type="…">…</figure>` and the output
///     ends with a `<!-- doc_id=… -->` line (plus `<!-- PAGE BREAK -->`
///     between pages of multi-page input) — `cleanMarkdown` strips
///     both, since figures come from Surya + FigureExtractor.
///
/// Docs: https://docs.landing.ai/dpt3/migration-guide.md,
/// https://docs.landing.ai/dpt3/parse-response.md
public enum LandingAIParse {
    /// US deployment. EU users pass `euBaseURL`; API keys are
    /// deployment-specific (a US key doesn't work in the EU).
    public static let defaultBaseURL = URL(string: "https://api.ade.landing.ai")!
    public static let euBaseURL = URL(string: "https://api.ade.eu-west-1.landing.ai")!
    static let path = "/v2/parse"

    /// DPT-3 Pro, LandingAI's default parse model. The `-latest` alias
    /// follows new snapshots; the response's `metadata.model_version`
    /// names the snapshot that ran (e.g. `dpt-3-pro-20260710`).
    public static let defaultModel = "dpt-3-pro-latest"

    /// Keep the default HTML tables (they carry merged cells) and turn
    /// off per-line `atomic_grounding`, which we don't read — it only
    /// enlarges the response.
    static let optionsJSON = #"{"atomic_grounding":false}"#

    /// Build the multipart `POST /v2/parse` request for one PNG.
    static func makeRequest(
        baseURL: URL,
        apiKey: String,
        model: String,
        png: Data,
        filename: String,
        timeout: TimeInterval
    ) -> URLRequest {
        let boundary = "Boundary-" + UUID().uuidString
        var body = Data()
        body.append(textField(name: "model", value: model, boundary: boundary))
        body.append(textField(name: "options", value: optionsJSON, boundary: boundary))
        body.append(fileField(
            name: "document", filename: filename, mimeType: "image/png",
            content: png, boundary: boundary
        ))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(
            url: baseURL.appendingPathComponent(path),
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body
        return request
    }

    // MARK: - Response

    /// The subset of Gen2 `ParseResponse` we use. `markdown` is
    /// required by the schema; decoded as optional so a malformed
    /// body surfaces as "empty" rather than a decode crash.
    struct Response: Decodable {
        let markdown: String?
        let metadata: Metadata?
        /// Root `document` node; nil on a body without one.
        var structure: Node? = nil

        init(markdown: String?, metadata: Metadata?, structure: Node? = nil) {
            self.markdown = markdown
            self.metadata = metadata
            self.structure = structure
        }

        /// `[start, end)` slice of `markdown` in Unicode code points —
        /// the unit Gen2 uses for every `grounding.range`. Clamped, so
        /// a bad range yields "" rather than a crash.
        func slice(_ range: Node.Range?) -> String {
            guard let range, let markdown else { return "" }
            let scalars = Array(markdown.unicodeScalars)
            let lo = max(0, min(range.start, scalars.count))
            let hi = max(lo, min(range.end, scalars.count))
            var out = String.UnicodeScalarView()
            out.append(contentsOf: scalars[lo..<hi])
            return String(out)
        }

        /// Text of a block: its markdown slice.
        func text(of node: Node) -> String { slice(node.grounding?.range) }

        /// Blocks of every successfully parsed page, in reading order.
        var blocks: [Node] {
            (structure?.children ?? [])
                .filter { $0.type == "page" && $0.status != "failed" }
                .flatMap { $0.children ?? [] }
        }

        private enum CodingKeys: String, CodingKey {
            case markdown, metadata, structure
        }

        struct Metadata: Decodable {
            let modelVersion: String?
            let failedPages: [Int]?
            let billing: Billing?

            private enum CodingKeys: String, CodingKey {
                case modelVersion = "model_version"
                case failedPages = "failed_pages"
                case billing
            }
        }

        struct Billing: Decodable {
            let totalCredits: Double?

            private enum CodingKeys: String, CodingKey {
                case totalCredits = "total_credits"
            }
        }
    }

    /// One `structure` node — document, page or block. Only `type` is
    /// required here; Gen2 omits unset optional fields.
    struct Node: Decodable, Equatable {
        let type: String
        var id: String? = nil
        var grounding: Grounding? = nil
        var children: [Node]? = nil
        /// Pages only: `"ok"` or `"failed"`.
        var status: String? = nil
        /// `table_cell` only: 0-indexed position and spans (default 1).
        var row: Int? = nil
        var col: Int? = nil
        var rowspan: Int? = nil
        var colspan: Int? = nil

        struct Grounding: Decodable, Equatable {
            var page: Int? = nil
            var range: Range? = nil
            var box: Box? = nil
        }

        struct Range: Decodable, Equatable {
            let start: Int
            let end: Int
        }

        /// Fractions of the page, origin top-left, y increasing down.
        struct Box: Decodable, Equatable {
            let xmin: Double
            let ymin: Double
            let xmax: Double
            let ymax: Double
        }
    }

    static func decode(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }

    // MARK: - Markdown cleanup

    /// Remove Gen2-only markup that isn't page text: HTML comments
    /// (`<!-- doc_id=… -->`, `<!-- PAGE BREAK -->`) and `<figure>`
    /// blocks (figures come from Surya + FigureExtractor). Collapses
    /// the blank lines left behind and trims the ends.
    static func cleanMarkdown(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(
            of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"<figure\b[^>]*>[\s\S]*?</figure>"#, with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: #"\n{3,}"#, with: "\n\n", options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tables

    /// `[[TableCell]]` for a `table` node, from its `table_cell`
    /// children: one row per `row` index, cells ordered by `col`, each
    /// merged cell listed once with its spans (same convention as
    /// `ClaudeTableExtractor`). Gen2 has no header flag, so the rows
    /// covered by the first row's cells are treated as the header —
    /// matching what the pipe-table path did with the first row.
    static func tableRows(
        from table: Node,
        in response: Response,
        runs makeRuns: (String) -> [InlineRun] = plainRuns
    ) -> [[TableCell]] {
        let cells = (table.children ?? []).filter { $0.type == "table_cell" }
        guard !cells.isEmpty else { return [] }
        let byRow = Dictionary(grouping: cells) { $0.row ?? 0 }
        let headerRows = (byRow[byRow.keys.min() ?? 0] ?? [])
            .map { max(1, $0.rowspan ?? 1) }.max() ?? 1
        let firstRow = byRow.keys.min() ?? 0
        return byRow.keys.sorted().map { r in
            (byRow[r] ?? []).sorted { ($0.col ?? 0) < ($1.col ?? 0) }.map { cell in
                TableCell(
                    runs: makeRuns(cellText(response.text(of: cell))),
                    isHeader: r < firstRow + headerRows,
                    rowspan: max(1, cell.rowspan ?? 1),
                    colspan: max(1, cell.colspan ?? 1)
                )
            }
        }
    }

    /// Parse the first HTML `<table>` in `html` — the fallback when the
    /// structure tree is missing. Reads `rowspan` / `colspan`; `<th>`
    /// cells are headers, and when there are none the first row's
    /// rowspan rule from `tableRows` applies.
    static func parseHTMLTable(
        _ html: String,
        runs makeRuns: (String) -> [InlineRun] = plainRuns
    ) -> [[TableCell]]? {
        guard let tableRange = html.range(
            of: #"<table\b[^>]*>[\s\S]*?</table>"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let table = String(html[tableRange])
        let rowPattern = try! NSRegularExpression(
            pattern: #"<tr\b[^>]*>([\s\S]*?)</tr>"#, options: [.caseInsensitive]
        )
        let cellPattern = try! NSRegularExpression(
            pattern: #"<(td|th)\b([^>]*)>([\s\S]*?)</\1>"#, options: [.caseInsensitive]
        )
        func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String {
            guard let r = Swift.Range(m.range(at: i), in: s) else { return "" }
            return String(s[r])
        }
        func span(_ name: String, in attrs: String) -> Int {
            guard let r = attrs.range(
                of: name + #"\s*=\s*["']?(\d+)"#,
                options: [.regularExpression, .caseInsensitive]
            ) else { return 1 }
            let digits = attrs[r].filter(\.isNumber)
            return max(1, Int(digits) ?? 1)
        }
        var raw: [[(isTH: Bool, text: String, rowspan: Int, colspan: Int)]] = []
        let ns = table as NSString
        for rowMatch in rowPattern.matches(in: table, range: NSRange(location: 0, length: ns.length)) {
            let rowHTML = group(rowMatch, 1, in: table)
            let rns = rowHTML as NSString
            let cells = cellPattern.matches(
                in: rowHTML, range: NSRange(location: 0, length: rns.length)
            ).map { m in
                let attrs = group(m, 2, in: rowHTML)
                return (
                    isTH: group(m, 1, in: rowHTML).lowercased() == "th",
                    text: cellText(group(m, 3, in: rowHTML)),
                    rowspan: span("rowspan", in: attrs),
                    colspan: span("colspan", in: attrs)
                )
            }
            if !cells.isEmpty { raw.append(cells) }
        }
        guard !raw.isEmpty else { return nil }
        let anyTH = raw.contains { $0.contains { $0.isTH } }
        let headerRows = raw[0].map(\.rowspan).max() ?? 1
        return raw.enumerated().map { (i, row) in
            row.map { c in
                TableCell(
                    runs: makeRuns(c.text),
                    isHeader: anyTH ? c.isTH : i < headerRows,
                    rowspan: c.rowspan,
                    colspan: c.colspan
                )
            }
        }
    }

    /// Grid width of `rows`: the widest row counting colspans. A lower
    /// bound when rowspans push cells right, which is fine for the
    /// minimum-size check callers use it for.
    static func columnCount(_ rows: [[TableCell]]) -> Int {
        rows.map { $0.reduce(0) { $0 + $1.colspan } }.max() ?? 0
    }

    static func plainRuns(_ text: String) -> [InlineRun] {
        text.isEmpty ? [] : [InlineRun(text)]
    }

    /// Cell content as plain text: `<br>` becomes a space, other tags
    /// are dropped, entities decoded, whitespace collapsed.
    static func cellText(_ raw: String) -> String {
        var t = raw.replacingOccurrences(
            of: #"<br\s*/?>"#, with: " ", options: [.regularExpression, .caseInsensitive]
        )
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        t = decodeEntities(t)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Block text as plain text for OCR observations: table cells and
    /// rows become spaces and newlines, other tags are dropped,
    /// entities decoded.
    static func plainText(_ markdown: String) -> String {
        var t = cleanMarkdown(markdown)
        t = t.replacingOccurrences(
            of: #"</t[dh]>"#, with: " ", options: [.regularExpression, .caseInsensitive]
        )
        t = t.replacingOccurrences(
            of: #"</tr>\s*|<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        t = decodeEntities(t)
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode the HTML entities an HTML table cell can carry: the five
    /// named XML ones, `&nbsp;`, and numeric `&#N;` / `&#xH;`.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = s[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<amp]
            let tail = rest[amp...]
            guard let semi = tail.firstIndex(of: ";"),
                  tail.distance(from: amp, to: semi) <= 10 else {
                out.append("&")
                rest = rest[rest.index(after: amp)...]
                continue
            }
            let name = String(tail[tail.index(after: amp)..<semi])
            var decoded: String?
            switch name {
            case "amp": decoded = "&"
            case "lt": decoded = "<"
            case "gt": decoded = ">"
            case "quot": decoded = "\""
            case "apos", "#39": decoded = "'"
            case "nbsp": decoded = "\u{00A0}"
            default:
                if name.hasPrefix("#x") || name.hasPrefix("#X"),
                   let v = UInt32(name.dropFirst(2), radix: 16),
                   let u = Unicode.Scalar(v) {
                    decoded = String(Character(u))
                } else if name.hasPrefix("#"),
                          let v = UInt32(name.dropFirst()),
                          let u = Unicode.Scalar(v) {
                    decoded = String(Character(u))
                }
            }
            if let decoded {
                out += decoded
                rest = rest[rest.index(after: semi)...]
            } else {
                out.append("&")
                rest = rest[rest.index(after: amp)...]
            }
        }
        out += rest
        return out
    }

    // MARK: - Cost

    /// Usage to record against `CloudModel.landingAIDPT3Pro`, which
    /// bills one synthetic output token per tenth of a credit
    /// ($0.001). Uses the credits the response reports; falls back to
    /// DPT-3 Pro's published sync rate (1 credit/page + 0.5 credits
    /// per 1,000 output characters, rounded up to 0.1 credit) when
    /// `metadata.billing` is missing.
    static func usage(for response: Response) -> Usage {
        let tenths: Int
        if let credits = response.metadata?.billing?.totalCredits {
            // Credits are billed in 0.1 steps; round to the nearest
            // tenth so float noise (1.1 × 10 = 11.000…02) doesn't
            // add a phantom tenth.
            tenths = Int((credits * 10).rounded())
        } else {
            let chars = Double(response.markdown?.unicodeScalars.count ?? 0)
            tenths = Int(((1 + 0.5 * chars / 1000) * 10).rounded(.up))
        }
        return Usage(inputTokens: 0, outputTokens: max(tenths, 0))
    }

    // MARK: - Multipart helpers

    private static func textField(
        name: String, value: String, boundary: String
    ) -> Data {
        var part = "--\(boundary)\r\n"
        part += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        part += "\(value)\r\n"
        return part.data(using: .utf8)!
    }

    private static func fileField(
        name: String,
        filename: String,
        mimeType: String,
        content: Data,
        boundary: String
    ) -> Data {
        var part = Data()
        var header = "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"\(name)\"; "
        header += "filename=\"\(filename)\"\r\n"
        header += "Content-Type: \(mimeType)\r\n\r\n"
        part.append(header.data(using: .utf8)!)
        part.append(content)
        part.append("\r\n".data(using: .utf8)!)
        return part
    }
}
