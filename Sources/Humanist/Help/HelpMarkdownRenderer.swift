import Foundation

/// Minimal Markdown → HTML converter for the in-app help system.
/// Scope is deliberately narrow: cover the subset of CommonMark
/// the authored help docs in `Resources/Help/*.md` actually use —
/// ATX headings (#, ##, ###), paragraphs, fenced + inline code,
/// bullet + numbered lists, GFM pipe tables, emphasis (`**` /
/// `*` / `_`), inline links. No nested lists, no blockquotes, no
/// HTML pass-through, no footnotes. If a help doc surfaces a
/// construct that doesn't render, extend the renderer rather
/// than reaching for a third-party Markdown dependency — the
/// help vocabulary is hand-authored and small enough that this
/// stays manageable.
///
/// Output is an HTML document fragment (no `<html>` / `<body>`
/// wrapping); the WKWebView host wraps it in a template with
/// CSS. The fragment is escaped enough that user-supplied
/// Markdown can't inject script, but the only "user" here is
/// the help-doc author who has access to the .md files anyway,
/// so the escape posture is "don't accidentally break the HTML
/// parser" rather than "defend against hostile input."
enum HelpMarkdownRenderer {

    /// Convert a Markdown string into an HTML document fragment.
    static func render(_ markdown: String) -> String {
        // Normalize line endings so the block-splitter doesn't
        // see CR-LF as something different from LF.
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = splitIntoBlocks(normalized)
        var html: [String] = []
        for block in blocks {
            html.append(renderBlock(block))
        }
        return html.joined(separator: "\n")
    }

    // MARK: - Block splitting

