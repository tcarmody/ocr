import Foundation
import Document

/// Parses the XHTML fragment a page-OCR cloud model returns into a
/// `[Block]` + `[Footnote]` slice. Shared by `ClaudePageOCREngine`
/// (Sonnet 4.6 / Opus 4.7) and `GeminiPageOCREngine` (Gemini 2.5 /
/// 3 Flash Preview / 3.5 Flash) — both engines emit the same
/// XHTML output contract from the shared base system prompt.
/// Previously named `ClaudePageXHTMLParser` from the era when only
/// Sonnet existed; renamed when Gemini joined.
///
/// XML-strict parser via `XMLParser`. The fragment is wrapped in a
/// synthetic `<doc>` root so single-paragraph pages parse, and a small
/// pre-processor swaps the most common XHTML named entities (`&nbsp;`,
/// `&mdash;`, etc.) with their Unicode characters since `XMLParser`
/// would otherwise reject them.
///
/// **Schema** (mirrors the prompt in `ClaudePageOCREngine`):
///   * `<p>` → `Block.paragraph`
///   * `<h1>`–`<h6>` → `Block.heading(level:)`
///   * `<aside class="footnote" id="fn-N">marker body</aside>` →
///     `Footnote(id: "fn-pP-N", marker: "marker", runs: [body])` where
///     P is the page index passed to `parse`
///   * `<a class="noteref" href="#fn-N">N</a>` → `InlineRun` with
///     `noterefId = "fn-pP-N"`
///   * `<em>` / `<i>` / `<strong>` / `<b>`: inline emphasis. We don't
///     model bold/italic at the run level (yet) — runs that fall
///     inside these elements still serialize as plain text. Future
///     work to add `InlineRun.style`.
///   * `<span lang="XX">` / `<span xml:lang="XX">` → `InlineRun.language`
///   * Anything else: passes through as plain text with surrounding
///     siblings.
///
/// Invalid XHTML degrades to one paragraph containing the
/// tag-stripped raw text, so a malformed Sonnet response doesn't
/// erase a page — it just loses structure.
public struct PageXHTMLParser: Sendable {
    public init() {}

    /// P-Verse-Layout. Parse a `class="line indent-3"` style
    /// attribute, return the integer N from the first `indent-N`
    /// token. Returns 0 when no such token is present (which is
    /// what `<p class="line">` alone means — flush-left). Exposed
    /// `static` so unit tests can pin the parsing behavior
    /// without piping every case through the full XML parser.
    public static func parseIndentBucket(from cls: String) -> Int {
        let tokens = cls.split(separator: " ")
        for token in tokens {
            if token.hasPrefix("indent-"),
               let n = Int(token.dropFirst("indent-".count)) {
                return n
            }
        }
        return 0
    }

