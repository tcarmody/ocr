import Foundation
import Document

/// Parses the XHTML fragment Sonnet returns from `ClaudePageOCREngine`
/// into a `[Block]` + `[Footnote]` slice.
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
public struct ClaudePageXHTMLParser: Sendable {
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

    /// Replace the named entities Sonnet sometimes emits with their
    /// Unicode characters. `XMLParser` only knows the five built-in
    /// XML entities (`&lt;`, `&gt;`, `&amp;`, `&apos;`, `&quot;`); any
    /// other named entity throws `NSXMLParserUndeclaredEntityError`.
    /// The prompt asks Sonnet to use Unicode directly, but Sonnet
    /// occasionally slips and emits HTML entities anyway.
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

        init(pageIndex: Int) {
            self.pageIndex = pageIndex
        }

        // MARK: XMLParserDelegate

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let tag = elementName.lowercased()
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
                    let indent = ClaudePageXHTMLParser
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
                // stream (multi-column body, sidebar, inset).
                // Capture the stream ID into the diagnostic and
                // treat the element as a block-level no-op:
                // contained <p> / <h2> / etc. still parse into
                // their own blocks, but the section itself doesn't
                // push an inline frame (which would corrupt the
                // block boundaries). The block IR is linearized
                // for now — see PLANS C-Multi-Stream-EPUB for the
                // future EPUB output story.
                if let streamID = attributeDict["data-stream"],
                   !streamID.isEmpty {
                    detectedStreams.insert(streamID)
                }
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
                // No-op: open didn't push an inline frame, so close
                // doesn't pop one. Contained <p> / <h2> blocks have
                // already self-closed via their own end-element
                // handlers.
                return
            default:
                flushTextBuffer()
                if !inlineStack.isEmpty { inlineStack.removeLast() }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
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
                if run.text.isEmpty { continue }
                if let last = out.last,
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