    /// Split the Markdown into logical blocks. Fenced code blocks
    /// (```…```) are kept as a single block even when they
    /// contain blank lines internally. Everything else splits on
    /// blank lines.
    private static func splitIntoBlocks(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var inFence = false

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                current.append(lineStr)
                if inFence {
                    blocks.append(current.joined(separator: "\n"))
                    current.removeAll()
                }
                inFence.toggle()
                continue
            }
            if inFence {
                current.append(lineStr)
                continue
            }
            if trimmed.isEmpty {
                if !current.isEmpty {
                    blocks.append(current.joined(separator: "\n"))
                    current.removeAll()
                }
                continue
            }
            current.append(lineStr)
        }
        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }
        return blocks
    }

    // MARK: - Block dispatch

    private static func renderBlock(_ block: String) -> String {
        let trimmed = block.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            return renderFencedCode(block)
        }
        if let heading = renderHeading(trimmed) {
            return heading
        }
        if isTable(trimmed) {
            return renderTable(block)
        }
        if isList(trimmed) {
            return renderList(block)
        }
        return "<p>\(renderInline(trimmed))</p>"
    }

    // MARK: - Headings

    private static func renderHeading(_ line: String) -> String? {
        for level in [3, 2, 1] {
            let marker = String(repeating: "#", count: level) + " "
            if line.hasPrefix(marker) {
                let text = String(line.dropFirst(marker.count))
                return "<h\(level)>\(renderInline(text))</h\(level)>"
            }
        }
        return nil
    }

    // MARK: - Fenced code

    private static func renderFencedCode(_ block: String) -> String {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else {
            return "<pre><code>\(escapeHTML(block))</code></pre>"
        }
        // Drop opening + closing ```; ignore the language hint
        // (CSS doesn't syntax-highlight in v1).
        let body = lines.dropFirst().dropLast().joined(separator: "\n")
        return "<pre><code>\(escapeHTML(body))</code></pre>"
    }

    // MARK: - Lists

    private static func isList(_ block: String) -> Bool {
        guard let first = block.split(separator: "\n").first else { return false }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("* ")
            || trimmed.range(of: "^[0-9]+\\. ", options: .regularExpression) != nil
    }

    private static func renderList(_ block: String) -> String {
        let lines = block.split(separator: "\n").map(String.init)
        let isOrdered = lines.first.map {
            $0.trimmingCharacters(in: .whitespaces)
                .range(of: "^[0-9]+\\. ", options: .regularExpression) != nil
        } ?? false
        let tag = isOrdered ? "ol" : "ul"
        var items: [String] = []
        for line in lines {
            var content = line.trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("- ") || content.hasPrefix("* ") {
                content = String(content.dropFirst(2))
            } else if let m = content.range(
                of: "^[0-9]+\\. ", options: .regularExpression
            ) {
                content = String(content[m.upperBound...])
            }
            items.append("<li>\(renderInline(content))</li>")
        }
        return "<\(tag)>\n\(items.joined(separator: "\n"))\n</\(tag)>"
    }

    // MARK: - Tables (GFM pipe style)

    private static func isTable(_ block: String) -> Bool {
        let lines = block.split(separator: "\n")
        guard lines.count >= 2 else { return false }
        // Second line must be the separator row (---).
        let second = lines[1].trimmingCharacters(in: .whitespaces)
        return lines[0].contains("|")
            && second.contains("|")
            && second.allSatisfy { "|:- \t".contains($0) }
    }

    private static func renderTable(_ block: String) -> String {
        let lines = block.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return "<p>\(renderInline(block))</p>" }
        let headerCells = splitTableRow(lines[0])
        // lines[1] is the separator row; skip.
        let bodyRows = lines.dropFirst(2).map(splitTableRow)
        var html = "<table>\n<thead><tr>"
        for cell in headerCells {
            html += "<th>\(renderInline(cell))</th>"
        }
        html += "</tr></thead>\n<tbody>\n"
        for row in bodyRows {
            html += "<tr>"
            for cell in row {
                html += "<td>\(renderInline(cell))</td>"
            }
            html += "</tr>\n"
        }
        html += "</tbody></table>"
        return html
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var parts = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // GFM rows often start + end with |, producing empty cells
        // at both ends. Strip them.
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    // MARK: - Inline pass

    /// Apply inline transformations: code spans, bold, italic,
    /// links. Order matters — code spans first so backticks
    /// inside them don't get misread, then bold (`**…**`) before
    /// italic so `**foo**` doesn't match as italic-italic.
    private static func renderInline(_ text: String) -> String {
        var s = escapeHTML(text)
        // Inline code: `…`. Substitute placeholders so the bold /
        // italic / link passes don't see the inside of code spans.
        var codeSnippets: [String] = []
        s = replaceRegex(s, pattern: "`([^`]+)`") { match in
            let code = String(match[match.index(after: match.startIndex)..<match.index(before: match.endIndex)])
            codeSnippets.append(code)
            return "\u{0000}CODE\(codeSnippets.count - 1)\u{0000}"
        }
        // Bold: **…**
        s = replaceRegex(s, pattern: "\\*\\*([^*]+)\\*\\*") { match in
            let inner = String(match.dropFirst(2).dropLast(2))
            return "<strong>\(inner)</strong>"
        }
        // Italic: *…*  or  _…_
        s = replaceRegex(s, pattern: "\\*([^*]+)\\*") { match in
            let inner = String(match.dropFirst().dropLast())
            return "<em>\(inner)</em>"
        }
        s = replaceRegex(s, pattern: "(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])") { match in
            let inner = String(match.dropFirst().dropLast())
            return "<em>\(inner)</em>"
        }
        // Links: [text](url)
        s = replaceRegex(s, pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)") { match in
            // Capture groups via a second pass since `replaceRegex`
            // hands back the full match. Re-extract with NSRegular.
            guard let r = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)"),
                  let m = r.firstMatch(
                    in: match, range: NSRange(match.startIndex..., in: match)
                  ),
                  m.numberOfRanges == 3,
                  let textR = Range(m.range(at: 1), in: match),
                  let urlR = Range(m.range(at: 2), in: match)
            else { return match }
            return "<a href=\"\(match[urlR])\">\(match[textR])</a>"
        }
        // Restore code spans last.
        for (idx, code) in codeSnippets.enumerated() {
            s = s.replacingOccurrences(
                of: "\u{0000}CODE\(idx)\u{0000}",
                with: "<code>\(escapeHTML(code))</code>"
            )
        }
        return s
    }

    // MARK: - Helpers

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Tiny regex helper. Iterates each match (left-to-right,
    /// non-overlapping) and lets the caller produce the replacement.
    /// Stdlib's `replacingOccurrences(of:options:)` and SwiftRegex
    /// both work for these patterns, but neither makes it easy to
    /// keep an index across matches for the code-span placeholder
    /// dance above.
    private static func replaceRegex(
        _ input: String,
        pattern: String,
        replacement: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        var result = ""
        var cursor = input.startIndex
        let matches = regex.matches(
            in: input, range: NSRange(input.startIndex..., in: input)
        )
        for match in matches {
            guard let range = Range(match.range, in: input) else { continue }
            result.append(contentsOf: input[cursor..<range.lowerBound])
            let full = String(input[range])
            result.append(contentsOf: replacement(full))
            cursor = range.upperBound
        }
        result.append(contentsOf: input[cursor..<input.endIndex])
        return result
    }
}