    public func parse(_ xhtml: String, pageIndex: Int) -> ClaudePageResult {
        let cleaned = Self.preprocess(xhtml)
        let wrapped = "<doc>\(cleaned)</doc>"
        guard let data = wrapped.data(using: .utf8) else {
            return ClaudePageResult(
                blocks: [.paragraph(runs: [InlineRun(Self.stripTags(xhtml))])],
                footnotes: []
            )
        }

        let delegate = Delegate(pageIndex: pageIndex)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        if !ok {
            // Malformed XHTML — fall back to plain-text recovery so
            // we don't drop the page entirely.
            let recovered = Self.stripTags(cleaned)
            let trimmed = recovered.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return ClaudePageResult(blocks: [], footnotes: [])
            }
            return ClaudePageResult(
                blocks: [.paragraph(runs: [InlineRun(trimmed)])],
                footnotes: []
            )
        }
        delegate.flushPending()
        return ClaudePageResult(
            blocks: delegate.blocks,
            footnotes: delegate.footnotes,
            detectedStreams: Array(delegate.detectedStreams).sorted()
        )
    }

    // MARK: - Preprocessing

    /// Replace the named entities the cloud OCR models sometimes
    /// emit with their Unicode characters. `XMLParser` only knows the
    /// five built-in XML entities (`&lt;`, `&gt;`, `&amp;`, `&apos;`,
    /// `&quot;`); any other named entity throws
    /// `NSXMLParserUndeclaredEntityError`. The shared system prompt
    /// tells the model to use Unicode directly, but Sonnet and
    /// Gemini both occasionally slip and emit HTML entities anyway.
    static func preprocess(_ s: String) -> String {
        var out = s
        let replacements: [(String, String)] = [
            ("&nbsp;",   "\u{00A0}"),
            ("&mdash;",  "\u{2014}"),
            ("&ndash;",  "\u{2013}"),
            ("&hellip;", "\u{2026}"),
            ("&ldquo;",  "\u{201C}"),
            ("&rdquo;",  "\u{201D}"),
            ("&lsquo;",  "\u{2018}"),
            ("&rsquo;",  "\u{2019}"),
            ("&copy;",   "\u{00A9}"),
            ("&reg;",    "\u{00AE}"),
            ("&trade;",  "\u{2122}"),
            ("&times;",  "\u{00D7}"),
            ("&divide;", "\u{00F7}"),
            ("&deg;",    "\u{00B0}"),
            ("&middot;", "\u{00B7}"),
            ("&laquo;",  "\u{00AB}"),
            ("&raquo;",  "\u{00BB}"),
            ("&prime;",  "\u{2032}"),
            ("&Prime;",  "\u{2033}"),
        ]
        for (k, v) in replacements {
            out = out.replacingOccurrences(of: k, with: v)
        }
        // P-Math: XMLParser with shouldProcessNamespaces=false
        // refuses default-namespace declarations on nested elements
        // (`<doc><math xmlns="…">` fails the whole parse). Strip the
        // xmlns attribute from any `<math …>` open tag; the writer
        // re-adds the canonical MathML namespace when it emits.
        out = stripMathXmlns(out)
        return out
    }

    /// Remove `xmlns="…"` attributes on `<math>` open tags. Other
    /// elements are untouched. The writer re-adds the canonical
    /// MathML namespace when emitting, so dropping it here is
    /// lossless on the round-trip — and XMLParser stops choking on
    /// the default-namespace declaration inside the `<doc>` wrapper.
    private static func stripMathXmlns(_ s: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"(<math\b[^>]*?)\s+xmlns\s*=\s*"[^"]*"([^>]*>)"#,
            options: [.caseInsensitive]
        ) else { return s }
        var out = s
        // A `<math>` element could have xmlns plus other attributes
        // (e.g. `display="block"`). Repeated apply handles the rare
        // case of two xmlns declarations on the same tag.
        for _ in 0..<3 {
            let ns = out as NSString
            let replaced = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(location: 0, length: ns.length),
                withTemplate: "$1$2"
            )
            if replaced == out { break }
            out = replaced
        }
        return out
    }

    /// Naive HTML/XHTML tag stripper used only on the malformed-input
    /// fallback path. Strips anything between `<` and `>` and decodes
    /// the five XML entities.
    static func stripTags(_ s: String) -> String {
        var out = s.replacingOccurrences(
            of: "<[^>]+>", with: "",
            options: .regularExpression
        )
        let entityMap: [(String, String)] = [
            ("&lt;",   "<"),
            ("&gt;",   ">"),
            ("&amp;",  "&"),
            ("&apos;", "'"),
            ("&quot;", "\""),
        ]
        for (k, v) in entityMap {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }

    // MARK: - Delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        let pageIndex: Int
        var blocks: [Block] = []
        var footnotes: [Footnote] = []
        /// Stream IDs observed via `<section data-stream="…">`.
        /// Surfaces to ClaudePageResult.detectedStreams as a
        /// diagnostic until the multi-stream EPUB shape ships.
        var detectedStreams: Set<String> = []

        enum BlockKind {
            case paragraph
            case heading(level: Int)
            case footnote(id: String)
            /// P-Verse-Layout. One line inside a `<div class="verse">`
            /// container. The `<p class="line indent-N">` element is
            /// treated as a self-contained line that finalizes into a
            /// `VerseLine` and gets appended to the surrounding
            /// verse-div's pending-lines buffer instead of becoming
            /// its own `Block` immediately.
            case verseLine(indent: Int)
        }

        struct InlineFrame {
            var language: BCP47?
            var noterefId: String?
            var isItalic: Bool = false
            var isBold: Bool = false
        }

        var currentBlockKind: BlockKind?
        var currentRuns: [InlineRun] = []
        var inlineStack: [InlineFrame] = []
        var textBuffer = ""

        /// P-Verse-Layout. Set when we enter a `<div class="verse">`
        /// element. While set, `<p>` opens are routed to
        /// `BlockKind.verseLine` and their closings accumulate into
        /// `pendingVerseLines` instead of emitting per-line `Block`s.
        /// The closing `</div>` flushes the buffer into a single
        /// `Block.verse(lines:)`.
        var inVerseDiv: Bool = false
        var pendingVerseLines: [VerseLine] = []

        /// Stream-id stack for `<section data-stream="…">`. Empty
        /// stack = top level (primary content). When a non-`main`
        /// section is on top, finalize-block suppresses appends so
        /// hallucinated "secondary" content (e.g. Gemini emitting a
        /// `main-2` stream that's actually invented next-page text)
        /// doesn't double the body into the EPUB. See PLANS
        /// C-Multi-Stream-EPUB for the future layout-aware path
        /// that would consume these streams instead of dropping them.
        var streamStack: [String] = []

        /// `<math>` capture state. P-Math (cheap path): when the
        /// model emits MathML, we capture the entire subtree as a
        /// string and emit it verbatim through an `InlineRun.rawXHTML`
        /// so the XHTML writer can pass it to the EPUB without
        /// flattening into `<sub>`/`<sup>` plain-text runs.
        ///   * `mathDepth > 0` ⇒ we're inside a `<math>` element;
        ///     subsequent start/end/character callbacks accumulate
        ///     into `mathBuffer` instead of touching the inline
        ///     stack or text buffer.
        ///   * `mathBuffer` builds the raw markup (open + inner + close).
        ///   * `mathPlainText` accumulates the visible text content
        ///     so downstream writers that don't render MathML
        ///     (Markdown, plain-text) have something to fall back on.
        var mathDepth: Int = 0
        var mathBuffer: String = ""
        var mathPlainText: String = ""

        /// True when the parser is currently inside a non-primary
        /// stream and emitted blocks should be discarded. The
        /// definition of "primary" is "empty stack" (no section
        /// wrapper at all — the common shape for typeset prose) OR
        /// "stack top is exactly `main`" — anything else is dropped.
        var isInPrimaryStream: Bool {
            guard let top = streamStack.last else { return true }
            return top == "main"
        }

        init(pageIndex: Int) {
            self.pageIndex = pageIndex
        }

        // MARK: XMLParserDelegate

        /// Serialize a tag open into its raw XML form, preserving
        /// attributes. Used by the `<math>` capture path to reassemble
        /// the model's emitted MathML verbatim.
        private func serializeOpenTag(
            _ tag: String, attributes: [String: String]
        ) -> String {
            if attributes.isEmpty { return "<\(tag)>" }
            // Sort attributes for stable output (helps tests + cache
            // hashing). Attribute values get XML-escaped.
            let attrs = attributes.keys.sorted().map { k -> String in
                let v = attributes[k] ?? ""
                let escaped = v
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                return "\(k)=\"\(escaped)\""
            }
            return "<\(tag) \(attrs.joined(separator: " "))>"
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let tag = elementName.lowercased()
            // P-Math: any tag inside an open <math> gets appended to
            // the capture buffer verbatim, bypassing the inline-frame
            // state machine. The `mathDepth > 0` check fires for
            // nested children (mrow, mi, mo, mfrac, msup, msub, …);
            // the explicit `tag == "math"` case handles the outer
            // entry.
            if tag == "math" {
                // Flush any pending paragraph text before capturing
                // so the math run inserts at the right position.
                flushTextBuffer()
                mathDepth = 1
                // Re-add the canonical MathML namespace that
                // `preprocess` stripped to keep XMLParser happy.
                // The model often emits it, but we strip + re-add
                // it deterministically so the EPUB output always
                // carries the proper namespace regardless of what
                // the model chose to include.
                var attrs = attributeDict
                attrs["xmlns"] = "http://www.w3.org/1998/Math/MathML"
                mathBuffer = serializeOpenTag(tag, attributes: attrs)
                mathPlainText = ""
                return
            }
            if mathDepth > 0 {
                mathBuffer += serializeOpenTag(tag, attributes: attributeDict)
                mathDepth += 1
                return
            }
            switch tag {
            case "doc":
                return
            case "div":
                // P-Verse-Layout. <div class="verse"> opens a poetry
                // region. Nested <div>s aren't supported in our
                // emission so the flag-based state is sufficient.
                let cls = attributeDict["class"] ?? ""
                if cls.contains("verse") {
                    inVerseDiv = true
                    pendingVerseLines = []
                }
                // Non-verse <div>: ignore the wrapper but let
                // contained block-level elements parse normally.
                // No inline frame because <div> wraps block content,
                // not inline.
            case "p":
                if inVerseDiv {
                    // P-Verse-Layout. <p class="line indent-N"> within
                    // a verse div. Extract the indent bucket from the
                    // class string; default to 0 when absent. Other
                    // class tokens (right-align in v2) are ignored
                    // for v1-narrow — that part lands later.
                    let cls = attributeDict["class"] ?? ""
                    let indent = PageXHTMLParser
                        .parseIndentBucket(from: cls)
                    startBlock(.verseLine(indent: indent))
                } else {
                    startBlock(.paragraph)
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(String(tag.dropFirst())) ?? 2
                startBlock(.heading(level: level))
            case "aside":
                let cls = attributeDict["class"] ?? ""
                if cls.contains("footnote") {
                    let rawId = attributeDict["id"] ?? "unknown"
                    startBlock(.footnote(id: namespacedFootnoteId(rawId)))
                } else {
                    // Unknown aside — push an inline frame so the
                    // closing tag balances; treat content as inline.
                    pushInlineFrame()
                }
            case "em", "i":
                // P-Verse-Layout: `<i lang="grc">…</i>` is the
                // canonical shape for italic foreign-language
                // fragments inside verse (Sonnet/Gemini prompt
                // addendum asks for it). Pick up the language
                // attribute on italic tags too — not just <span>.
                let lang = attributeDict["lang"]
                    ?? attributeDict["xml:lang"]
                pushInlineFrame(
                    language: lang.map { BCP47($0) },
                    italic: true
                )
            case "strong", "b":
                let lang = attributeDict["lang"]
                    ?? attributeDict["xml:lang"]
                pushInlineFrame(
                    language: lang.map { BCP47($0) },
                    bold: true
                )
            case "span":
                let lang = attributeDict["lang"] ?? attributeDict["xml:lang"]
                pushInlineFrame(language: lang.map { BCP47($0) })
            case "a":
                let cls = attributeDict["class"] ?? ""
                let href = attributeDict["href"] ?? ""
                if cls.contains("noteref"), href.hasPrefix("#") {
                    let rawId = String(href.dropFirst())
                    pushInlineFrame(noterefId: namespacedFootnoteId(rawId))
                } else {
                    pushInlineFrame()
                }
            case "br":
                // Inline line-break — flush surrounding text into the
                // current frame, then re-flush a newline character so
                // the resulting run preserves the visual break.
                flushTextBuffer()
                textBuffer = "\n"
                flushTextBuffer()
            case "section":
                // <section data-stream="…"> wraps a parallel text
                // stream (multi-column body, sidebar, inset). Push
                // onto the stream stack so finalizeBlock can suppress
                // anything outside the primary stream — Gemini 3.5
                // Flash in particular emits `main-2` blocks that are
                // hallucinated next-page content, and concatenating
                // them into the EPUB doubles the body. Block IR is
                // linearized for the primary stream only; see PLANS
                // C-Multi-Stream-EPUB for the future EPUB output story.
                let streamID = attributeDict["data-stream"] ?? ""
                if !streamID.isEmpty {
                    detectedStreams.insert(streamID)
                }
                // Push even an empty string — the close needs a
                // matching pop. Treat empty as primary (it would
                // pass the "main or empty stack" predicate at the
                // top by reading the stack-top empty string differently
                // — see `isInPrimaryStream` below).
                streamStack.append(streamID.isEmpty ? "main" : streamID)
            default:
                // Unknown tag — push a frame so the closing balances;
                // text inside is treated as if the tag wasn't there.
                pushInlineFrame()
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let tag = elementName.lowercased()
            // P-Math close path. If we're inside a `<math>` subtree
            // append the close tag; when depth returns to 0, emit the
            // captured MathML as a single rawXHTML InlineRun and
            // reset state. If we're at the top of a block (no current
            // block kind) — i.e. the `<math>` appeared standalone
            // outside any `<p>`/`<h*>` — start a paragraph implicitly
            // so the run has a block to land in.
            if mathDepth > 0 {
                mathBuffer += "</\(tag)>"
                mathDepth -= 1
                if mathDepth == 0 {
                    if currentBlockKind == nil {
                        startBlock(.paragraph)
                    }
                    currentRuns.append(InlineRun(
                        mathPlainText,
                        rawXHTML: mathBuffer
                    ))
                    mathBuffer = ""
                    mathPlainText = ""
                }
                return
            }
            switch tag {
            case "doc":
                return
            case "div":
                // P-Verse-Layout. Closing the verse div flushes any
                // pending lines as a single Block.verse. Empty
                // verse divs (no lines accumulated) emit nothing.
                if inVerseDiv {
                    if !pendingVerseLines.isEmpty {
                        blocks.append(.verse(lines: pendingVerseLines))
                    }
                    pendingVerseLines = []
                    inVerseDiv = false
                }
            case "p", "h1", "h2", "h3", "h4", "h5", "h6":
                flushTextBuffer()
                finalizeBlock()
            case "aside":
                if case .footnote = currentBlockKind {
                    flushTextBuffer()
                    finalizeBlock()
                } else if !inlineStack.isEmpty {
                    flushTextBuffer()
                    inlineStack.removeLast()
                }
            case "em", "i", "strong", "b", "span", "a":
                flushTextBuffer()
                if !inlineStack.isEmpty { inlineStack.removeLast() }
            case "br":
                return
            case "section":
                // Pop the stream stack to mirror the open's push.
                // The contained block tags have already self-closed
                // through their own end-element handlers; finalize-
                // block suppressed any in non-primary streams.
                if !streamStack.isEmpty { streamStack.removeLast() }
                return
            default:
                flushTextBuffer()
                if !inlineStack.isEmpty { inlineStack.removeLast() }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            // P-Math capture: characters inside `<math>` accumulate
            // into both the raw markup buffer (XML-escaped — they're
            // attribute-free text content within the math markup)
            // and the plain-text fallback string. Done before the
            // currentBlockKind guard so math content inside a bare
            // `<math>` (no surrounding `<p>`) still gets captured.
            if mathDepth > 0 {
                let escaped = string
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                mathBuffer += escaped
                mathPlainText += string
                return
            }
            // Drop characters that fall outside any block context —
            // those are usually whitespace between block elements.
            guard currentBlockKind != nil else { return }
            textBuffer += string
        }

        // MARK: Block / inline state machine

        private func pushInlineFrame(
            language: BCP47? = nil,
            noterefId: String? = nil,
            italic: Bool = false,
            bold: Bool = false
        ) {
            // Flush any pending text under the *previous* frame
            // before switching, so a `<span>` partway through a
            // paragraph correctly attributes the preceding chars.
            flushTextBuffer()
            let parent = inlineStack.last ?? InlineFrame()
            inlineStack.append(InlineFrame(
                language: language ?? parent.language,
                noterefId: noterefId ?? parent.noterefId,
                // Emphasis is additive: a `<strong>` inside an
                // `<em>` produces both italic + bold on the inner
                // run, matching how readers render bold-italic.
                isItalic: parent.isItalic || italic,
                isBold: parent.isBold || bold
            ))
        }

        private func startBlock(_ kind: BlockKind) {
            // Defensive: if a previous block is still open (malformed
            // input), close it before starting the new one.
            if currentBlockKind != nil {
                flushTextBuffer()
                finalizeBlock()
            }
            currentBlockKind = kind
            currentRuns = []
            textBuffer = ""
            inlineStack = []
        }

        private func flushTextBuffer() {
            guard !textBuffer.isEmpty else { return }
            // Don't bury whitespace-only text from inter-tag chars.
            let frame = inlineStack.last ?? InlineFrame()
            currentRuns.append(InlineRun(
                textBuffer,
                language: frame.language,
                noterefId: frame.noterefId,
                isItalic: frame.isItalic,
                isBold: frame.isBold
            ))
            textBuffer = ""
        }

        private func finalizeBlock() {
            defer {
                currentBlockKind = nil
                currentRuns = []
                inlineStack = []
                textBuffer = ""
            }
            guard let kind = currentBlockKind else { return }
            // Drop blocks with only whitespace content.
            let joined = currentRuns.map(\.text).joined()
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Suppress blocks emitted inside a non-primary
            // `<section data-stream="…">`. Gemini 3.5 Flash in
            // particular emits a `main-2` stream that's a
            // hallucinated continuation of the page (often the
            // next page's content) — concatenating it produces
            // visibly doubled text in the EPUB. The id is still
            // recorded in `detectedStreams` for the diagnostic
            // surface.
            guard isInPrimaryStream else { return }
            // Trim leading/trailing whitespace from the run text where
            // it's purely whitespace (paragraphs often have whitespace
            // between block tags that XMLParser returns as text).
            let runs = compactRuns(currentRuns)
            switch kind {
            case .paragraph:
                blocks.append(.paragraph(runs: runs))
            case .heading(let level):
                blocks.append(.heading(level: level, runs: runs))
            case .footnote(let id):
                let (marker, body) = splitMarker(from: runs)
                footnotes.append(Footnote(
                    id: id,
                    marker: marker,
                    runs: body
                ))
            case .verseLine(let indent):
                // P-Verse-Layout. Accumulate into the pending
                // buffer; the enclosing </div> flushes them as a
                // single Block.verse.
                pendingVerseLines.append(VerseLine(
                    runs: runs, indent: indent
                ))
            }
        }

        func flushPending() {
            flushTextBuffer()
            if currentBlockKind != nil { finalizeBlock() }
        }

        // MARK: Helpers

        /// Namespace a Sonnet-supplied id (`fn-1`, `fn-2`) with the
        /// page index so two notes on different pages don't collide
        /// in the document-level footnote map.
        private func namespacedFootnoteId(_ rawId: String) -> String {
            // Strip a leading `fn-` if present, then re-prefix with
            // the page index.
            let trimmed: String
            if rawId.hasPrefix("fn-") {
                trimmed = String(rawId.dropFirst("fn-".count))
            } else {
                trimmed = rawId
            }
            return "fn-p\(pageIndex)-\(trimmed)"
        }

        /// Drop empty runs and merge adjacent runs that share
        /// identical attributes — the parser produces a fresh run
        /// every time text crosses an inline-frame boundary, even if
        /// the boundary didn't actually change anything semantically.
        /// Compaction keeps the downstream `[InlineRun]` tidy without
        /// changing meaning.
        private func compactRuns(_ runs: [InlineRun]) -> [InlineRun] {
            var out: [InlineRun] = []
            for run in runs {
                // A rawXHTML run carries opaque markup (e.g.
                // captured MathML); keep it even when `text` is
                // empty so the markup makes it into the EPUB.
                if run.text.isEmpty && run.rawXHTML == nil { continue }
                if let last = out.last,
                   // rawXHTML runs are opaque — never merge them
                   // with neighbours (the merge would drop the
                   // markup) and never merge anything into them.
                   last.rawXHTML == nil,
                   run.rawXHTML == nil,
                   last.language == run.language,
                   last.noterefId == run.noterefId,
                   last.isItalic == run.isItalic,
                   last.isBold == run.isBold {
                    out[out.count - 1] = InlineRun(
                        last.text + run.text,
                        language: last.language,
                        noterefId: last.noterefId,
                        isItalic: last.isItalic,
                        isBold: last.isBold
                    )
                } else {
                    out.append(run)
                }
            }
            return out
        }

        /// Pull a leading "marker" off the footnote body. The marker
        /// is the first whitespace-delimited token that's ≤ 4 chars
        /// long (real markers are "1", "12", "*", "†", "1.", "(1)" —
        /// all short). Symbols like `*` and `†` count as valid
        /// markers; we don't trim punctuation, just take the token
        /// verbatim. Anything longer than 4 chars (i.e. body text
        /// without an explicit marker) leaves the marker empty and
        /// the body untouched.
        private func splitMarker(from runs: [InlineRun]) -> (marker: String, body: [InlineRun]) {
            guard let firstRun = runs.first else { return ("", runs) }
            let leading = firstRun.text.drop(while: \.isWhitespace)
            guard !leading.isEmpty else { return ("", runs) }
            // First whitespace-delimited token is the marker.
            let markerEnd = leading.firstIndex(where: { $0.isWhitespace }) ?? leading.endIndex
            let marker = String(leading[..<markerEnd])
            guard !marker.isEmpty, marker.count <= 4 else {
                return ("", runs)
            }
            // Body: everything after the marker + leading whitespace.
            let afterMarker = leading[markerEnd...].drop(while: \.isWhitespace)
            let bodyTextInFirstRun = String(afterMarker)
            var body = runs
            if bodyTextInFirstRun.isEmpty {
                body.removeFirst()
            } else {
                body[0] = InlineRun(
                    bodyTextInFirstRun,
                    language: firstRun.language,
                    noterefId: firstRun.noterefId
                )
            }
            return (marker, body)
        }
    }
}
