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
public struct ClaudePageOCREngine: PageOCREngine, Sendable {
    public var providerId: String { "claude" }

    /// What the engine is reading. The base XHTML-output contract
    /// is shared; mode picks the model + appends mode-specific
    /// instructions to the system prompt.
    ///
    /// `.typeset` is the original Sonnet path for plain modern
    /// printed / typeset material. `.earlyPrint(typeface:)`
    /// stays on Sonnet but layers on a normalizing-posture prompt
    /// tuned for 15th–18th c. printed books (long-s, ligatures,
    /// u/v + i/j interchange). `.manuscript(hand:)` routes to
    /// Opus 4.7 with a diplomatic-posture prompt for handwritten
    /// material. The three are mutually exclusive at the
    /// launcher; the engine factory picks one per conversion.
    public enum Mode: Sendable, Equatable {
        case typeset
        case earlyPrint(typeface: EarlyPrintTypeface)
        case manuscript(hand: ManuscriptHand)

        var defaultModel: AnthropicModel {
            switch self {
            case .typeset: return .sonnet4_6
            case .earlyPrint: return .sonnet4_6
            case .manuscript: return .opus4_7
            }
        }
    }

    public let client: AnthropicAPIClient
    public let budget: ClaudeCallBudget
    public var mode: Mode
    public var model: AnthropicModel
    public var maxOutputTokens: Int
    /// Optional per-page response sink. Each call to `recognize` /
    /// `parseBatchMessage` reports the raw XHTML (or sentinel marker
    /// like `[REFUSED]`) here. Drives the pipeline's debug-log dump.
    /// nil → no captures (production path with `emitDebugLog: false`).
    public var captureSink: CaptureSink?

    /// Build a page engine with a sensible default model + token cap.
    /// 8192 max output covers dense academic pages (typical body
    /// content runs 1500-3000 output tokens; headroom matters because
    /// truncated XHTML mid-tag is a parser pathology we want to
    /// avoid).
    ///
    /// `mode` selects the Sonnet typeset path (default) or the
    /// Opus manuscript path; the `model` parameter inherits the
    /// mode's default if not specified, so callers usually pass
    /// just `mode:` and let the model follow.
    public init(
        client: AnthropicAPIClient,
        budget: ClaudeCallBudget,
        mode: Mode = .typeset,
        model: AnthropicModel? = nil,
        maxOutputTokens: Int = 8192,
        captureSink: CaptureSink? = nil
    ) {
        self.client = client
        self.budget = budget
        self.mode = mode
        self.model = model ?? mode.defaultModel
        self.maxOutputTokens = maxOutputTokens
        self.captureSink = captureSink
    }

    public enum PageOCRError: Error, LocalizedError {
        case budgetExhausted
        case pngEncodeFailed
        /// Anthropic returned `stop_reason: "refusal"`. Distinct from
        /// `.empty` so refusal-rate stats can split policy refusals
        /// from "model returned nothing" model hiccups.
        case refused
        /// Response was successful but produced no parseable text.
        case empty
        case underlying(any Error)

        public var errorDescription: String? {
            switch self {
            case .budgetExhausted:    return "Per-book Claude call budget exhausted."
            case .pngEncodeFailed:    return "Could not encode page image as PNG."
            case .refused:            return "Claude refused to transcribe this page."
            case .empty:              return "Claude returned no text for this page."
            case .underlying(let e):  return e.localizedDescription
            }
        }
    }

    public func classify(error: any Error) -> ProviderStatus {
        if error is CancellationError { return .canceled }
        if let api = error as? AnthropicAPIError,
           case .rateLimited = api {
            return .rateLimited
        }
        guard let e = error as? PageOCRError else { return .apiError }
        switch e {
        case .budgetExhausted: return .budgetExhausted
        case .refused:         return .refused
        case .empty:           return .empty
        case .underlying(let inner):
            if let api = inner as? AnthropicAPIError,
               case .rateLimited = api {
                return .rateLimited
            }
            return .apiError
        case .pngEncodeFailed:
            return .apiError
        }
    }

