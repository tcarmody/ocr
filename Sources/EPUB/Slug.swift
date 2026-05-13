import Foundation

/// Filename slug derived from a chapter's first heading. Used by the
/// editor's "Rename Chapter from First Heading" command and (in a
/// future commit) by the chapter-splitter's auto-naming path so a
/// split essay lands at e.g.
/// `on-the-program-of-the-coming-philosophy.xhtml` rather than
/// `chapter-001_split_001.xhtml`.
///
/// The shape is deliberately conservative — same constraints
/// `EditorViewModel.isValidBasename` enforces on user-typed names,
/// so a slug never produces a basename the editor would then reject:
///   * Decode the handful of HTML entities likely to land in
///     scraped headings.
///   * Strip filesystem-breaking characters (`/`, `\`, `:`, `*`,
///     `?`, `"`, `<`, `>`, `|`).
///   * Apostrophes are stripped too — valid in macOS / EPUB but
///     URL-encode in hrefs, which makes the resulting filename
///     ugly when surfaced.
///   * Whitespace runs collapse to single hyphens; consecutive
///     hyphens collapse; leading + trailing hyphens trim.
///   * Cap at `maxLength` characters on a hyphen boundary so the
///     resulting filename stays well under APFS's 255-byte ceiling
///     once `.xhtml` and any directory prefix are appended.
///
/// Returns nil when the input slugifies to the empty string
/// (heading was punctuation-only, or pure HTML markup). Callers
/// fall back to a counter-based name in that case.
public enum Slug {

    /// Cap on slug length, applied on a hyphen boundary. 80 leaves
    /// comfortable room for `text/`, the `.xhtml` extension, any
    /// `-NN` collision suffix, and macOS APFS's 255-byte ceiling.
    /// Matches the bound in `R-Split-Filename-Sanity`'s primary
    /// loop.
    public static let maxLength = 80

    /// Slugify `text`. Returns nil when the result is empty
    /// (heading was nothing but punctuation, HTML tags, or
    /// markup-only content).
    ///
    /// Strategy: decode entities → strip HTML → whitespace runs
    /// become single hyphens → whitelist filter keeps only
    /// letters / digits / `_-.` (matches `EditorViewModel
    /// .isValidBasename`'s allowed set, so the slug never
    /// produces a basename the rename UI would then reject) →
    /// collapse consecutive hyphens → trim → length cap.
    public static func fromHeading(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var s = decodeEntities(text)
        s = stripHTMLTags(s)
        // Replace whitespace runs with single hyphens BEFORE the
        // whitelist filter so the spaces become explicit
        // separators that survive the filter.
        s = s.split(
            whereSeparator: { $0.isWhitespace || $0.isNewline }
        ).joined(separator: "-")
        // Whitelist filter: keep letters / digits / underscore /
        // hyphen / dot. Drops apostrophes, smart quotes, em/en
        // dashes, ampersands, path separators, glob meta-chars —
        // everything that would be URL-encoded or filesystem-
        // hostile.
        s = String(s.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-"
                || scalar == "_"
                || scalar == "."
        })
        // Collapse runs of hyphens that appeared from adjacent
        // stripped punctuation (`"X — Y"` → `X--Y`).
        while s.contains("--") {
            s = s.replacingOccurrences(of: "--", with: "-")
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !s.isEmpty else { return nil }
        return truncateAtHyphen(s, max: maxLength)
    }

    // MARK: - Helpers

    private static func decodeEntities(_ s: String) -> String {
        // Minimal set — enough for headings that came from OPF
        // metadata or copied-in HTML. Production HTML decoders are
        // overkill here; the input is always small + bounded.
        var out = s
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        out = out.replacingOccurrences(of: "&lt;", with: "<")
        out = out.replacingOccurrences(of: "&gt;", with: ">")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&apos;", with: "'")
        out = out.replacingOccurrences(of: "&#39;", with: "'")
        out = out.replacingOccurrences(of: "&nbsp;", with: " ")
        return out
    }

    private static func stripHTMLTags(_ s: String) -> String {
        s.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
    }

    /// Truncate `s` at the last hyphen ≤ `max` characters so the
    /// result reads as a complete word. Falls back to a hard cut
    /// when there's no hyphen within range (single very long token).
    private static func truncateAtHyphen(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let prefix = s.prefix(max)
        if let lastHyphen = prefix.lastIndex(of: "-") {
            return String(s[..<lastHyphen])
        }
        return String(prefix)
    }
}

