import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import OCR

/// `OCREngine` impl backed by Google Gemini Flash multimodal. Cascade-
/// tier per-region OCR sibling of `ClaudeOCREngine`; picked by
/// `pageOCRProvider == .gemini25Flash / .gemini3FlashPreview / .gemini35Flash`
/// so the same Settings choice that controls page-OCR routing also
/// controls which Cloud provider answers hard regions in the cascade.
///
/// Same posture as `ClaudeOCREngine`: gated behind `CloudCallBudget`,
/// guardrail-checked against the prior tier in `RegionCascade`. The
/// engine returns whatever Gemini transcribed; the cascade decides
/// whether to keep it.
///
/// Why Flash rather than Pro: per-region transcription is a tiny task
/// (a few hundred output tokens), and Flash quality on prose is
/// comparable to Sonnet at a fraction of the cost. Manuscript /
/// classical-script pages can opt up to Sonnet via the page-OCR
/// provider picker if a regression shows up.
public struct GeminiOCREngine: OCREngine {
    public let apiKeyProvider: @Sendable () -> String?
    public let budget: CloudCallBudget
    public var model: String
    public var maxOutputTokens: Int
    public var baseURL: URL
    public var requestTimeout: TimeInterval
    /// `generationConfig.thinkingConfig.thinkingLevel`. Pin to
    /// `"minimal"` on reasoning-capable Flash variants (3 / 3.5) so
    /// transcription doesn't pay for unused chain-of-thought tokens.
    /// `nil` on 2.5 Flash (no thinking config; field would fail
    /// validation).
    public var thinkingLevel: String?

    public init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        budget: CloudCallBudget,
        model: String = "gemini-2.5-flash",
        maxOutputTokens: Int = 4096,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
        requestTimeout: TimeInterval = 60,
        thinkingLevel: String? = nil
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
        self.thinkingLevel = thinkingLevel
    }

    public enum GeminiOCRError: Error, LocalizedError {
        case budgetExhausted
        case missingAPIKey
        case pngEncodeFailed
        case emptyResponse
        case http(status: Int, body: String?)
        case decode(String)
        case underlying(any Error)

        public var errorDescription: String? {
            switch self {
            case .budgetExhausted:     return "Per-book cloud call budget exhausted."
            case .missingAPIKey:       return "Missing Google AI Studio API key."
            case .pngEncodeFailed:     return "Could not encode region image as PNG."
            case .emptyResponse:       return "Gemini returned no text for this region."
            case .http(let s, let b):  return "Gemini HTTP \(s): \(b ?? "")"
            case .decode(let m):       return "Gemini response decode: \(m)"
            case .underlying(let e):   return e.localizedDescription
            }
        }
    }

    public func recognize(
        image: CGImage, hints: OCRHints
    ) async throws -> OCRResult {
        // Reserve budget before any work so a refused call doesn't
        // pay encode + base64 costs.
        guard await budget.tryConsume() else {
            throw GeminiOCRError.budgetExhausted
        }
        try Task.checkCancellation()

        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw GeminiOCRError.missingAPIKey
        }
        guard let png = Self.encodePNG(image) else {
            throw GeminiOCRError.pngEncodeFailed
        }
        let base64 = png.base64EncodedString()

        let url = baseURL.appendingPathComponent(
            "/v1beta/models/\(model):generateContent"
        )
        let body = RequestBody(
            systemInstruction: SystemInstruction(parts: [
                TextPart(text: ClaudeOCREngine.systemPrompt)
            ]),
            contents: [
                Content(parts: [
                    Part(
                        inlineData: InlineData(
                            mimeType: "image/png", data: base64
                        ),
                        text: nil
                    ),
                    Part(
                        inlineData: nil,
                        text: ClaudeOCREngine.userPromptForLanguages(hints.languages)
                    ),
                ])
            ],
            generationConfig: GenerationConfig(
                maxOutputTokens: maxOutputTokens,
                temperature: 0.1,
                thinkingConfig: thinkingLevel.map {
                    ThinkingConfig(thinkingLevel: $0)
                }
            )
        )

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw GeminiOCRError.underlying(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GeminiOCRError.underlying(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GeminiOCRError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw GeminiOCRError.http(status: http.statusCode, body: body)
        }

        let envelope: ResponseBody
        do {
            envelope = try Self.decoder.decode(ResponseBody.self, from: data)
        } catch {
            throw GeminiOCRError.decode(String(describing: error))
        }
        if let usage = envelope.usageMetadata {
            await budget.recordUsage(
                Usage(
                    inputTokens: usage.promptTokenCount ?? 0,
                    outputTokens: usage.candidatesTokenCount ?? 0
                ),
                for: CloudModel(rawValue: model)
            )
        }

        // SAFETY / RECITATION / etc. finish reasons with no text:
        // treat the same as empty so the cascade keeps the prior
        // tier instead of replacing it with garbage.
        let candidate = envelope.candidates?.first
        let parts = candidate?.content?.parts ?? []
        let text = parts.compactMap { $0.text }.joined()
        guard !text.isEmpty else {
            throw GeminiOCRError.emptyResponse
        }

        // One observation per call — Gemini doesn't return per-line
        // bboxes for inline text. Wrap the transcription as a single
        // observation filling the input image's normalized bbox.
        // `source: .claude` is a slight misnomer (it covers both
        // cloud providers since the cascade's downstream logic
        // doesn't distinguish), preserved for compatibility with
        // existing observation-source counting.
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

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    // MARK: - Wire types
    //
    // Same shape as `GeminiPageOCREngine`'s inner types. Duplicated
    // rather than shared because (1) the wire types are tiny, (2)
    // factoring them out would create cross-file coupling that the
    // type system can't otherwise see, and (3) the engines have
    // independent lifecycles (Page OCR ships first / drives prompt
    // changes; region OCR follows). When a third site needs the
    // same shape, pull the types up.

    private struct RequestBody: Encodable {
        let systemInstruction: SystemInstruction
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    private struct SystemInstruction: Encodable {
        let parts: [TextPart]
    }

    private struct TextPart: Encodable {
        let text: String
    }

    private struct Content: Encodable {
        let parts: [Part]
    }

    private struct Part: Encodable {
        let inlineData: InlineData?
        let text: String?

        enum CodingKeys: String, CodingKey {
            case inlineData = "inline_data"
            case text
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let d = inlineData { try c.encode(d, forKey: .inlineData) }
            if let t = text { try c.encode(t, forKey: .text) }
        }
    }

    private struct InlineData: Encodable {
        let mimeType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case data
        }
    }

    private struct GenerationConfig: Encodable {
        let maxOutputTokens: Int
        let temperature: Double
        let thinkingConfig: ThinkingConfig?

        enum CodingKeys: String, CodingKey {
            case maxOutputTokens, temperature, thinkingConfig
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(maxOutputTokens, forKey: .maxOutputTokens)
            try c.encode(temperature, forKey: .temperature)
            if let t = thinkingConfig {
                try c.encode(t, forKey: .thinkingConfig)
            }
        }
    }

    private struct ThinkingConfig: Encodable {
        let thinkingLevel: String
    }

    private struct ResponseBody: Decodable {
        let candidates: [Candidate]?
        let usageMetadata: UsageMetadata?
    }

    private struct Candidate: Decodable {
        let content: CandidateContent?
        let finishReason: String?
    }

    private struct CandidateContent: Decodable {
        let parts: [CandidatePart]?
    }

    private struct CandidatePart: Decodable {
        let text: String?
    }

    private struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
    }
}
