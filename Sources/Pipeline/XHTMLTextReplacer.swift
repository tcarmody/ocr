import Foundation

/// Apply `ClaudeCoherenceAnalyzer.Suggestion` rewrites to a raw
/// XHTML string, scoped to text content nodes only. Tags,
/// attributes, comments, CDATA, processing instructions, and
/// `<script>` / `<style>` element bodies all pass through
/// byte-identical.
///
/// Used by the EPUB import path so the coherence pass can apply
/// recurring-OCR-error rewrites without going through a
/// full-fidelity XHTML → Chapter IR round-trip. Publisher-specific
/// formatting that `Chapter` doesn't model (custom CSS classes,
/// inline styles, namespaced attributes, unusual asides) survives
/// unchanged.
///
/// The replacement loop matches the existing `Chapter`-side
/// `applyWithGuardrails` semantics: case-sensitive, plain
/// `replacingOccurrences`, applied in the order suggestions were
/// passed in. Callers are responsible for running suggestions
/// through `ClaudeCoherenceAnalyzer.filterByGuardrails` first;
/// this helper does not re-validate.
public enum XHTMLTextReplacer {

    /// Apply `suggestions` to `xhtml`. Returns the rewritten
    /// XHTML, or `xhtml` unchanged when no suggestion's `wrong`
    /// string occurs in any text region.
    public static func apply(
        suggestions: [ClaudeCoherenceAnalyzer.Suggestion],
        xhtml: String
    ) -> String {
        guard !suggestions.isEmpty else { return xhtml }

        var output = ""
        output.reserveCapacity(xhtml.count)
        var i = xhtml.startIndex
        let end = xhtml.endIndex
        /// When non-nil, we're inside `<script>` or `<style>`
        /// body and every char up to the matching close tag
        /// passes through unchanged.
        var skipUntilCloseOf: String? = nil

        while i < end {
            if let tag = skipUntilCloseOf {
                let close = "</\(tag)"
                if let closeRange = xhtml.range(
                    of: close,
                    options: [.caseInsensitive],
                    range: i..<end
                ) {
                    // Body of the script/style up to (but not
                    // including) the closing tag is verbatim.
                    output.append(contentsOf: xhtml[i..<closeRange.lowerBound])
                    i = closeRange.lowerBound
                    skipUntilCloseOf = nil
                } else {
                    // Malformed: no closing tag. Pass the rest
                    // through unchanged rather than scribbling
                    // over script source.
                    output.append(contentsOf: xhtml[i..<end])
                    i = end
                }
                continue
            }

            let c = xhtml[i]
            if c == "<" {
                let consumed = consumeMarkup(in: xhtml, from: i, end: end)
                output.append(contentsOf: xhtml[i..<consumed.endIndex])
                if let entered = consumed.entersRawText {
                    skipUntilCloseOf = entered
                }
                i = consumed.endIndex
            } else {
                // Text region: scan to the next `<`, apply
                // replacements, append.
                let nextLT = xhtml[i..<end].firstIndex(of: "<") ?? end
                let region = String(xhtml[i..<nextLT])
                output.append(applyReplacements(to: region, suggestions: suggestions))
                i = nextLT
            }
        }
        return output
    }

    // MARK: - markup consumption

    /// Result of consuming one markup construct (tag, comment,
    /// CDATA, PI) starting at `<`. `entersRawText` is the tag name
    /// (`script` or `style`) when this is an opening tag whose
    /// body should not be touched.
    private struct MarkupConsumption {
        let endIndex: String.Index
        let entersRawText: String?
    }

    /// Identify the markup construct that begins at `xhtml[start]`
    /// (which must be `<`) and return the index one past its end.
    /// Falls back to "consume to `>`" for ordinary tags.
    private static func consumeMarkup(
        in xhtml: String, from start: String.Index, end: String.Index
    ) -> MarkupConsumption {
        // Comment: <!-- ... -->
        if xhtml[start..<end].hasPrefix("<!--") {
            if let close = xhtml.range(of: "-->", range: start..<end) {
                return MarkupConsumption(
                    endIndex: close.upperBound, entersRawText: nil
                )
            }
            return MarkupConsumption(endIndex: end, entersRawText: nil)
        }
        // CDATA: <![CDATA[ ... ]]>
        if xhtml[start..<end].hasPrefix("<![CDATA[") {
            if let close = xhtml.range(of: "]]>", range: start..<end) {
                return MarkupConsumption(
                    endIndex: close.upperBound, entersRawText: nil
                )
            }
            return MarkupConsumption(endIndex: end, entersRawText: nil)
        }
        // Processing instruction: <? ... ?>
        if xhtml[start..<end].hasPrefix("<?") {
            if let close = xhtml.range(of: "?>", range: start..<end) {
                return MarkupConsumption(
                    endIndex: close.upperBound, entersRawText: nil
                )
            }
            return MarkupConsumption(endIndex: end, entersRawText: nil)
        }
        // DOCTYPE: <!DOCTYPE ...>. Same shape as ordinary tag —
        // find the matching `>`.
        // Fall through to the general tag path; the `<!` prefix
        // is handled the same way as `<x`.

        // Ordinary tag: scan to the first `>`. EPUB XHTML 5 is
        // XML-compliant — attribute values quote any `>` they
        // contain, so naive scan is safe in practice.
        let gtIndex = xhtml[start..<end].firstIndex(of: ">") ?? end
        let tagEnd: String.Index
        if gtIndex < end {
            tagEnd = xhtml.index(after: gtIndex)
        } else {
            tagEnd = end
        }
        let tagSlice = xhtml[start..<tagEnd]
        return MarkupConsumption(
            endIndex: tagEnd,
            entersRawText: rawTextTagOpened(by: tagSlice)
        )
    }

    /// Returns `"script"` / `"style"` when `tag` is an *opening*
    /// `<script>` or `<style>` tag (not self-closing, not a close
    /// tag). Returns nil otherwise.
    private static func rawTextTagOpened(
        by tag: Substring
    ) -> String? {
        // Skip close tags and self-closing tags.
        guard !tag.hasPrefix("</") else { return nil }
        let trimmed = tag.dropFirst()  // strip leading <
        // Self-closing: `<style ... />`. The slash sits just
        // before the closing `>`.
        if tag.hasSuffix("/>") { return nil }
        // Match tag name case-insensitively.
        let lowercase = trimmed.lowercased()
        if lowercase.hasPrefix("script") {
            let next = lowercase.dropFirst("script".count).first
            if next == nil || next == " " || next == "\t"
                || next == "\n" || next == ">" {
                return "script"
            }
        }
        if lowercase.hasPrefix("style") {
            let next = lowercase.dropFirst("style".count).first
            if next == nil || next == " " || next == "\t"
                || next == "\n" || next == ">" {
                return "style"
            }
        }
        return nil
    }

    // MARK: - replacement

    /// Apply every suggestion's `wrong → right` to `text` via
    /// case-sensitive substring replacement. Matches the
    /// existing `Chapter`-side semantics in
    /// `ClaudeCoherenceAnalyzer.applyWithGuardrails`.
    private static func applyReplacements(
        to text: String,
        suggestions: [ClaudeCoherenceAnalyzer.Suggestion]
    ) -> String {
        var s = text
        for sug in suggestions {
            guard !sug.wrong.isEmpty else { continue }
            s = s.replacingOccurrences(of: sug.wrong, with: sug.right)
        }
        return s
    }
}
