import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import OCR

/// End-to-end "Claude does the page" engine. Skips the cascade — given
/// a rendered page image, it asks Sonnet 4.6 to return a clean XHTML
/// fragment of the page's body content (paragraphs, headings,
/// footnotes, language spans, footnote references) and parses that
/// directly into a `[Block]` + `[Footnote]` slice.
///
/// Replaces the Vision → Surya → Tesseract → Claude per-region cascade
/// with one call per page. Trade-offs vs the cascade:
///
///   * **Quality**: Sonnet sees the whole page at once — column flow,
///     footnote linking, heading semantics, mixed-script spans all
///     come back correctly assembled. The cascade had to compose
///     multiple imperfect tools and we kept hitting failure modes at
///     the seams (column merge, mid-word chapter break, footnote
///     misattribution).
///   * **Cost**: ~$0.04 / page at Sonnet 4.6 pricing — roughly 2-3×
///     the current Cloud-enhanced cascade. Surfaced to the user via
///     the "Claude OCR ($$$)" toggle's help text.
///   * **Speed**: one network call per page (~5-15s) replaces the
///     cascade's mostly-local steps. Slower per page, but simpler.
///   * **Pipeline**: ColumnSplitter / RegionCascade / RegionAwareReflow
///     don't run for pages that take this path. Surya layout still
///     runs (figures, table bboxes); figure extraction is unchanged.
public struct ClaudePageOCREngine: Sendable {
    public let client: AnthropicAPIClient
    public let budget: ClaudeCallBudget
    public var model: AnthropicModel
    public var maxOutputTokens: Int

    /// Build a page engine with a sensible default model + token cap.
    /// 8192 max output covers dense academic pages (typical body
    /// content runs 1500-3000 output tokens; headroom matters because
    /// truncated XHTML mid-tag is a parser pathology we want to
    /// avoid).
    public init(
        client: AnthropicAPIClient,
        budget: ClaudeCallBudget,
        model: AnthropicModel = .sonnet4_6,
        maxOutputTokens: Int = 8192
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    public enum PageOCRError: Error, LocalizedError {
        case budgetExhausted
        case pngEncodeFailed
        case emptyResponse
        case underlying(any Error)

        public var errorDescription: String? {
            switch self {
            case .budgetExhausted:    return "Per-book Claude call budget exhausted."
            case .pngEncodeFailed:    return "Could not encode page image as PNG."
            case .emptyResponse:      return "Claude returned no text for this page."
            case .underlying(let e):  return e.localizedDescription
            }
        }
    }

    /// Recognize one page. `pageIndex` is the 0-based PDF page index;
    /// it's used to namespace footnote IDs (`fn-pN-K`) so two
    /// footnotes both labelled "1" on different pages don't collide.
    public func recognize(
        pageImage: CGImage,
        pageIndex: Int,
        languages: [BCP47]
    ) async throws -> ClaudePageResult {
        guard await budget.tryConsume() else {
            throw PageOCRError.budgetExhausted
        }
        try Task.checkCancellation()

        guard let png = Self.encodePNG(pageImage) else {
            throw PageOCRError.pngEncodeFailed
        }
        let base64 = png.base64EncodedString()

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
            system: .plain(Self.systemPrompt),
            messages: [
                Message(role: .user, content: .blocks([
                    .image(mediaType: .png, base64Data: base64),
                    .text(Self.userPromptForLanguages(languages)),
                ])),
            ],
            // Pure transcription + structural layout — no reasoning
            // needed. Disables the thinking budget for speed and
            // cost.
            thinking: .disabled
        )

        let response: AnthropicMessageResponse
        do {
            response = try await client.send(request)
        } catch let apiError as AnthropicAPIError {
            throw PageOCRError.underlying(apiError)
        }

        await budget.recordUsage(response.usage, for: model)
        if response.didRefuse {
            throw PageOCRError.emptyResponse
        }
        guard let xhtml = response.primaryText, !xhtml.isEmpty else {
            throw PageOCRError.emptyResponse
        }

        let parser = ClaudePageXHTMLParser()
        return parser.parse(xhtml, pageIndex: pageIndex)
    }

    // MARK: - Prompts

    /// Short stable system prompt. The XHTML schema is small enough
    /// that listing it inline beats a long behavioral description;
    /// each rule is one bullet.
    static let systemPrompt = """
        You are transcribing a single page of a book into a clean XHTML body fragment.

        OUTPUT REQUIREMENTS:
        - Return ONLY the XHTML fragment. No <html>, <head>, <body>, no doctype, \
        no preface, no quoting, no commentary.
        - Use plain Unicode characters everywhere. Do NOT use HTML entities like \
        &nbsp;, &mdash;, &amp;quot;, etc. — output the actual character.

        ELEMENTS YOU MAY USE:
        - <p> for body paragraphs.
        - <h2> for chapter / part / major-section titles (use this for the highest \
        heading on the page in most cases).
        - <h3> for sub-section titles within a chapter.
        - <h1> ONLY for the book's overall title page (rare; almost always wrong on \
        an interior page).
        - <em> for italics, <strong> for bold.
        - <span lang="XX"> wraps a non-primary-language span. XX is a BCP-47 code: \
        `grc` for ancient Greek, `la` for Latin, `fr`, `de`, `es`, `it`, `he`, \
        `ar`, `ru`, etc.
        - For footnotes:
          * In-text reference: <a class="noteref" href="#fn-N">N</a> where N is the \
        displayed marker.
          * Footnote body, placed at the END of the page output: \
        <aside class="footnote" id="fn-N">N body text…</aside>. The id values \
        must be sequential numbers per page (fn-1, fn-2, …) regardless of the \
        displayed marker — symbolic markers like *, †, ‡ go in the displayed \
        text, not the id.

        WHAT TO SKIP:
        - Page numbers, running heads, marginalia, decorative ornaments.
        - Figure captions and figure descriptions — figures are handled separately.
        - Image content; describe nothing.

        TRANSCRIPTION RULES:
        - Preserve original spelling and punctuation. Do not modernize.
        - For multi-column layout: read columns top-to-bottom, left then right; \
        emit paragraphs in reading order.
        - Hyphenated word at a line break: join into one word, drop the hyphen.
        - If text is unclear, transcribe what you can read; do NOT insert \
        markers like [unclear] or [illegible].
        """

    /// User-turn prompt carrying the per-request language hint. Kept
    /// out of the system prompt so the system stays byte-stable for
    /// future prefix-cache eligibility.
    static func userPromptForLanguages(_ languages: [BCP47]) -> String {
        let codes = languages.map(\.rawValue).joined(separator: ", ")
        return "Languages expected on this page: \(codes). Transcribe the page into XHTML per the rules above."
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

/// One page's worth of structured content from Sonnet. The pipeline
/// layers a page anchor on top before splicing into the document
/// stream — this struct only holds what the engine actually returned.
public struct ClaudePageResult: Sendable {
    public let blocks: [Block]
    public let footnotes: [Footnote]

    public init(blocks: [Block], footnotes: [Footnote]) {
        self.blocks = blocks
        self.footnotes = footnotes
    }
}
