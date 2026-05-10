import Foundation

/// Strip and harvest model-suggested follow-up questions from an
/// assistant turn's raw text. Both `BookChatViewModel` and
/// `LibraryChatViewModel` use this after their citation parsers so
/// the visible `text` ends with the answer (no trailing follow-up
/// block) but the message's `suggestedFollowUps` field carries the
/// list for one-click rendering.
///
/// Wire format (chosen because it mirrors the chat's existing
/// `[chapter:N]` citation marker shape — easy regex, doesn't collide
/// with prose, low chance of accidental output):
///
/// ```
/// [follow-ups]
/// What does the author say about X?
/// How does this compare to Y?
/// Where does this argument appear elsewhere?
/// [/follow-ups]
/// ```
///
/// One question per line, leading bullet/dash optional. The block
/// must be the *last* thing in the response — content after the
/// closing tag is stripped but the parser doesn't try to splice
/// around mid-message follow-up blocks.
enum FollowUpParser {

    static func parse(_ text: String) -> (cleaned: String, followUps: [String]) {
        // Match `[follow-ups]` ... `[/follow-ups]` non-greedy.
        // Captured group 1 = inner block content. `.dotMatchesLineSeparators`
        // (`(?s)`) so `.*?` spans newlines.
        let pattern = "(?s)\\[follow-ups\\](.*?)\\[/follow-ups\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, [])
        }
        let nsText = text as NSString
        guard let match = regex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ), match.numberOfRanges >= 2 else {
            return (text, [])
        }
        // Inner content between the tags.
        let inner = nsText.substring(with: match.range(at: 1))
        let questions = inner
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { stripBullet(String($0)).trimmingCharacters(
                in: .whitespacesAndNewlines
            ) }
            .filter { !$0.isEmpty }

        // Strip the marker block + everything after. Trim trailing
        // whitespace so the visible text doesn't end on a blank line.
        let outer = match.range(at: 0)
        let prefixEnd = outer.location
        let cleaned = nsText
            .substring(to: prefixEnd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, questions)
    }

    /// Strip leading bullet markers (`-`, `*`, `1.`, `2.`, etc.) so
    /// a question rendered as a list item parses to plain text the
    /// chat input can re-send verbatim.
    private static func stripBullet(_ s: String) -> String {
        var trimmed = s.drop(while: { $0 == " " || $0 == "\t" })
        // Bullet markers
        if let first = trimmed.first,
           first == "-" || first == "*" || first == "+" {
            let after = trimmed.dropFirst()
            if after.first == " " {
                return after
                    .drop(while: { $0 == " " })
                    .description
            }
        }
        // Numeric markers like "1. " or "12. "
        var idx = trimmed.startIndex
        var sawDigit = false
        while idx < trimmed.endIndex, trimmed[idx].isNumber {
            sawDigit = true
            idx = trimmed.index(after: idx)
        }
        if sawDigit, idx < trimmed.endIndex, trimmed[idx] == "." {
            let afterDot = trimmed.index(after: idx)
            if afterDot < trimmed.endIndex, trimmed[afterDot] == " " {
                trimmed = trimmed[trimmed.index(after: afterDot)...]
                return String(trimmed).drop(while: { $0 == " " }).description
            }
        }
        return s
    }
}
