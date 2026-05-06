import Foundation

/// Convert straight quotes / apostrophes (`"`, `'`) to typographic
/// curly equivalents (`“`, `”`, `‘`, `’`) in XHTML text content,
/// **without touching characters that sit inside tags**. Attribute
/// values (`href="…"`), processing instructions (`<?xml … ?>`),
/// and DOCTYPE declarations all stay byte-stable; only the text
/// between tags is transformed.
///
/// Algorithm:
/// 1. Walk the source character by character, tracking `inTag`.
///    `<` opens a tag, `>` closes it. (XML / XHTML doesn't allow
///    raw `<` or `>` in attribute values, so a flat depth-counter
///    isn't needed; the alternation works.)
/// 2. Inside tags, characters pass through verbatim.
/// 3. Outside tags, `"` and `'` are classified as opening or
///    closing based on the preceding character — whitespace,
///    bracket openers, dashes, and the start of the string all
///    open; alphanumerics and punctuation close. This handles the
///    common cases (`"hello"` → `“hello”`, `don't` → `don’t`,
///    `(it's)` → `(it’s)`) but doesn't try to handle every edge
///    case (e.g. elisions like `'cause` → `‘cause`, technically
///    wrong; user can hand-fix).
///
/// Comments (`<!--…-->`) and CDATA sections (`<![CDATA[…]]>`)
/// land in the "inside tag" path so their content is left alone —
/// acceptable because user-facing prose almost never lives there.
public enum SmartQuoter {

    /// Transform straight quotes in `source` to curly. See type
    /// docs for the algorithm and limitations.
    public static func smartQuote(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var inTag = false
        var prev: Character? = nil

        for ch in source {
            if inTag {
                out.append(ch)
                if ch == ">" { inTag = false }
                // Don't update `prev` while inside a tag — the
                // openness check that follows the `>` should look
                // at the last *text* character before the tag, not
                // the `>` itself. If the tag is at the start of
                // the document, prev stays nil and the next quote
                // opens correctly.
                continue
            }
            if ch == "<" {
                inTag = true
                out.append(ch)
                prev = nil
                continue
            }
            switch ch {
            case "\"":
                out.append(isOpener(prev: prev) ? "\u{201C}" : "\u{201D}")
            case "'":
                out.append(isOpener(prev: prev) ? "\u{2018}" : "\u{2019}")
            default:
                out.append(ch)
            }
            prev = ch
        }
        return out
    }

    /// True when a quote with this preceding character should be
    /// rendered as an opening curly. Whitespace, bracket openers,
    /// dashes, opening quotes, and start-of-string all open; word
    /// characters / closing punctuation close.
    static func isOpener(prev: Character?) -> Bool {
        guard let p = prev else { return true }
        if p.isWhitespace { return true }
        switch p {
        case "(", "[", "{",
             "\u{2018}", "\u{201C}",   // existing curly openers
             "-", "\u{2013}", "\u{2014}":  // hyphen, en-dash, em-dash
            return true
        default:
            return false
        }
    }
}