    /// One captured Sonnet response — the raw XHTML and whether the
    /// parser produced any blocks. The pipeline collects these (when
    /// `emitDebugLog` is on) and dumps them to a sibling file for
    /// diagnosing "blank XHTML between page anchors" mysteries.
    public struct CapturedResponse: Sendable {
        public let pageIndex: Int
        public let rawXHTML: String
        public let parsedBlocksEmpty: Bool
    }

    /// Synchronous, thread-safe capture sink. The engine calls this
    /// from both `async` (`recognize`) and `sync` (`parseBatchMessage`)
    /// paths, including from concurrent page TaskGroup tasks, so the
    /// implementation is responsible for its own locking.
    public typealias CaptureSink = @Sendable (CapturedResponse) -> Void

    private func capture(
        pageIndex: Int, raw: String, parseEmpty: Bool
    ) {
        captureSink?(CapturedResponse(
            pageIndex: pageIndex,
            rawXHTML: raw,
            parsedBlocksEmpty: parseEmpty
        ))
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
        guard let request = Self.buildRequest(
            pageImage: pageImage, languages: languages,
            model: model, mode: mode,
            maxOutputTokens: maxOutputTokens
        ) else {
            throw PageOCRError.pngEncodeFailed
        }

        let response: AnthropicMessageResponse
        do {
            response = try await client.send(request)
        } catch let apiError as AnthropicAPIError {
            capture(
                pageIndex: pageIndex,
                raw: "[API ERROR: \(apiError.localizedDescription)]",
                parseEmpty: true
            )
            throw PageOCRError.underlying(apiError)
        } catch {
            capture(
                pageIndex: pageIndex,
                raw: "[SEND FAILED: \(error)]",
                parseEmpty: true
            )
            throw PageOCRError.underlying(error)
        }

        await budget.recordUsage(response.usage, for: model)
        if response.didRefuse {
            capture(pageIndex: pageIndex, raw: "[REFUSED]", parseEmpty: true)
            throw PageOCRError.refused
        }
        guard let xhtml = response.primaryText, !xhtml.isEmpty else {
            capture(pageIndex: pageIndex, raw: "[EMPTY]", parseEmpty: true)
            throw PageOCRError.empty
        }

        let parser = ClaudePageXHTMLParser()
        let result = parser.parse(xhtml, pageIndex: pageIndex)
        capture(
            pageIndex: pageIndex, raw: xhtml,
            parseEmpty: result.blocks.isEmpty
        )
        return result
    }

    /// Tier 9 / E-Batches step 2. Build the request shape without
    /// sending it — used by the batch dispatch path to assemble a
    /// single `AnthropicBatchSubmitRequest` carrying all the
    /// per-page Sonnet calls. Returns nil only on PNG encode
    /// failure. Caller is responsible for reserving a budget call
    /// (the synchronous `recognize` does that itself) and for
    /// recording usage post-result via `recordBatchUsage`.
    public func buildBatchRequest(
        pageImage: CGImage, languages: [BCP47]
    ) -> AnthropicMessageRequest? {
        Self.buildRequest(
            pageImage: pageImage, languages: languages,
            model: model, mode: mode,
            maxOutputTokens: maxOutputTokens
        )
    }

    /// Parse a successful batch result message into a
    /// `ClaudePageResult`. Returns nil on refusal or empty primary
    /// text — caller treats nil as "this page yielded nothing
    /// usable, leave its blocks empty in the document."
    public func parseBatchMessage(
        _ response: AnthropicMessageResponse, pageIndex: Int
    ) -> ClaudePageResult? {
        parseBatchMessageOutcome(response, pageIndex: pageIndex).result
    }

