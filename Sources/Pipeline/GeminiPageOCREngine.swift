import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import OCR

/// `PageOCREngine` impl backed by Google Gemini 2.5 Flash via the
/// Generative Language API. Drop-in alternative to `ClaudePageOCREngine`
/// for the typeset / early-print path; manuscript still routes to Opus.
/// Same XHTML output contract, parsed by `PageXHTMLParser`.
///
/// Why Flash rather than Pro: on prose pages quality is effectively a
/// wash with Sonnet, and per-page cost runs ~$0.005 vs Sonnet's $0.04.
/// On a 400-page book that's $2 vs $17. Quality drops vs Sonnet on the
/// hardest layouts (heavy marginalia, dense multi-column footnotes)
/// — users with those workloads should keep Claude selected.
///
/// Prompt caching is Anthropic-only (the Messages API's
/// `cache_control` doesn't exist on Gemini). Batch API is now wired
/// for both providers via separate dispatchers. Per-book call budget
/// is the provider-agnostic `CloudCallBudget`.
public struct GeminiPageOCREngine: PageOCREngine, Sendable {
    public var providerId: String { model }

    public let apiKeyProvider: @Sendable () -> String?
    public let budget: CloudCallBudget
    public var model: String
    public var maxOutputTokens: Int
    public var captureSink: ClaudePageOCREngine.CaptureSink?
    public var baseURL: URL
    public var requestTimeout: TimeInterval
    /// Optional `thinking_level` value passed under `thinkingConfig`
    /// in the generation config. Gemini 3 Flash and newer reasoning
    /// models default to non-zero thinking, which inflates output
    /// token count without helping pure transcription. Pin to
    /// `"minimal"` for OCR. Nil for 2.5 Flash (no reasoning to
    /// disable; field is ignored / would fail validation on older
    /// models).
    public var thinkingLevel: String?

