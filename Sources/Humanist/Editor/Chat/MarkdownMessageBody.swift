import SwiftUI

/// Renders an assistant chat reply as formatted Markdown rather
/// than raw text. Cloud / Ollama replies routinely use **bold**,
/// *italic*, bullet lists, headings, and inline `code` — the
/// previous `Text(message.text)` showed those literally
/// (`**bold**` rendering the asterisks alongside the word).
///
/// Foundation's `AttributedString(markdown:)` handles inline
/// emphasis + inline code + links in a single call but ignores
/// block-level structure (lists, headings, fenced code, block
/// quotes). This view supplies the block-level pass — splits the
/// text on blank lines, classifies each block by its line prefix,
/// and renders it with the right SwiftUI primitive. Inline
/// emphasis within each block still routes through
/// `AttributedString(markdown:)` so we don't reinvent that wheel.
///
/// Scope is intentionally narrow: cover what the model actually
/// emits in chat replies, not the full CommonMark spec. If a
/// real-world reply surfaces an unrendered construct (tables,
/// nested lists with multiple levels, footnotes), extend this
/// renderer rather than reaching for a third-party Markdown
/// dependency.
struct MarkdownMessageBody: View {
    let text: String
    /// Cached block parse folded into a single AttributedString so
    /// the view emits exactly one `Text` regardless of how many
    /// paragraphs / bullets / headings the message contains.
    ///
    /// Why one Text: each `Text(...).textSelection(.enabled)` on
    /// macOS 26 backs into an `NSTextField` wrapped by SwiftUI's
    /// `SelectionOverlay` NSViewRepresentable. Every `NSTextField`
    /// in scope sets its font on every layout pass, and each
    /// `setFont` invalidates intrinsic content size, which triggers
    /// another layout pass, which calls setFont again — a feedback
    /// loop in the JetUI / Liquid Glass renderer that scales
    /// linearly with the *count* of selectable Text views in the
    /// scroll view. A 10-message transcript with multi-Text bodies
    /// produced ~30+ NSTextFields and pinned the main thread on
    /// every hover / scroll / unrelated state change (sampled
    /// cascade: SelectionOverlay → FallbackAlignmentProvider →
    /// setFont → invalidateIntrinsicContentSize, repeating).
    ///
    /// Folding to one Text per message cuts the NSTextField count
    /// 3-5× and breaks the cascade. Visual cost: bullet lists
    /// render as "• item" inline rather than as indented HStacks,
    /// code blocks lose their tinted background, headings render
    /// as bold inline rather than separate larger lines. Acceptable
    /// trade for a chat pane that scrolls.
    ///
    /// Recomputed only when `text` changes via `.task(id: text)`
    /// so a streaming append still re-renders, but a hover /
    /// scroll / unrelated state change reuses the cache.
    @State private var cache: Cache = Cache(text: "", attributed: AttributedString())

    var body: some View {
        // NSTextView wrapper for selection — see
        // `SelectableMessageText` for why this beats
        // `Text(...).textSelection(.enabled)` on macOS 26.
        SelectableMessageText(attributedString: cache.attributed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: text) {
                // Cancels-and-restarts on text change (streaming
                // append cadence). The fold is pure-string work,
                // safe to run on the MainActor at parse cost.
                let folded = Self.foldToAttributedString(text)
                cache = Cache(text: text, attributed: folded)
            }
    }

    // MARK: - Block parsing

