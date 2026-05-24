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
///
/// **R-Chat-Reinstate-Polish**: this view restores the per-block
/// rendering that commit `d0911b6` collapsed into a single
/// `Text(AttributedString)` during the chat-hang investigation.
/// Working theory now is that the hang was federated-index memory
/// pressure, not the multi-Text cascade — the R-Federated-Memory
/// -Pass changes dropped RSS from ~14 GB to ~3 GB and chat scroll
/// feels healthy at FP16. If hangs reappear after this restore,
/// revert this commit and the investigation moves back to the
/// view graph (most likely culprit: SelectionOverlay's setFont
/// loop on NSTextField-backed selectable Text).
struct MarkdownMessageBody: View {
    let text: String
    /// Cached block parse keyed by the input text. Recomputed only
    /// when `text` changes via `.task(id: text)` so a streaming
    /// append still re-parses, but a hover / scroll / unrelated
    /// state change reuses the cache.
    @State private var cache: Cache = Cache(text: "", blocks: [])

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(cache.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: text) {
            let parsed = Self.parseBlocks(text)
            cache = Cache(text: text, blocks: parsed)
        }
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("Copy Message", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let s):
            Text(Self.inlineAttributed(s))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(Self.inlineAttributed(s))
                .font(Self.headingFont(level: level))
                .fixedSize(horizontal: false, vertical: true)
                // Slightly tighter top padding so headings hug the
                // preceding paragraph the way prose readers expect.
                .padding(.top, level <= 2 ? 4 : 0)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(Self.inlineAttributed(item))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(idx + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(Self.inlineAttributed(item))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .blockquote(let s):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 3)
                Text(Self.inlineAttributed(s))
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .codeBlock(_, let code):
            Text(code)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                )
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

    /// Cache keys the parsed `[Block]` by the text it came from so
    /// an out-of-order task completion (rare but possible during
    /// fast streaming) doesn't render against a stale text.
    private struct Cache: Equatable {
        let text: String
        let blocks: [Block]
    }

    /// Inline-Markdown render via `AttributedString(markdown:)`.
    /// `.inlineOnlyPreservingWhitespace` so the parser doesn't try
    /// to interpret block-level structure inside what we've
    /// already classified as one block.
    static func inlineAttributed(_ s: String) -> AttributedString {
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            return try AttributedString(markdown: s, options: options)
        } catch {
            return AttributedString(s)
        }
    }

    private static func headingFont(level: Int) -> Font {
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