    public init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        budget: CloudCallBudget,
        model: String = "gemini-2.5-flash",
        maxOutputTokens: Int = 8192,
        captureSink: ClaudePageOCREngine.CaptureSink? = nil,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
        requestTimeout: TimeInterval = 120,
        thinkingLevel: String? = nil
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
        self.captureSink = captureSink
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
        self.thinkingLevel = thinkingLevel
    }

    public enum PageOCRError: Error, LocalizedError {
        case budgetExhausted
        case missingAPIKey
        case pngEncodeFailed
        /// Gemini returned `finishReason: SAFETY` / `RECITATION` /
        /// other policy-decline reasons with no text parts.
        case refused
        /// Response decoded but yielded no text — model hiccup,
        /// not a refusal.
        case empty
        case http(status: Int, body: String?)
        case decode(String)
        case underlying(any Error)

        public var errorDescription: String? {
            switch self {
            case .budgetExhausted:     return "Per-book call budget exhausted."
            case .missingAPIKey:       return "Missing Google AI Studio API key."
            case .pngEncodeFailed:     return "Could not encode page image as PNG."
            case .refused:             return "Gemini refused to transcribe this page."
            case .empty:               return "Gemini returned no text for this page."
            case .http(let s, let b):  return "Gemini HTTP \(s): \(b ?? "")"
            case .decode(let m):       return "Gemini response decode: \(m)"
            case .underlying(let e):   return e.localizedDescription
            }
        }
    }

    public func classify(error: any Error) -> ProviderStatus {
        if error is CancellationError { return .canceled }
        guard let e = error as? PageOCRError else { return .apiError }
        switch e {
        case .budgetExhausted: return .budgetExhausted
        case .refused:         return .refused
        case .empty:           return .empty
        case .http(let status, _):
            // 429 is throttling; everything else is API trouble.
            return status == 429 ? .rateLimited : .apiError
        case .missingAPIKey, .pngEncodeFailed, .decode, .underlying:
            return .apiError
        }
    }

    private func capture(
        pageIndex: Int, raw: String, parseEmpty: Bool
    ) {
        captureSink?(ClaudePageOCREngine.CapturedResponse(
            pageIndex: pageIndex,
            rawXHTML: raw,
            parsedBlocksEmpty: parseEmpty
        ))
    }

    public func recognize(
        pageImage: CGImage,
        pageIndex: Int,
        languages: [BCP47]
    ) async throws -> ClaudePageResult {
        guard await budget.tryConsume() else {
            throw PageOCRError.budgetExhausted
        }
        try Task.checkCancellation()
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw PageOCRError.missingAPIKey
        }
        guard let (png, _) = Self.encodeForGemini(pageImage) else {
            throw PageOCRError.pngEncodeFailed
        }
        let base64 = png.base64EncodedString()

        let url = baseURL.appendingPathComponent(
            "/v1beta/models/\(model):generateContent"
        )
        let body = RequestBody(
            systemInstruction: SystemInstruction(parts: [
                TextPart(text: Self.systemPrompt)
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
                        text: Self.userPromptForLanguages(languages)
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
            throw PageOCRError.underlying(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            capture(
                pageIndex: pageIndex,
                raw: "[SEND FAILED: \(error)]",
                parseEmpty: true
            )
            throw PageOCRError.underlying(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PageOCRError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            capture(
                pageIndex: pageIndex,
                raw: "[API ERROR \(http.statusCode): \(body ?? "")]",
                parseEmpty: true
            )
            throw PageOCRError.http(status: http.statusCode, body: body)
        }

        let envelope: ResponseBody
        do {
            envelope = try Self.decoder.decode(ResponseBody.self, from: data)
        } catch {
            capture(
                pageIndex: pageIndex,
                raw: "[DECODE FAILED: \(error)]",
                parseEmpty: true
            )
            throw PageOCRError.decode(String(describing: error))
        }

        if let usage = envelope.usageMetadata {
            // Attribute usage to the actual model so cost rolls up
            // correctly when the user picks 3 Flash preview (different
            // rates from 2.5 Flash).
            await budget.recordUsage(
                Usage(
                    inputTokens: usage.promptTokenCount ?? 0,
                    outputTokens: usage.candidatesTokenCount ?? 0
                ),
                for: CloudModel(rawValue: model)
            )
        }

        // Gemini returns finishReason="SAFETY" or "RECITATION" with no
        // parts on a refusal. Treat the same as Claude's `.didRefuse`.
        let candidate = envelope.candidates?.first
        let finishReason = candidate?.finishReason ?? ""
        let parts = candidate?.content?.parts ?? []
        let text = parts.compactMap { $0.text }.joined()

        if text.isEmpty {
            // SAFETY / RECITATION / PROHIBITED_CONTENT are Gemini's
            // refusal-shaped finish reasons. STOP / MAX_TOKENS / OTHER
            // with empty text are non-refusal "no output" cases —
            // classify as empty so the refusal-rate stat stays clean.
            let refusalReasons: Set<String> = [
                "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST"
            ]
            let upper = finishReason.uppercased()
            if refusalReasons.contains(upper) {
                capture(
                    pageIndex: pageIndex,
                    raw: "[REFUSED: \(finishReason)]",
                    parseEmpty: true
                )
                throw PageOCRError.refused
            }
            let marker = finishReason.isEmpty ? "[EMPTY]" : "[FINISH: \(finishReason)]"
            capture(pageIndex: pageIndex, raw: marker, parseEmpty: true)
            throw PageOCRError.empty
        }

        // Gemini sometimes wraps the XHTML in a ```xml or ```html
        // fenced block despite the prompt asking for raw fragments.
        // Strip those so the parser sees clean XHTML.
        let xhtml = Self.stripCodeFence(text)

        let parser = PageXHTMLParser()
        let result = parser.parse(xhtml, pageIndex: pageIndex)
        capture(
            pageIndex: pageIndex, raw: xhtml,
            parseEmpty: result.blocks.isEmpty
        )
        return result
    }

    // MARK: - Batch helpers (P-Gemini-Batch)

    /// Build one batch-API entry for the given page image. Returns
    /// nil on PNG encode failure. The caller serializes a sequence
    /// of these to JSONL bytes and uploads via
    /// `GeminiBatchAPIClient.uploadJSONL`. Each entry carries a
    /// `metadata.key` of the form `"page-NNNNN"` matching the
    /// Anthropic `custom_id` convention so the result-walk loop
    /// can share the page-index extractor.
    public func buildBatchEntryData(
        pageImage: CGImage, languages: [BCP47], pageIndex: Int
    ) -> Data? {
        guard let (png, _) = Self.encodeForGemini(pageImage) else { return nil }
        let base64 = png.base64EncodedString()
        let body = RequestBody(
            systemInstruction: SystemInstruction(parts: [
                TextPart(text: Self.systemPrompt)
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
                        text: Self.userPromptForLanguages(languages)
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
        let key = String(format: "page-%05d", pageIndex)
        let entry = BatchEntry(request: body, metadata: .init(key: key))
        return try? Self.encoder.encode(entry)
    }

    /// JSONL envelope for one batch entry. Wraps the same
    /// `RequestBody` the sync path sends, plus the per-entry
    /// `metadata.key` Google uses to correlate results.
    private struct BatchEntry: Encodable {
        let request: RequestBody
        let metadata: Metadata

        struct Metadata: Encodable {
            let key: String
        }
    }

    /// Parse the raw `response` sub-object JSON from a Gemini
    /// batch result line. Returns the parsed `ClaudePageResult`
    /// on success, plus a `ProviderStatus` describing what
    /// happened — `succeeded` / `refused` / `empty` / `apiError`
    /// so the dispatch loop can roll up refusal-rate stats the
    /// same way the sync path does. Records token usage against
    /// the per-book budget along the way.
    public func parseBatchResponseOutcome(
        rawJSON: Data, pageIndex: Int
    ) async -> (result: ClaudePageResult?, status: ProviderStatus) {
        let envelope: ResponseBody
        do {
            envelope = try Self.decoder.decode(
                ResponseBody.self, from: rawJSON
            )
        } catch {
            capture(
                pageIndex: pageIndex,
                raw: "[BATCH DECODE FAILED: \(error)]",
                parseEmpty: true
            )
            return (nil, .apiError)
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
        let finishReason = candidate?.finishReason ?? ""
        let parts = candidate?.content?.parts ?? []
        let text = parts.compactMap { $0.text }.joined()
        if text.isEmpty {
            let refusalReasons: Set<String> = [
                "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST"
            ]
            let upper = finishReason.uppercased()
            if refusalReasons.contains(upper) {
                capture(
                    pageIndex: pageIndex,
                    raw: "[REFUSED: \(finishReason)]",
                    parseEmpty: true
                )
                return (nil, .refused)
            }
            let marker = finishReason.isEmpty
                ? "[EMPTY]" : "[FINISH: \(finishReason)]"
            capture(pageIndex: pageIndex, raw: marker, parseEmpty: true)
            return (nil, .empty)
        }
        let xhtml = Self.stripCodeFence(text)
        let parser = PageXHTMLParser()
        let result = parser.parse(xhtml, pageIndex: pageIndex)
        capture(
            pageIndex: pageIndex,
            raw: xhtml,
            parseEmpty: result.blocks.isEmpty
        )
        return (result, .succeeded)
    }

    // MARK: - Prompts (mirror ClaudePageOCREngine.baseSystemPrompt)

    static let systemPrompt = ClaudePageOCREngine.baseSystemPrompt

    static func userPromptForLanguages(_ languages: [BCP47]) -> String {
        ClaudePageOCREngine.userPromptForLanguages(languages)
    }

    // MARK: - Helpers

    /// Strip leading/trailing Markdown code fences if the model wrapped
    /// the output in ```xml … ``` or ```html … ```. Safe no-op on
    /// already-clean fragments.
    static func stripCodeFence(_ s: String) -> String {
        var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

    /// Gemini accepts inline image data up to ~20 MB and auto-handles
    /// resolution well into the multi-thousand-pixel range. We still
    /// cap the long edge at 1568 px (same as Anthropic) to keep tokens
    /// bounded; Gemini's image token count grows with resolution past
    /// ~1568 even though the input limit allows larger.
    private static let preferredMaxDim: Int = 1568
    private static let minMaxDim: Int = 768
    private static let maxBase64Bytes: Int = 18 * 1024 * 1024  // headroom under 20 MB

    static func encodeForGemini(_ image: CGImage) -> (data: Data, longEdge: Int)? {
        let initialDim = max(image.width, image.height)
        var targetDim = min(initialDim, preferredMaxDim)
        var current = downsize(image, longEdge: targetDim)
        while true {
            guard let png = encodePNG(current) else { return nil }
            if png.count <= maxBase64Bytes {
                return (png, max(current.width, current.height))
            }
            let nextDim = max(targetDim / 2, minMaxDim)
            if nextDim == targetDim {
                return (png, max(current.width, current.height))
            }
            targetDim = nextDim
            current = downsize(image, longEdge: targetDim)
        }
    }

    private static func downsize(_ image: CGImage, longEdge: Int) -> CGImage {
        let w = image.width
        let h = image.height
        let larger = max(w, h)
        if larger <= longEdge { return image }
        let scale = CGFloat(longEdge) / CGFloat(larger)
        let newW = max(1, Int((CGFloat(w) * scale).rounded()))
        let newH = max(1, Int((CGFloat(h) * scale).rounded()))
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = newW * 4
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    // MARK: - Wire types

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
            case maxOutputTokens, temperature
            case thinkingConfig
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(maxOutputTokens, forKey: .maxOutputTokens)
            try c.encode(temperature, forKey: .temperature)
            // Only emit `thinkingConfig` when set — sending it on
            // models that don't support `thinking_level` (e.g. 2.5
            // Flash) would fail request validation.
            if let t = thinkingConfig {
                try c.encode(t, forKey: .thinkingConfig)
            }
        }
    }

    /// `generationConfig.thinkingConfig` for Gemini 3-series reasoning
    /// models. `thinkingLevel` accepts `"minimal"` / `"low"` /
    /// `"medium"` / `"high"`; `"minimal"` matches the "no thinking"
    /// posture and minimizes both latency and output token count for
    /// pure-transcription tasks.
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

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
