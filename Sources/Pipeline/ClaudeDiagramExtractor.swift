import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import Layout
import OCR

/// P-Diagram-Description Tier 1. Sonnet-driven alt-text generator
/// for `.picture` regions: crop the page raster to the region,
/// send the crop + any associated caption to Sonnet 4.6, and
/// return a short, screen-reader-ready description that
/// `RegionAwareReflow` swaps in for the bare `alt="figure"`
/// placeholder.
///
/// Returns `nil` (so the caller leaves the existing `alt`
/// unchanged) on:
///   * per-book budget exhausted,
///   * PNG encoding failure,
///   * network / API error,
///   * model refusal,
///   * empty / suspect response (refusal-style prose without
///     diagram content).
///
/// One Sonnet call per `.picture` region. Typical academic book
/// has 5-15 figures so per-book cost lands at $0.05-$0.15. The
/// per-book `CloudCallBudget` is the hard ceiling regardless.
public struct ClaudeDiagramExtractor: DiagramExtractor {
    public let client: AnthropicAPIClient
    public let budget: CloudCallBudget
    public var model: CloudModel
    public var maxOutputTokens: Int

    public init(
        client: AnthropicAPIClient,
        budget: CloudCallBudget,
        model: CloudModel = .sonnet4_6,
        // Short alt text + small headroom for Tier 2/3 once they
        // land. The system prompt caps the model at 120 chars
        // for Tier 1 output; 512 tokens covers that with room
        // for the future description / labels payload.
        maxOutputTokens: Int = 512
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    public func extract(
        pageImage: CGImage,
        regionBox: CGRect,
        captionText: String?,
        languages: [BCP47],
        stagingDir: URL,
        pageIndex: Int,
        regionIndex: Int
    ) async -> DiagramExtractionResult? {
        guard let cropped = RegionCascade.cropImage(pageImage, to: regionBox) else {
            return nil
        }
        guard await budget.tryConsume() else { return nil }
        try? Task.checkCancellation()

        guard let png = Self.encodePNG(cropped) else { return nil }
        let base64 = png.base64EncodedString()

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
            // Cache the system prompt. Diagrams average 5-15 per
            // book; within a single book the cache hits on every
            // call after the first.
            system: .cached(Self.systemPrompt, ttl: .oneHour),
            messages: [
                Message(role: .user, content: .blocks([
                    .image(mediaType: .png, base64Data: base64),
                    .text(Self.userPrompt(
                        captionText: captionText,
                        languages: languages
                    )),
                ])),
            ],
            // Pure description, no reasoning needed.
            thinking: .disabled
        )

        let response: AnthropicMessageResponse
        do {
            response = try await client.send(request)
        } catch {
            return nil
        }
        await budget.recordUsage(response.usage, for: model)

        if response.didRefuse { return nil }
        guard let raw = response.primaryText, !raw.isEmpty else { return nil }
        return Self.parseResponse(raw)
    }

    // MARK: - Prompt

    /// Stable system prompt — kept byte-stable across requests so
    /// the prefix is cacheable. Asks for a single short alt-text
    /// line, no surrounding prose.
    static let systemPrompt = """
        You generate short accessibility alt text for diagrams \
        and figures extracted from book pages. The image shows ONE \
        figure region — could be a chart, schematic, photograph, \
        anatomical illustration, flowchart, map, or other visual. \
        Return ONLY the alt text, in the format described below. \
        No preface, no commentary, no markdown fences.

        Output format — a single line, ≤ 120 characters, plain text.

        Rules:
          * Name the diagram TYPE specifically: "bar chart", \
        "scatter plot", "line graph", "flowchart", "anatomical \
        illustration", "schematic diagram", "photograph", "map", \
        "engraving", etc. Avoid generic "figure" / "image".
          * State the SUBJECT — what's depicted or what variables \
        are plotted. Be concrete: "marriage market supply and \
        demand", "rat brain coronal cross-section", "1923 \
        Manhattan street map".
          * For charts, include the axes' meanings when visible \
        ("with population on x-axis and wage rate on y-axis").
          * NO preambles. Never start with "This image shows", \
        "The figure depicts", "An illustration of", "A diagram \
        showing", etc. Lead with the diagram type or subject \
        directly.
          * NO speculation. If the image is unclear or you can't \
        tell what's depicted, return the empty string. The caller \
        treats empty as "fall back to the default alt='figure'" — \
        never invent content.
          * Decorative ornaments, page-edge flourishes, and chapter \
        opener illustrations without subject matter: return the \
        empty string.
          * Match the printed caption's framing when the user turn \
        provides one — don't invent a different topic than the \
        caption states. The caption is authoritative on the \
        SUBJECT; your job is to add visual-form detail \
        ("the bar chart [from caption] shows X on the x-axis…").
        """

