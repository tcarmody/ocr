import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import OCR

/// `TableExtractor` impl backed by Google Gemini Flash multimodal.
/// Sibling of `ClaudeTableExtractor`; picked alongside
/// `GeminiOCREngine` whenever the user's `pageOCRProvider` is one of
/// the Gemini Flash variants. Same JSON-grid output schema as the
/// Claude path so downstream `TableCell`-consuming code doesn't
/// branch on provider.
///
/// Why Flash here: table extraction is per-table (rare — ~0.5 per
/// book in the cost-estimator model), vision-heavy, and the
/// structural schema is the same shape Sonnet returns. Per-table
/// cost runs single-digit cents on Flash vs ~$0.04 on Sonnet, and
/// quality differences haven't shown up on typeset prose tables.
/// Highly complex multi-row-header tables may still prefer Sonnet —
/// the page-OCR provider picker is the user's lever there.
public struct GeminiTableExtractor: TableExtractor {
    public let apiKeyProvider: @Sendable () -> String?
    public let budget: CloudCallBudget
    public var model: String
    public var maxOutputTokens: Int
    public var baseURL: URL
    public var requestTimeout: TimeInterval
    /// `generationConfig.thinkingConfig.thinkingLevel`. Pinned to
    /// `"minimal"` on reasoning-capable Flash variants (3 / 3.5);
    /// nil on 2.5 Flash. Tables benefit even less from CoT than
    /// pure transcription does — the schema is fixed JSON.
    public var thinkingLevel: String?

    public init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        budget: CloudCallBudget,
        model: String = "gemini-2.5-flash",
        // Tables can carry a lot of cell text; budget output
        // tokens generously. A 10×6 academic table at ~30 chars/
        // cell still fits well under 4K, but multi-paragraph
        // cells push higher.
        maxOutputTokens: Int = 4096,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
        requestTimeout: TimeInterval = 120,
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

    public func extract(
        pageImage: CGImage,
        regionBox: CGRect,
        observations: [TextObservation],
        stagingDir: URL,
        pageIndex: Int,
        regionIndex: Int
    ) async -> [[TableCell]]? {
        guard let cropped = RegionCascade.cropImage(pageImage, to: regionBox) else {
            return nil
        }
        guard await budget.tryConsume() else { return nil }
        try? Task.checkCancellation()

        guard let key = apiKeyProvider(), !key.isEmpty else { return nil }
        guard let png = Self.encodePNG(cropped) else { return nil }
        let base64 = png.base64EncodedString()

        let url = baseURL.appendingPathComponent(
            "/v1beta/models/\(model):generateContent"
        )
        // Same prompt as `ClaudeTableExtractor` (loaded via that
        // engine's `systemPrompt` / `userPrompt`) so the JSON schema
        // is byte-identical across providers and the shared parser
        // handles either response.
        let body = RequestBody(
            systemInstruction: SystemInstruction(parts: [
                TextPart(text: ClaudeTableExtractor.systemPrompt)
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
                        text: ClaudeTableExtractor.userPrompt
                    ),
                ])
            ],
            generationConfig: GenerationConfig(
                maxOutputTokens: maxOutputTokens,
                temperature: 0.0,
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
            return nil
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return nil
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        let envelope: ResponseBody
        do {
            envelope = try Self.decoder.decode(ResponseBody.self, from: data)
        } catch {
            return nil
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

        let candidate = envelope.candidates?.first
        let parts = candidate?.content?.parts ?? []
        let raw = parts.compactMap { $0.text }.joined()
        guard !raw.isEmpty else { return nil }

        // Reuse the shared parser — same JSON wire format on both
        // providers.
        guard let rows = ClaudeTableExtractor.parseRows(from: raw) else {
            return nil
        }
        let maxCols = rows.map(\.count).max() ?? 0
        guard rows.count >= TableHeuristic.minRows,
              maxCols >= TableHeuristic.minCols else {
            return nil
        }
        return rows
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
    // Same shape as `GeminiOCREngine`'s inner types. Duplication is
    // acceptable: each engine's wire layer is small + private, and
    // pulling it up creates cross-file coupling that the type system
    // can't otherwise see.

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
