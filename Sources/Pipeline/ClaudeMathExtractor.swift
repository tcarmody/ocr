import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import Layout
import OCR

/// P-Math-Cascade. Sonnet-driven MathML transcription for `.formula`
/// regions: crop the page raster to the region, send the crop to
/// Sonnet 4.6, and return the model's MathML response. Cascade-mode
/// conversions that previously just rastered display equations now
/// get real semantic markup that screen readers, search, and copy/
/// paste can use.
///
/// Returns `nil` (so the caller falls back to the figure raster) on:
///   * per-book budget exhausted,
///   * PNG encoding failure,
///   * network / API error,
///   * model refusal,
///   * empty / non-MathML response,
///   * MathML that doesn't open with `<math` (defensive — keeps
///     pollution out of the EPUB's chapter XHTML).
///
/// One Sonnet call per `.formula` region. Formulas average 0–2
/// per book in non-STEM corpora; even a math-heavy book with 50
/// equations costs ~$0.05–$0.25 here. The whole-page Cloud OCR
/// path captures MathML inline as part of its single per-page call
/// and never reaches this extractor.
public struct ClaudeMathExtractor: MathExtractor {
    public let client: AnthropicAPIClient
    public let budget: CloudCallBudget
    public var model: CloudModel
    public var maxOutputTokens: Int

    public init(
        client: AnthropicAPIClient,
        budget: CloudCallBudget,
        model: CloudModel = .sonnet4_6,
        // Single display equation rarely exceeds 1K MathML tokens
        // (a long aligned derivation pushes ~2K). 4K leaves
        // comfortable headroom without burning budget on a
        // generous-but-unused ceiling.
        maxOutputTokens: Int = 4096
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    public func extract(
        pageImage: CGImage,
        regionBox: CGRect,
        stagingDir: URL,
        pageIndex: Int,
        regionIndex: Int
    ) async -> String? {
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
            // Cache the system prompt. Math regions are rare per
            // book (most books have 0); the cache wins on cross-
            // book session usage when the user converts several
            // STEM books in a row.
            system: .cached(Self.systemPrompt, ttl: .oneHour),
            messages: [
                Message(role: .user, content: .blocks([
                    .image(mediaType: .png, base64Data: base64),
                    .text(Self.userPrompt),
                ])),
            ],
            // Pure transcription, no reasoning needed.
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
        return Self.sanitizeMathML(raw)
    }

    // MARK: - Prompt

    /// Stable system prompt — kept byte-stable across requests so
    /// the prefix is cacheable. Asks for a single `<math>` element
    /// with no surrounding prose so the caller can drop the result
    /// directly into the chapter XHTML.
    static let systemPrompt = """
        You are transcribing a single mathematical formula from a \
        book page. The image shows ONE formula region cropped from \
        the page (typically a display equation set off on its own \
        line, sometimes an inline expression). Return ONLY the \
        MathML transcription — no preface, no commentary, no \
        markdown fences, no surrounding prose.

        Rules:
          * Wrap the result in a single `<math display="block" \
        xmlns="http://www.w3.org/1998/Math/MathML">…</math>` element \
        for display equations (centered standalone formulas, \
        derivations, equations with numbers). Use \
        `<math xmlns="http://www.w3.org/1998/Math/MathML">…</math>` \
        without `display="block"` for clearly inline expressions.
          * Equation numbers (like "(1)", "(3.4)") go OUTSIDE the \
        `<math>` element if present — append them as plain text \
        after the closing `</math>` tag.
          * Use semantic MathML elements: `<mrow>`, `<mi>`, `<mn>`, \
        `<mo>`, `<msub>`, `<msup>`, `<msubsup>`, `<mfrac>`, `<msqrt>`, \
        `<mroot>`, `<mtable>` / `<mtr>` / `<mtd>` for aligned \
        derivations, `<munder>` / `<mover>` / `<munderover>` for \
        summation / product / integral with limits.
          * Transcribe operators and Greek letters as themselves \
        (e.g. `<mi>α</mi>`, `<mo>∫</mo>`, `<mo>≤</mo>`). Do NOT \
        rewrite into LaTeX, MathJax `\\frac{}{}` syntax, or ASCII \
        approximations.
          * If the image is NOT a formula (e.g. a chart, photograph, \
        or just text), return the empty string. The caller treats \
        empty as "fall back to the raster figure" — never invent \
        markup for non-math content.
          * If the formula is too unclear to transcribe reliably, \
        return the empty string. Original-raster fallback is \
        always better than a wrong transcription.
        """

    /// User-turn prompt; minimal so the system prefix stays cacheable.
    static let userPrompt = "Transcribe the math in this image."

    // MARK: - Sanitization

    /// Strip code-fence wrappers and surrounding whitespace from the
    /// model's response, then verify it starts with `<math`. The
    /// system prompt forbids fences, but Sonnet occasionally wraps
    /// XML output in ```xml fences anyway. A reply that doesn't
    /// begin with `<math` (after stripping) is treated as a refusal —
    /// keep stray prose out of the chapter XHTML.
    static func sanitizeMathML(_ raw: String) -> String? {
        let stripped = stripCodeFence(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return nil }
        guard stripped.hasPrefix("<math") else { return nil }
        return stripped
    }

    /// Strip outer ```...``` fence (with optional language tag) from
    /// a model response. Conservative — only the outer fence comes
    /// off, internal content is left alone.
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
    /// shape as the other Claude extractors; duplicated rather than
    /// shared because the engines live in separate types.
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
