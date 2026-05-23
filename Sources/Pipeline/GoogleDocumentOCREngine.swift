import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import OCR

/// `OCREngine` impl backed by Google Cloud Vision API's
/// `DOCUMENT_TEXT_DETECTION` feature. Slotted into `RegionCascade` as
/// Stage 2.5 (after Vision → Surya → Tesseract, before Claude) when
/// `processingMode == .cloud` and a Google Cloud Vision key is
/// configured.
///
/// Why this stage exists: hard-region OCR through Claude is the most
/// expensive tier in the cascade (~$0.012/call). Cloud Vision's
/// document OCR runs $0.0015/image and handles most of what Tesseract
/// rejects — degraded scans, skewed pages, low-contrast print —
/// before falling through to Claude for the genuinely hard tail
/// (polytonic Greek, Hebrew, vertical CJK). Expected effect: ~80%
/// cut in Stage 3 Claude calls on scan-heavy books with no measurable
/// quality loss.
///
/// Sends the cropped region image as base64; returns a single
/// observation spanning the input image's normalized bbox, same shape
/// `ClaudeOCREngine` produces. The cascade translates that to full-
/// page coords and runs the guardrail comparison against the prior
/// tier — same flow as the Claude stage.
public struct GoogleDocumentOCREngine: OCREngine, Sendable {
    public let apiKeyProvider: @Sendable () -> String?
    public let budget: CloudCallBudget
    public var baseURL: URL
    public var requestTimeout: TimeInterval

    public init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        budget: CloudCallBudget,
        baseURL: URL = URL(string: "https://vision.googleapis.com")!,
        requestTimeout: TimeInterval = 60
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.budget = budget
        self.baseURL = baseURL
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
            case .missingAPIKey:      return "Missing Google Cloud Vision API key."
            case .pngEncodeFailed:    return "Could not encode region image as PNG."
            case .emptyResponse:      return "Cloud Vision returned no text."
            case .http(let s, let b): return "Cloud Vision HTTP \(s): \(b ?? "")"
            case .decode(let m):      return "Cloud Vision response decode: \(m)"
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
        let base64 = png.base64EncodedString()

        let url = baseURL.appendingPathComponent("/v1/images:annotate")
        let body = RequestBody(requests: [
            AnnotateRequest(
                image: ImageEnvelope(content: base64),
                features: [Feature(type: "DOCUMENT_TEXT_DETECTION")],
                imageContext: ImageContext(
                    languageHints: hints.languages.map(\.rawValue)
                )
            )
        ])

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw DocumentOCRError.underlying(error)
        }

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
            let body = String(data: data, encoding: .utf8)
            throw DocumentOCRError.http(status: http.statusCode, body: body)
        }

        let envelope: ResponseBody
        do {
            envelope = try Self.decoder.decode(ResponseBody.self, from: data)
        } catch {
            throw DocumentOCRError.decode(String(describing: error))
        }

        // Record one synthetic output token per call so per-book cost
        // accounting attributes $0.0015 per request (see
        // AnthropicModel.pricing for the encoding).
        await budget.recordUsage(
            Usage(inputTokens: 0, outputTokens: 1),
            for: .googleDocumentOCR
        )

        let text = envelope.responses?.first?.fullTextAnnotation?.text ?? ""
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

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        let requests: [AnnotateRequest]
    }

    private struct AnnotateRequest: Encodable {
        let image: ImageEnvelope
        let features: [Feature]
        let imageContext: ImageContext
    }

    private struct ImageEnvelope: Encodable {
        let content: String
    }

    private struct Feature: Encodable {
        let type: String
    }

    private struct ImageContext: Encodable {
        let languageHints: [String]
    }

    private struct ResponseBody: Decodable {
        let responses: [AnnotateResponse]?
    }

    private struct AnnotateResponse: Decodable {
        let fullTextAnnotation: FullTextAnnotation?
    }

    private struct FullTextAnnotation: Decodable {
        let text: String?
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
