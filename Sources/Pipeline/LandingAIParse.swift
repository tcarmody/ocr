import Foundation
import AI

/// Shared wire layer for LandingAI's ADE Gen2 parse API (DPT-3),
/// used by `LandingAIDocumentEngine` (cascade region OCR + page OCR)
/// and `LandingAITableExtractor`.
///
/// Gen2 replaced the Gen1 `POST https://api.va.landing.ai/v1/ade/parse`
/// (DPT-2) with `POST https://api.ade.landing.ai/v2/parse`. The request
/// is still multipart/form-data with a `document` file part, a `model`
/// field and Bearer auth; the response is a redesign — `chunks`,
/// per-chunk markdown and the top-level `grounding` map are gone in
/// favour of a `structure` tree. We read only the top-level `markdown`
/// string (still the whole document in reading order) and the billing
/// metadata, so the rest of the pipeline is unaffected.
///
/// Gen2 markdown differs from Gen1 in ways the callers care about:
///   * tables default to HTML `<table>` markup — we send
///     `options.blocks.table.format = "markdown"` so the existing
///     pipe-table parsers keep working (merged cells expand into
///     empty neighbours, as before);
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

    /// Ask for pipe-syntax tables instead of the HTML default.
    static let optionsJSON = #"{"blocks":{"table":{"format":"markdown"}}}"#

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