    /// Same as `parseBatchMessage` but also reports whether the
    /// failure (if any) was a refusal vs an empty response. Drives
    /// refusal-rate stats for the batch dispatch path.
    public func parseBatchMessageOutcome(
        _ response: AnthropicMessageResponse, pageIndex: Int
    ) -> (result: ClaudePageResult?, status: ProviderStatus) {
        if response.didRefuse {
            capture(pageIndex: pageIndex, raw: "[REFUSED]", parseEmpty: true)
            return (nil, .refused)
        }
        guard let xhtml = response.primaryText, !xhtml.isEmpty else {
            capture(pageIndex: pageIndex, raw: "[EMPTY]", parseEmpty: true)
            return (nil, .empty)
        }
        let parser = ClaudePageXHTMLParser()
        let result = parser.parse(xhtml, pageIndex: pageIndex)
        capture(
            pageIndex: pageIndex, raw: xhtml,
            parseEmpty: result.blocks.isEmpty
        )
        return (result, .succeeded)
    }

    /// Record token usage from a batch result. Mirrors
    /// `budget.recordUsage` in the synchronous path; batch dispatch
    /// calls this once per result line so the per-book stats
    /// match what was actually spent.
    public func recordBatchUsage(_ usage: Usage) async {
        await budget.recordUsage(usage, for: model)
    }

    /// Internal request-builder shared by `recognize` and
    /// `buildBatchRequest`. Encodes the page image as base64 PNG
    /// and assembles the Messages API request body. Returns nil
    /// on PNG encode failure (no recovery — fall back to cascade).
    ///
    /// The image gets downsized to fit Anthropic's API limits
    /// before encoding: max 8000 px on either dimension AND max
    /// 5 MB base64-encoded. Books rendered at 600 DPI for scans
    /// blew past both limits silently — the API rejected every
    /// page and the per-page error swallow in the pipeline made
    /// the conversion produce a blank EPUB. Anthropic's vision
    /// model auto-downscales above ~1568 px anyway, so anything
    /// larger is wasted bandwidth + tokens.
    private static func buildRequest(
        pageImage: CGImage,
        languages: [BCP47],
        model: AnthropicModel,
        mode: Mode,
        maxOutputTokens: Int
    ) -> AnthropicMessageRequest? {
        guard let (png, _) = Self.encodeForAnthropic(pageImage) else { return nil }
        let base64 = png.base64EncodedString()
        return AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
            // Cache the system prompt — same instruction repeated
            // for every page in the book, so the first page writes
            // the cache and pages 2..N hit it. 1h TTL fits a 400-
            // page book that runs across multiple cache-window
            // boundaries. The mode-specific prompt block (typeset
            // vs. manuscript hand) is appended to the base; the
            // cache key changes with mode so each book's prefix
            // cache stays clean.
            system: .cached(systemPrompt(for: mode), ttl: .oneHour),
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
    }

    /// Compose the system prompt for the active mode. Typeset gets
    /// `baseSystemPrompt` verbatim; manuscript modes get the base
    /// prompt + the hand-specific addendum from `ManuscriptHand`.
    static func systemPrompt(for mode: Mode) -> String {
        switch mode {
        case .typeset:
            return baseSystemPrompt
        case .earlyPrint(let typeface):
            return baseSystemPrompt + "\n\n" + typeface.promptAddendum
        case .manuscript(let hand):
            return baseSystemPrompt + "\n\n" + hand.promptAddendum
        }
    }

    // MARK: - Prompts

