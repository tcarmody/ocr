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
    /// Cached block parse + inline AttributedStrings. SwiftUI
    /// recomputes the view's `body` on every observable change in
    /// the enclosing chat pane — that's many times per second
    /// while scrolling, while streaming, while a tool status flips.
    /// Without caching, each recompute paid the full Markdown
    /// parse (regex line splitting + per-line `AttributedString(
    /// markdown:)` calls) for every visible message; on a long
    /// transcript that compounded into 100s of regex passes per
    /// scroll frame and produced visible hangs (sampled main
    /// thread pinned in SelectionOverlay/JetUI update cascades
    /// downstream of body recompute).
    ///
    /// Recomputed only when `text` changes (via the `id:` modifier
    /// on the outer view) so a streaming append still re-parses,
    /// but a hover / scroll / unrelated state change reuses the
    /// cache.
    @State private var cache: Cache = Cache(text: "", blocks: [])

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cache.blocks.indices, id: \.self) { idx in
                renderBlock(cache.blocks[idx])
            }
        }
        // Selection scoped to the whole message so a user can drag
        // across multiple paragraphs the way they would in any
        // standard text view.
        .textSelection(.enabled)
        .task(id: text) {
            // Parse off the main actor only when the input changes;
            // `.task(id:)` cancels + restarts on every text change
            // which is exactly the streaming-append cadence we want
            // (cancel old parse, start fresh on the new text).
            let blocks = Self.parse(text)
            cache = Cache(text: text, blocks: blocks)
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

    /// `Cache` keys parsed blocks by the text they came from so an
    /// out-of-order task completion (rare but possible during fast
    /// streaming) doesn't render blocks against a stale text.
    private struct Cache: Equatable {
        let text: String
        let blocks: [Block]
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

    // MARK: - Block rendering

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inline(text))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(for: level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? 4 : 2)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { idx in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(items[idx]))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { idx in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(idx + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(inline(items[idx]))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .blockquote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(inline(text))
                    .foregroundStyle(.secondary)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .codeBlock(_, let code):
            Text(code)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                )
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        default: return .body.weight(.semibold)
        }
    }

    /// Inline-Markdown pass via `AttributedString(markdown:)`.
    /// Falls back to the raw string when parsing fails (rare —
    /// only on input the parser actively rejects, like an
    /// unbalanced bracket pair).
    private func inline(_ s: String) -> AttributedString {
        do {
            // `.inlineOnlyPreservingWhitespace` keeps the input's
            // single-newline / multi-space layout untouched so the
            // parser doesn't re-flow chat text.
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            return try AttributedString(markdown: s, options: options)
        } catch {
            return AttributedString(s)
        }
    }
}
