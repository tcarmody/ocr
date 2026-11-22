import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import OCR

/// `OCREngine` impl backed by LandingAI's Agentic Document Extraction
/// Gen2 parse API (`POST /v2/parse`, DPT-3 Pro). Shares the `OCREngine`
/// shape with `GoogleDocumentOCREngine` so it can plug into
/// `RegionCascade` at the same tier as a cloud document-OCR alternative
/// — useful when Vision / Surya / Tesseract reject a region and the
/// user prefers LandingAI over Cloud Vision (or wants to A/B the two on
/// book-style pages with dense tables and figures, which is ADE's
/// strength). Also the transport under `LandingAIPageOCREngine`.
///
/// Wire shape (see `LandingAIParse`): multipart/form-data with a
/// `document` file part (PNG of the region), a `model` field
/// (`dpt-3-pro-latest` by default) and an `options` field. Auth is
/// `Authorization: Bearer <apikey>`. Each text-bearing block of the
/// response's `structure` tree becomes one observation with its own
/// box (converted to Vision's lower-left origin) and plain text —
/// HTML tables flattened to space-separated cells, one row per line.
/// When the tree is missing we fall back to the flat `markdown` as a
/// single observation spanning the whole image, as before. The
/// cascade translates boxes to full-page coords and runs the
/// guardrail comparison against the prior tier.
public struct LandingAIDocumentEngine: OCREngine, Sendable {
    public let apiKeyProvider: @Sendable () -> String?
    public let budget: CloudCallBudget
    public var baseURL: URL
    public var model: String
    public var requestTimeout: TimeInterval

    /// `baseURL` defaults to LandingAI's US Gen2 deployment
    /// (`https://api.ade.landing.ai`). EU users should pass
    /// `https://api.ade.eu-west-1.landing.ai` with an EU key — keys
    /// are deployment-specific. `model` is the parse model id;
    /// `dpt-3-pro-latest` follows new DPT-3 Pro snapshots — pin a
    /// dated snapshot (e.g. `dpt-3-pro-20260710`) when regression-
    /// testing against a known version.
    public init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        budget: CloudCallBudget,
        baseURL: URL = LandingAIParse.defaultBaseURL,
        model: String = LandingAIParse.defaultModel,
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
            case .http(401, let b):
                // Gen2 runs on a separate deployment; a key made for
                // the old Gen1 API may not be accepted there.
                return "LandingAI ADE HTTP 401: \(b ?? "") — check the API key; "
                    + "keys are created at ade.landing.ai (EU: ade.eu-west-1.landing.ai)."
            case .http(let s, let b): return "LandingAI ADE HTTP \(s): \(b ?? "")"
            case .decode(let m):      return "LandingAI ADE response decode: \(m)"
            case .underlying(let e):  return e.localizedDescription
            }
        }
    }

    public func recognize(image: CGImage, hints: OCRHints) async throws -> OCRResult {
        // Language hints are not part of the parse endpoint schema,
        // so `hints.languages` is intentionally ignored.
        let response = try await parse(image: image, filename: "region.png")
        let observations = Self.observations(from: response)
        let text = observations.map(\.text).joined(separator: "\n\n")
        guard !text.isEmpty else {
            throw DocumentOCRError.emptyResponse
        }
        let mean = observations.map(\.confidence).reduce(0, +)
            / Double(observations.count)
        return OCRResult(text: text, meanConfidence: mean, observations: observations)
    }

    /// One `POST /v2/parse` call: budget, request, status check,
    /// decode and cost recording. Shared by `recognize` and
    /// `LandingAIPageOCREngine`, which builds blocks from the
    /// structure tree.
    func parse(image: CGImage, filename: String) async throws -> LandingAIParse.Response {
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

        let request = LandingAIParse.makeRequest(
            baseURL: baseURL, apiKey: key, model: model,
            png: png, filename: filename, timeout: requestTimeout
        )

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

        // 2xx includes 206 (partial success: some pages failed). A
        // single-image request is one page, so a 206 here would carry
        // a failed page and empty markdown → `.emptyResponse` upstream.
        let envelope: LandingAIParse.Response
        do {
            envelope = try LandingAIParse.decode(data)
        } catch {
            throw DocumentOCRError.decode(String(describing: error))
        }

        // Record the credits LandingAI billed (tenths of a credit as
        // synthetic output tokens; see CloudModel.landingAIDPT3Pro).
        await budget.recordUsage(
            LandingAIParse.usage(for: envelope),
            for: .landingAIDPT3Pro
        )
        return envelope
    }

    /// Block types whose text is page content for OCR purposes.
    /// Figures, logos and scan codes carry descriptions or payloads,
    /// not transcribed text.
    static let textBlockTypes: Set<String> = [
        "text", "table", "marginalia", "card", "attestation",
    ]

    /// Observations from the structure tree: one per text-bearing
    /// block, in reading order, with its box converted from Gen2's
    /// top-left origin to Vision's lower-left. Falls back to the flat
    /// markdown as one full-image observation when the tree has no
    /// usable blocks.
    static func observations(from response: LandingAIParse.Response) -> [TextObservation] {
        let fromTree: [TextObservation] = response.blocks.compactMap { node in
            guard textBlockTypes.contains(node.type) else { return nil }
            let text = LandingAIParse.plainText(response.text(of: node))
            guard !text.isEmpty else { return nil }
            return TextObservation(
                text: text,
                confidence: 0.95,
                box: visionBox(node.grounding?.box),
                source: .claude
            )
        }
        if !fromTree.isEmpty { return fromTree }
        let flat = LandingAIParse.plainText(response.markdown ?? "")
        guard !flat.isEmpty else { return [] }
        return [TextObservation(
            text: flat,
            confidence: 0.95,
            box: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: .claude
        )]
    }

    /// Gen2 box (fractions, origin top-left, y down) → Vision rect
    /// (normalized, origin lower-left). Missing box → whole image.
    static func visionBox(_ box: LandingAIParse.Node.Box?) -> CGRect {
        guard let box else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let xmin = min(max(box.xmin, 0), 1), xmax = min(max(box.xmax, 0), 1)
        let ymin = min(max(box.ymin, 0), 1), ymax = min(max(box.ymax, 0), 1)
        return CGRect(
            x: xmin, y: 1 - max(ymin, ymax),
            width: abs(xmax - xmin), height: abs(ymax - ymin)
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
}