    /// Coarse block types. Anything we don't recognize gets
    /// `.paragraph`, which still benefits from inline Markdown
    /// rendering via `AttributedString(markdown:)`.
    enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bulletList(items: [String])
        case orderedList(items: [String])
        case blockquote(String)
        case codeBlock(language: String?, code: String)
    }

    /// `Cache` keys the folded AttributedString by the text it came
    /// from so an out-of-order task completion (rare but possible
    /// during fast streaming) doesn't render against a stale text.
    private struct Cache: Equatable {
        let text: String
        let attributed: AttributedString
    }

    // MARK: - Folding blocks into one AttributedString

    /// Parse + fold in one pass. Each block contributes its inline
    /// AttributedString with block-specific attributes applied
    /// (heading → bold + larger; bullet → "• " prefix; code → fixed
    /// width; blockquote → secondary + italic). Blocks are separated
    /// by a double-newline so they wrap as paragraphs without
    /// needing layout primitives.
    static func foldToAttributedString(_ text: String) -> AttributedString {
        let blocks = parse(text)
        var out = AttributedString()
        for (i, block) in blocks.enumerated() {
            if i > 0 { out += AttributedString("\n\n") }
            out += renderBlockAttributed(block)
        }
        return out
    }

    /// Render one block into an AttributedString. Uses
    /// `AttributedString(markdown:)` for inline emphasis within
    /// the block's text payload so **bold** / *italic* / `code`
    /// still render correctly.
    private static func renderBlockAttributed(_ block: Block) -> AttributedString {
        switch block {
        case .paragraph(let text):
            return inlineAttributed(text)
        case .heading(let level, let text):
            var a = inlineAttributed(text)
            a.font = headingFontForFold(level: level)
            return a
        case .bulletList(let items):
            var combined = AttributedString()
            for (i, item) in items.enumerated() {
                if i > 0 { combined += AttributedString("\n") }
                var bullet = AttributedString("•  ")
                bullet.foregroundColor = .secondary
                combined += bullet
                combined += inlineAttributed(item)
            }
            return combined
        case .orderedList(let items):
            var combined = AttributedString()
            for (i, item) in items.enumerated() {
                if i > 0 { combined += AttributedString("\n") }
                var marker = AttributedString("\(i + 1).  ")
                marker.foregroundColor = .secondary
                combined += marker
                combined += inlineAttributed(item)
            }
            return combined
        case .blockquote(let text):
            var a = inlineAttributed(text)
            a.foregroundColor = .secondary
            // Italic via font modifier — applied as a SwiftUI font
            // attribute so it composes with the renderer's default
            // size / weight.
            a.font = .callout.italic()
            return a
        case .codeBlock(_, let code):
            var a = AttributedString(code)
            a.font = .callout.monospaced()
            return a
        }
    }

    /// Inline-Markdown render via `AttributedString(markdown:)`.
    /// `.inlineOnlyPreservingWhitespace` so the parser doesn't try
    /// to interpret block-level structure inside what we've
    /// already classified as one block.
    private static func inlineAttributed(_ s: String) -> AttributedString {
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            return try AttributedString(markdown: s, options: options)
        } catch {
            return AttributedString(s)
        }
    }

    private static func headingFontForFold(level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        default: return .callout.weight(.semibold)
        }
    }

    /// Walk the input line-by-line, batching lines into blocks.
    /// Blank lines separate blocks (CommonMark posture). Fenced
    /// code blocks span across blank lines until the closing
    /// fence — handled as a special case in the loop.
    /// Visible to tests so the block parser can be exercised
    /// without instantiating a SwiftUI view hierarchy.
    static func parseBlocks(_ text: String) -> [Block] {
        parse(text)
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Fenced code block — consume until the matching close
            // fence regardless of intervening blank lines.
            if line.hasPrefix("```") {
                let language = line
                    .dropFirst(3)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var codeLines: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                // Skip the closing fence if present.
                if i < lines.count { i += 1 }
                blocks.append(.codeBlock(
                    language: language.isEmpty ? nil : language,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }
            // Blank line — block separator.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }
            // Heading — `#` through `######` followed by a space.
            if let heading = parseHeading(line) {
                blocks.append(heading)
                i += 1
                continue
            }
            // Block quote — one or more leading-`>` lines until
            // a non-quote line breaks the run.
            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count, lines[i].hasPrefix(">") {
                    let stripped = String(lines[i].dropFirst())
                        .trimmingCharacters(in: .whitespaces)
                    quoteLines.append(stripped)
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: " ")))
                continue
            }
            // Bullet list — lines starting `- `, `* `, or `+ `.
            // Consume contiguous bullet lines.
            if isBulletLine(line) {
                var items: [String] = []
                while i < lines.count, isBulletLine(lines[i]) {
                    items.append(stripBulletPrefix(lines[i]))
                    i += 1
                }
                blocks.append(.bulletList(items: items))
                continue
            }
            // Ordered list — lines starting `N. `.
            if isOrderedLine(line) {
                var items: [String] = []
                while i < lines.count, isOrderedLine(lines[i]) {
                    items.append(stripOrderedPrefix(lines[i]))
                    i += 1
                }
                blocks.append(.orderedList(items: items))
                continue
            }
            // Default — accumulate non-blank lines into one
            // paragraph (single newlines within a paragraph collapse
            // to a single space, matching CommonMark).
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                if next.trimmingCharacters(in: .whitespaces).isEmpty
                    || isBulletLine(next)
                    || isOrderedLine(next)
                    || next.hasPrefix("```")
                    || next.hasPrefix(">")
                    || parseHeading(next) != nil {
                    break
                }
                paragraphLines.append(next)
                i += 1
            }
            blocks.append(.paragraph(
                paragraphLines.joined(separator: " ")
            ))
        }
        return blocks
    }

    private static func parseHeading(_ line: String) -> Block? {
        // Match `#` (1-6 of them) followed by a space and the
        // heading text. Anything else falls through.
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level >= 1, idx < line.endIndex, line[idx] == " " else {
            return nil
        }
        let text = String(line[line.index(after: idx)...])
            .trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func isBulletLine(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first,
              first == "-" || first == "*" || first == "+"
        else { return false }
        let afterMarker = trimmed.dropFirst()
        return afterMarker.first == " "
    }

    private static func stripBulletPrefix(_ line: String) -> String {
        var trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        trimmed = trimmed.dropFirst()  // bullet marker
        return trimmed
            .drop(while: { $0 == " " })
            .description
    }

    private static func isOrderedLine(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        var idx = trimmed.startIndex
        var sawDigit = false
        while idx < trimmed.endIndex, trimmed[idx].isNumber {
            sawDigit = true
            idx = trimmed.index(after: idx)
        }
        guard sawDigit, idx < trimmed.endIndex,
              trimmed[idx] == "." else { return false }
        let afterDot = trimmed.index(after: idx)
        return afterDot < trimmed.endIndex && trimmed[afterDot] == " "
    }

    private static func stripOrderedPrefix(_ line: String) -> String {
        var trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        // Drop digits.
        while let first = trimmed.first, first.isNumber {
            trimmed = trimmed.dropFirst()
        }
        // Drop `.` and following space.
        if trimmed.first == "." { trimmed = trimmed.dropFirst() }
        return trimmed.drop(while: { $0 == " " }).description
    }

}
