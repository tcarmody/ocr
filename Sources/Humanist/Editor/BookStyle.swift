import Foundation

/// R-Custom-Styles. User-facing styling choices for an open book —
/// font family, font size, and theme — that the editor renders into
/// the EPUB's `OEBPS/css/book.css` and persists in the file itself
/// via a sentinel JSON comment. Round-trips across save / reopen
/// without needing a separate META-INF sidecar.
public struct BookStyle: Codable, Equatable, Sendable {
    public enum FontFamily: String, Codable, CaseIterable, Sendable {
        case serif      // Georgia, Times New Roman — the original default
        case sans       // -apple-system, Helvetica Neue
        case monospace  // SF Mono, Menlo
    }

    public enum Theme: String, Codable, CaseIterable, Sendable {
        case light  // white bg, black text
        case sepia  // warm cream bg, dark brown text
        case dark   // dark grey bg, light text
    }

    public var font: FontFamily
    /// Body font size in `em`. 1.0 is the default; sane range
    /// 0.75 – 1.5 covers most reading preferences.
    public var fontSize: Double
    public var theme: Theme

    public init(
        font: FontFamily = .serif,
        fontSize: Double = 1.0,
        theme: Theme = .light
    ) {
        self.font = font
        self.fontSize = fontSize
        self.theme = theme
    }

    public static let `default` = BookStyle()
}

/// Renders / parses `OEBPS/css/book.css` for `BookStyle`. The
/// generated CSS keeps the original `EPUBStaticFiles.bookCSS` rules
/// as a baseline, then appends body-level overrides for font /
/// size / theme. A sentinel comment carrying JSON lets us recover
/// the user's choices on next open without a separate sidecar.
public enum BookCSSBuilder {

    /// Sentinel that marks the auto-generated style block.
    /// Anything between START and END can be regenerated; user
    /// edits to the rest of `book.css` are preserved.
    static let blockStart = "/* humanist-style:start */"
    static let blockEnd   = "/* humanist-style:end */"

    /// Generate a complete `book.css` for the given style on top
    /// of the existing CSS contents (or the default when no CSS
    /// exists yet). The generated style block replaces any
    /// previously-generated block; non-style edits round-trip.
    public static func apply(style: BookStyle, to existingCSS: String?) -> String {
        let base = stripStyleBlock(existingCSS ?? defaultBaseCSS)
        let block = renderStyleBlock(style)
        // Append the style block at the end so author rules above
        // it stay readable and the override section is clearly
        // demarcated.
        if base.hasSuffix("\n") {
            return base + "\n" + block + "\n"
        }
        return base + "\n\n" + block + "\n"
    }

    /// Recover the user's `BookStyle` from a `book.css` blob.
    /// Returns nil when no sentinel is present (un-styled book or
    /// pre-R-Custom-Styles EPUB).
    public static func parse(_ css: String) -> BookStyle? {
        guard let payload = extractStyleJSON(from: css),
              let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(BookStyle.self, from: data)
    }

    /// The default CSS we ship for new books. Identical to
    /// `EPUBStaticFiles.bookCSS` — duplicated here so this module
    /// doesn't reach across into EPUB just for a constant string,
    /// and so a future divergence (e.g. editor-only stylesheet
    /// extensions) doesn't tangle the two.
    static let defaultBaseCSS = """
        body { font-family: Georgia, "Times New Roman", serif; line-height: 1.5; margin: 1em; }
        h1, h2, h3, h4, h5, h6 { font-family: -apple-system, "Helvetica Neue", sans-serif; line-height: 1.2; }
        p { margin: 0 0 0.6em 0; text-indent: 1.2em; }
        p:first-of-type { text-indent: 0; }
        a[epub|type~="noteref"] { vertical-align: super; font-size: 0.75em; }
        aside[epub|type~="footnote"] { display: none; }
        figure { margin: 1em 0; text-align: center; }
        figure img { max-width: 100%; height: auto; }
        figcaption { font-size: 0.85em; font-style: italic; margin-top: 0.4em; }
        table { border-collapse: collapse; margin: 1em auto; }
        th, td { border: 1px solid #ccc; padding: 0.3em 0.5em; text-align: left; vertical-align: top; }
        th { background: #f5f5f5; font-weight: bold; }
        caption { font-size: 0.85em; font-style: italic; margin-bottom: 0.4em; }
        """

