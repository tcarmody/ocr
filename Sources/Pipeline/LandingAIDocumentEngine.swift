import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import OCR

/// `OCREngine` impl backed by LandingAI's Agentic Document Extraction
/// (`POST /v1/ade/parse`). Prototype: shares the `OCREngine` shape with
/// `GoogleDocumentOCREngine` so it can plug into `RegionCascade` at the
/// same tier as a cloud document-OCR alternative — useful when Vision /
/// Surya / Tesseract reject a region and the user prefers LandingAI over
/// Cloud Vision (or wants to A/B the two on book-style pages with
/// dense tables and figures, which is ADE's strength).
///
/// Wire shape: multipart/form-data with a `document` file part (PNG of
/// the region) and an optional `model` string field (`dpt-2-latest` by
/// default). Auth is `Authorization: Bearer <apikey>`. Response is JSON;
/// we pull `markdown` as the recognized text and surface it as a single
/// observation spanning the input image's normalized bbox — same posture
/// as `GoogleDocumentOCREngine`. The cascade translates that to full-
/// page coords and runs the guardrail comparison against the prior tier.
///
/// Not yet wired into `RegionCascade` / `PipelineEngineFactories` — that
/// requires a new `cloudFeatures.landingAIInCascade` toggle, a stage
/// slot in `PipelineCascadeLoop`, and a `CostEstimator` case. This
/// prototype is the engine itself; wiring follows in a separate change.
public struct LandingAIDocumentEngine: OCREngine, Sendable {
    public let apiKeyProvider: @Sendable () -> String?
    public let budget: CloudCallBudget
    public var baseURL: URL
    public var model: String
    public var requestTimeout: TimeInterval

    /// `baseURL` defaults to LandingAI's production endpoint. EU users
    /// should pass `https://api.va.eu-west-1.landing.ai`. `model` is
    /// the parsing model id (e.g. `dpt-2-latest`); LandingAI documents
    /// `dpt-2-latest` as the current default — pin a specific revision
    /// here if regression-testing against a known version.
    public init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        budget: CloudCallBudget,
        baseURL: URL = URL(string: "https://api.va.landing.ai")!,
        model: String = "dpt-2-latest",
        requestTimeout: TimeInterval = 120
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.budget = budget
        self.baseURL = baseURL
        self.model = model
        self.requestTimeout = requestTimeout
    }

    public enum DocumentOCRError: Error, LocalizedError {
        case budgetExhausted
        case missingAPIKey
        case pngEncodeFailed
        case emptyResponse
        case http(status: Int, body: String?)
        case decode(String)
        case underlying(any Error)

        public var errorDescription: String? {
            switch self {
            case .budgetExhausted:    return "Per-book call budget exhausted."
            case .missingAPIKey:      return "Missing LandingAI ADE API key."
            case .pngEncodeFailed:    return "Could not encode region image as PNG."
            case .emptyResponse:      return "LandingAI ADE returned no markdown."
            case .http(let s, let b): return "LandingAI ADE HTTP \(s): \(b ?? "")"
            case .decode(let m):      return "LandingAI ADE response decode: \(m)"
            case .underlying(let e):  return e.localizedDescription
            }
        }
    }

    public func recognize(image: CGImage, hints: OCRHints) async throws -> OCRResult {
        guard await budget.tryConsume() else {
            throw DocumentOCRError.budgetExhausted
        }
        try Task.checkCancellation()

        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw DocumentOCRError.missingAPIKey
        }
        guard let png = Self.encodePNG(image) else {
            throw DocumentOCRError.pngEncodeFailed
        }

        // Multipart body. The Python SDK posts the `document` field as
        // the file part and `model` as a plain text field; we mirror
        // that. Language hints are not part of the parse endpoint
        // schema, so `hints.languages` is intentionally ignored.
        let boundary = "Boundary-" + UUID().uuidString
        var body = Data()
        body.append(Self.multipartTextField(
            name: "model", value: model, boundary: boundary
        ))
        body.append(Self.multipartFileField(
            name: "document",
            filename: "region.png",
            mimeType: "image/png",
            content: png,
            boundary: boundary
        ))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let url = baseURL.appendingPathComponent("/v1/ade/parse")
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw DocumentOCRError.underlying(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DocumentOCRError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            throw DocumentOCRError.http(status: http.statusCode, body: bodyStr)
        }

        let envelope: ParseResponse
        do {
            envelope = try Self.decoder.decode(ParseResponse.self, from: data)
        } catch {
            throw DocumentOCRError.decode(String(describing: error))
        }

        // Record one synthetic output token per call so per-book cost
        // accounting can attribute the per-page rate (see
        // AnthropicModel.pricing.landingAIDocumentExtraction).
        await budget.recordUsage(
            Usage(inputTokens: 0, outputTokens: 1),
            for: .landingAIDocumentExtraction
        )

        let text = envelope.markdown ?? ""
        guard !text.isEmpty else {
            throw DocumentOCRError.emptyResponse
        }

        let observation = TextObservation(
            text: text,
            confidence: 0.95,
            box: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: .claude
        )
        return OCRResult(
            text: text,
            meanConfidence: 0.95,
            observations: [observation]
        )
    }

    // MARK: - Helpers

    private static func encodePNG(_ image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }

    private static func multipartTextField(
        name: String, value: String, boundary: String
    ) -> Data {
        var part = "--\(boundary)\r\n"
        part += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        part += "\(value)\r\n"
        return part.data(using: .utf8)!
    }

    private static func multipartFileField(
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

    // MARK: - Wire types
    //
    // Decode only the fields we use. ADE's `ParseResponse` also carries
    // `chunks`, `splits`, `metadata`, and `grounding`; downstream code
    // in the cascade just wants flat text, and the `markdown` field is
    // the most faithful representation of that.

    private struct ParseResponse: Decodable {
        let markdown: String?
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
