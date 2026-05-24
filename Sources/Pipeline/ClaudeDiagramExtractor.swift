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
        figureImage: CGImage,
        captionText: String?,
        languages: [BCP47],
        pageIndex: Int,
        regionIndex: Int
    ) async -> DiagramExtractionResult? {
        guard await budget.tryConsume() else { return nil }
        try? Task.checkCancellation()

        guard let png = Self.encodePNG(figureImage) else { return nil }
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
    /// the prefix is cacheable. Asks for alt text + longer
    /// description in a two-part response separated by a sentinel.
    static let systemPrompt = """
        You generate accessibility metadata for diagrams and \
        figures extracted from book pages. The image shows ONE \
        figure region — could be a chart, schematic, photograph, \
        anatomical illustration, flowchart, map, or other visual. \
        Return ONLY the metadata in the format described below. \
        No preface, no commentary, no markdown fences.

        Output format — three parts separated by literal \
        `---DESCRIPTION---` and `---LABELS---` lines on their own:

        <alt text — single line, ≤ 120 characters>
        ---DESCRIPTION---
        <longer description — 1-3 sentences, ≤ 500 characters>
        ---LABELS---
        - <label 1>
        - <label 2>
        - <label 3>

        First part (ALT TEXT) rules:
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
          * Match the printed caption's framing when the user turn \
        provides one — don't invent a different topic than the \
        caption states.

        Second part (DESCRIPTION) rules:
          * 1-3 complete sentences. Aim for 150-400 characters; \
        hard cap at 500.
          * Describe what's visible in MORE DETAIL than the alt \
        text affords — region structure, layout, labeled \
        elements, value ranges, geometric relationships. The \
        goal is text a chat / search index can hit on queries \
        about the diagram's content.
          * Stay factual and visible: only describe what's actually \
        rendered. No interpretation, no inferred meaning, no \
        "this represents…" speculation.
          * NO preambles for this part either — start with a noun \
        phrase ("A bar chart with…", "Two-axis plot showing…").

        Third part (LABELS) rules:
          * One label per line, leading "- ". Each label is a \
        verbatim transcription of a text string that appears \
        INSIDE the diagram — axis labels, callouts, legend \
        entries, anatomical part names, flowchart node text. \
        At most 12 labels; omit minor / decorative text.
          * Transcribe characters as printed (preserve case, \
        diacritics, math symbols). Do NOT translate, expand \
        abbreviations, or paraphrase.
          * If the diagram has no readable in-image text, leave \
        this part empty — just the `---LABELS---` separator with \
        no lines after it.

        If the image is unclear, decorative-only, or you cannot \
        tell what's depicted, return the empty string for ALL \
        three parts (i.e. just the two separator lines on their \
        own, with no content before or between or after). The \
        caller treats empty as "fall back to the default \
        alt='figure'" — never invent content.
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

    /// Parse the model's three-part response into a
    /// `DiagramExtractionResult`. Tier 1 populates `altText`,
    /// Tier 2 adds `description`, Tier 3 adds `labels`. Tier 2 /
    /// Tier 3 sections are optional — a partial response (no
    /// separator, or `---DESCRIPTION---` without
    /// `---LABELS---`) still surfaces whatever it has.
    ///
    /// Returns nil on empty / refusal-style alt-text responses
    /// so the caller leaves the default `alt="figure"` in place.
    static func parseResponse(_ raw: String) -> DiagramExtractionResult? {
        let stripped = stripCodeFence(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return nil }

        // Split on the description separator first, then on the
        // labels separator within the post-description chunk.
        let (head, afterDesc) = splitOnce(stripped, anyOf: [
            "\n---DESCRIPTION---\n",
            "\n---DESCRIPTION---",
            "---DESCRIPTION---\n",
            "---DESCRIPTION---",
        ])
        let descChunk: String?
        let labelsChunk: String?
        if let afterDesc {
            let (d, l) = splitOnce(afterDesc, anyOf: [
                "\n---LABELS---\n",
                "\n---LABELS---",
                "---LABELS---\n",
                "---LABELS---",
            ])
            descChunk = d.isEmpty ? nil : d
            labelsChunk = l
        } else {
            descChunk = nil
            labelsChunk = nil
        }

        guard let altText = sanitizeAltText(head) else { return nil }
        let description = descChunk.flatMap { sanitizeDescription($0) }
        let labels = labelsChunk.map { parseLabels($0) } ?? []
        return DiagramExtractionResult(
            altText: altText,
            description: description,
            labels: labels
        )
    }

    /// Split `text` on the first matching separator from `seps`,
    /// trimming whitespace on both halves. Returns `(prefix,
    /// suffix?)`. When no separator matches, the prefix is the
    /// full input and the suffix is nil.
    static func splitOnce(
        _ text: String, anyOf seps: [String]
    ) -> (String, String?) {
        for sep in seps {
            if let range = text.range(of: sep) {
                let head = String(text[text.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (head, tail)
            }
        }
        return (text, nil)
    }

    /// Parse the labels half of a three-part response. Each line
    /// is one label; leading "- " / "* " / "• " bullets get
    /// stripped. Empty lines and lines longer than 80 chars are
    /// dropped — runaway content is more likely a parse artifact
    /// than a real label. Hard cap at 12 labels per figure to
    /// match the prompt rule.
    static func parseLabels(_ raw: String) -> [String] {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var out: [String] = []
        for line in lines {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") { t = String(t.dropFirst(2)) }
            else if t.hasPrefix("* ") { t = String(t.dropFirst(2)) }
            else if t.hasPrefix("• ") { t = String(t.dropFirst(2)) }
            t = t.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.count <= 80 else { continue }
            out.append(t)
            if out.count >= 12 { break }
        }
        return out
    }

    /// Sanitize the alt-text half of a two-part response (or the
    /// entire response when the separator is missing — keeps
    /// pre-Tier-2 prompt cache hits working). Empty / refusal-
    /// prefixed input returns nil; preambles get stripped;
    /// length capped at 120 chars.
    static func sanitizeAltText(_ raw: String) -> String? {
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return nil }

        // Defensive: catch common refusal-style replies that
        // shouldn't get wrapped as alt text.
        let lower = stripped.lowercased()
        let refusalPrefixes = [
            "i cannot", "i can't", "i am unable", "i'm unable",
            "sorry", "unable to",
        ]
        for prefix in refusalPrefixes where lower.hasPrefix(prefix) {
            return nil
        }

        // Strip the kind of preamble the prompt forbids but
        // models occasionally slip in anyway.
        var trimmed = stripped
        for preamble in Self.bannedPreambles
        where trimmed.lowercased().hasPrefix(preamble) {
            trimmed = String(trimmed.dropFirst(preamble.count))
            if let first = trimmed.first {
                trimmed = first.uppercased() + trimmed.dropFirst()
            }
            break
        }

        let capped = trimmed.count <= 120
            ? trimmed
            : String(trimmed.prefix(117)) + "…"
        return capped
    }

    /// Sanitize the description half. Same refusal-prefix +
    /// preamble guards as alt text, but with a longer length
    /// cap (500 chars) matching the prompt instructions.
    /// Returns nil for empty / refusal-style input so the
    /// caller leaves `description` nil.
    static func sanitizeDescription(_ raw: String) -> String? {
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return nil }

        let lower = stripped.lowercased()
        let refusalPrefixes = [
            "i cannot", "i can't", "i am unable", "i'm unable",
            "sorry", "unable to",
        ]
        for prefix in refusalPrefixes where lower.hasPrefix(prefix) {
            return nil
        }

        var trimmed = stripped
        for preamble in Self.bannedPreambles
        where trimmed.lowercased().hasPrefix(preamble) {
            trimmed = String(trimmed.dropFirst(preamble.count))
            if let first = trimmed.first {
                trimmed = first.uppercased() + trimmed.dropFirst()
            }
            break
        }

        let capped = trimmed.count <= 500
            ? trimmed
            : String(trimmed.prefix(497)) + "…"
        return capped
    }

    static let bannedPreambles = [
        "this image shows ", "this figure shows ",
        "this image depicts ", "this figure depicts ",
        "an illustration of ", "a diagram showing ",
        "a diagram of ", "a figure showing ",
        "the image shows ", "the figure shows ",
        "the figure depicts ", "the image depicts ",
    ]

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