    /// User-turn prompt; includes the caption text (when known)
    /// so the model's output stays consistent with the printed
    /// caption. Languages hint helps the model recognize axis
    /// labels in non-English typeset material.
    static func userPrompt(captionText: String?, languages: [BCP47]) -> String {
        var parts: [String] = []
        let trimmedCap = captionText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCap.isEmpty {
            parts.append("Printed caption: \(trimmedCap)")
        }
        let langCodes = languages.map(\.rawValue).joined(separator: ", ")
        if !langCodes.isEmpty {
            parts.append("Page languages: \(langCodes)")
        }
        parts.append("Describe the figure in this image as alt text.")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Sanitization

    /// Parse the model's response into a `DiagramExtractionResult`.
    /// Tier 1 only populates `altText`; Tier 2 (description) and
    /// Tier 3 (labels) extend this without changing the call site.
    ///
    /// Returns nil on empty / refusal-style responses so the
    /// caller leaves the default `alt="figure"` in place.
    static func parseResponse(_ raw: String) -> DiagramExtractionResult? {
        let stripped = stripCodeFence(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return nil }

        // Defensive: catch common refusal-style replies that
        // shouldn't get wrapped as alt text. The system prompt
        // tells the model to return empty when not a diagram,
        // but a hedged response sometimes leaks through —
        // "alt='I cannot describe this image'" would render in
        // screen readers as exactly that, which is worse than
        // the bare "figure" fallback.
        let lower = stripped.lowercased()
        let refusalPrefixes = [
            "i cannot", "i can't", "i am unable", "i'm unable",
            "sorry", "unable to",
        ]
        for prefix in refusalPrefixes where lower.hasPrefix(prefix) {
            return nil
        }

        // Strip the kind of preamble the prompt forbids but
        // models occasionally slip in anyway. Case-insensitive
        // match at the start of the string only.
        let preambles = [
            "this image shows ", "this figure shows ",
            "this image depicts ", "this figure depicts ",
            "an illustration of ", "a diagram showing ",
            "a diagram of ", "a figure showing ",
            "the image shows ", "the figure shows ",
            "the figure depicts ", "the image depicts ",
        ]
        var trimmed = stripped
        for preamble in preambles where trimmed.lowercased().hasPrefix(preamble) {
            trimmed = String(trimmed.dropFirst(preamble.count))
            // Capitalize the leading character so the alt text
            // reads as a sentence.
            if let first = trimmed.first {
                trimmed = first.uppercased() + trimmed.dropFirst()
            }
            break
        }

        // Cap at 120 chars defensively even when the prompt asks
        // for that — screen readers are slow when alt text gets
        // long, and a runaway response shouldn't degrade UX.
        let capped = trimmed.count <= 120
            ? trimmed
            : String(trimmed.prefix(117)) + "…"
        return DiagramExtractionResult(altText: capped)
    }

    /// Strip outer ```...``` fence (with optional language tag)
    /// from a model response. Conservative — only the outer fence
    /// comes off, internal content is left alone.
    static func stripCodeFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
            return trimmed
        }
        var lines = trimmed.split(
            separator: "\n", omittingEmptySubsequences: false
        )
        if !lines.isEmpty { lines.removeFirst() }
        if !lines.isEmpty,
           lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// PNG encode a CGImage for inline base64 transmission. Same
    /// shape as the other Claude extractors; duplicated rather
    /// than shared because the engines live in separate types.
    static func encodePNG(_ image: CGImage) -> Data? {
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