    // MARK: - rendering

    /// Build the override block for `style`. The block starts with
    /// `blockStart`, ends with `blockEnd`, and carries a JSON
    /// sentinel inside `humanist-style:` so we can round-trip
    /// the choices on next open.
    static func renderStyleBlock(_ style: BookStyle) -> String {
        let json = jsonString(for: style)
        var lines: [String] = [blockStart]
        lines.append("/* humanist-style: \(json) */")
        lines.append("body { \(bodyOverrides(style)) }")
        return (lines + [blockEnd]).joined(separator: "\n")
    }

    /// Body-level CSS overrides for the style. Only properties the
    /// user actually picked are emitted; the baseline rules
    /// inherited from the default CSS handle the rest.
    static func bodyOverrides(_ style: BookStyle) -> String {
        var parts: [String] = []
        parts.append("font-family: \(fontStack(style.font));")
        parts.append("font-size: \(formatSize(style.fontSize));")
        let (bg, fg) = themeColors(style.theme)
        parts.append("background: \(bg);")
        parts.append("color: \(fg);")
        return parts.joined(separator: " ")
    }

    static func fontStack(_ family: BookStyle.FontFamily) -> String {
        switch family {
        case .serif:
            return "Georgia, \"Times New Roman\", serif"
        case .sans:
            return "-apple-system, \"Helvetica Neue\", Helvetica, Arial, sans-serif"
        case .monospace:
            return "\"SF Mono\", Menlo, Consolas, monospace"
        }
    }

    static func themeColors(_ theme: BookStyle.Theme) -> (String, String) {
        switch theme {
        case .light: return ("#ffffff", "#1a1a1a")
        case .sepia: return ("#f4ecd8", "#5b4636")
        case .dark:  return ("#1e1e1e", "#d6d6d6")
        }
    }

    /// Format a font-size value in `em`. Trims trailing zeros so
    /// `1.0` renders as `1em` rather than `1.0em`, and clamps to
    /// the 0.5–2.0 range so a corrupted value can't produce
    /// unreadable output.
    static func formatSize(_ size: Double) -> String {
        let clamped = max(0.5, min(2.0, size))
        if clamped == clamped.rounded() {
            return "\(Int(clamped))em"
        }
        // Two decimal places at most; strip trailing zeros.
        var s = String(format: "%.2f", clamped)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return "\(s)em"
    }

    // MARK: - parsing

    /// Strip the previous `humanist-style:start … humanist-style:end`
    /// block (and any leading blank lines) from `css`, leaving the
    /// rest intact. Idempotent: if no block is present, returns the
    /// input as-is.
    static func stripStyleBlock(_ css: String) -> String {
        guard let startRange = css.range(of: blockStart),
              let endRange = css.range(of: blockEnd, range: startRange.upperBound..<css.endIndex)
        else { return css }
        var result = String(css[..<startRange.lowerBound])
            + String(css[endRange.upperBound...])
        // Trim trailing whitespace + blank lines so consecutive
        // applies don't accumulate empty lines.
        while result.hasSuffix("\n\n") || result.hasSuffix("\n ") {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n"
    }

    /// Pull the JSON payload out of the `humanist-style: {...}`
    /// sentinel inside the style block. Returns nil when the
    /// sentinel is missing or malformed.
    static func extractStyleJSON(from css: String) -> String? {
        // Match `humanist-style: {...}` greedily within a comment.
        let pattern = #"humanist-style:\s*(\{[^}]*\})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(css.startIndex..., in: css)
        guard let match = regex.firstMatch(in: css, range: range),
              match.numberOfRanges >= 2,
              let payloadRange = Range(match.range(at: 1), in: css) else {
            return nil
        }
        return String(css[payloadRange])
    }

    private static func jsonString(for style: BookStyle) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(style),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}