    /// Short stable base system prompt — XHTML output schema +
    /// what-to-skip + reading-order rules shared by every mode.
    /// Mode-specific addenda layer on via
    /// `systemPrompt(for:)`. Manuscript modes still benefit
    /// from this base prompt's XHTML / footnote / reading-order
    /// rules; only the transcription policy is mode-specific.
    static let baseSystemPrompt = """
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

        COMPLEX-LAYOUT RULES (apply ONLY when a page has clearly parallel \
        text streams running side by side — books like Derrida's *Glas*, \
        bilingual editions with verso/recto streams, Talmud-style commentaries \
        with marginal glosses, or art books with a narrow sidebar of \
        dictionary / etymological entries):
        - Emit each parallel stream as its own <section data-stream="ID"> wrapping \
        that stream's paragraphs.
        - Stream IDs are: "main" (the dominant body column), "main-2" (a second \
        equal-weight body column running parallel to "main"), "sidebar" (a \
        narrower secondary stream like a glossary, dictionary citations, or \
        running marginalia), "inset" (a smaller block embedded within another \
        column's flow, like a German citation set apart from the surrounding \
        English commentary).
        - Within each <section>, preserve reading order top-to-bottom.
        - Do NOT split into streams on these (they are intra-stream structure, \
        not parallel streams): a horizontal rule separating body text from \
        footnotes, the footnote section itself at the bottom of a page, \
        block quotations, indented passages, or a single-column page where \
        text simply wraps. Single-column pages produce no <section data-stream> \
        wrappers — emit paragraphs at the top level as usual.
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

    /// Anthropic API request limits we pre-clamp against.
    /// Source: Anthropic Messages API image-input docs.
    private static let anthropicMaxBase64Bytes: Int = 5 * 1024 * 1024  // 5 MB
    /// Anthropic auto-downscales images larger than this, so anything
    /// bigger is wasted bytes + tokens. Use as our preferred starting
    /// dimension; iterate downward only if PNG still exceeds 5 MB at
    /// this size (rare but possible for very dense scans).
    private static let anthropicPreferredMaxDim: Int = 1568
    /// Floor we won't shrink past; below this OCR quality drops
    /// faster than the 5 MB win is worth.
    private static let anthropicMinMaxDim: Int = 768

    /// Returns a base64-safe PNG of `image`, resized down if needed
    /// to fit Anthropic's 5 MB / 8000 px-per-side limits. Starts at
    /// `anthropicPreferredMaxDim` (1568 — the resolution Anthropic's
    /// vision model uses internally) and halves until under 5 MB or
    /// until the floor is hit. Returns the encoded data + the final
    /// long-edge dimension (useful for diagnostics).
    static func encodeForAnthropic(
        _ image: CGImage
    ) -> (data: Data, longEdge: Int)? {
        // Initial size: cap to preferred max dim. Scan-DPI inputs
        // are routinely 5000-8000 px across; capping to 1568 cuts
        // the byte count by an order of magnitude with no quality
        // loss (server-side downscale would do the same anyway).
        let initialDim = max(image.width, image.height)
        var targetDim = min(initialDim, anthropicPreferredMaxDim)
        var current = downsize(image, longEdge: targetDim)
        while true {
            guard let png = encodePNG(current) else { return nil }
            if png.count <= anthropicMaxBase64Bytes {
                return (png, max(current.width, current.height))
            }
            // PNG still too large — halve the long edge and try
            // again. Floor at `anthropicMinMaxDim`; if we hit it
            // and still can't fit, return what we have (the API
            // will reject; the user gets a clear error in
            // claude-pages.txt).
            let nextDim = max(targetDim / 2, anthropicMinMaxDim)
            if nextDim == targetDim {
                return (png, max(current.width, current.height))
            }
            targetDim = nextDim
            current = downsize(image, longEdge: targetDim)
        }
    }

    /// Resize `image` so its long edge is at most `longEdge` pixels.
    /// Returns the original when it already fits. Bilinear filtering
    /// (high quality CoreGraphics interpolation).
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
}

/// One page's worth of structured content from Sonnet. The pipeline
/// layers a page anchor on top before splicing into the document
/// stream — this struct only holds what the engine actually returned.
public struct ClaudePageResult: Sendable {
    public let blocks: [Block]
    public let footnotes: [Footnote]
    /// Distinct `data-stream` IDs the parser observed on this
    /// page (e.g. `["main", "sidebar"]`). Empty for single-column
    /// pages. Today this is a diagnostic signal — surfaced in the
    /// per-page debug log so we can measure how often Sonnet /
    /// Gemini detect parallel layouts on the corpus. The block IR
    /// doesn't yet carry per-block stream IDs (would need a Block
    /// enum expansion across ~120 pattern-match sites), so the
    /// EPUB output is linearized regardless. The multi-stream
    /// EPUB shape is documented future work in
    /// `C-Multi-Stream-EPUB` in PLANS.md.
    public let detectedStreams: [String]

    public init(
        blocks: [Block],
        footnotes: [Footnote],
        detectedStreams: [String] = []
    ) {
        self.blocks = blocks
        self.footnotes = footnotes
        self.detectedStreams = detectedStreams
    }
}
