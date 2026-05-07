import Foundation

/// Splice operation that replaces the body of a single Humanist
/// page (between two `<span id="hu-page-N">` anchors) inside an
/// XHTML chapter.
///
/// Used by:
///   * The Re-OCR Current Page command's "Replace in Source" path —
///     dispatched through CodeMirror's JS bridge for live edits.
///   * The bulk Re-OCR All Pages flow (V-Refresh) — applied directly
///     to the in-memory `Resource.text` so a 400-page bulk re-OCR
///     doesn't have to round-trip through CodeMirror per page.
///
/// Mirrors the JS implementation in `Resources/codemirror/index.html`
/// (`humanistReplacePageInSource`) so behavior stays consistent
/// across the live-edit and bulk paths.
public enum PageContentReplacer {

    /// Replace the body of the page identified by `anchorId` in
    /// `chapterText` with `newXHTML`. The page body is everything
    /// between the closing `>` of `<span … id="anchorId">` and the
    /// start of the next `<span … id="hu-page-N">` (or `</body>`,
    /// for the last page in a chapter). The anchor itself is left
    /// in place — only its content is replaced.
    ///
    /// Returns nil when the anchor isn't found in the chapter
    /// (caller should treat this as a soft failure: the chapter
    /// doesn't contain that page anchor, skip it).
    public static func replaceBody(
        of anchorId: String,
        in chapterText: String,
        with newXHTML: String
    ) -> String? {
        // Locate the anchor's opening `<span ... id="anchorId" ...>`
        // tag. We accept either quoting style — the converter emits
        // double quotes, but user edits or external tools might
        // use single quotes.
        let needles = ["id=\"\(anchorId)\"", "id='\(anchorId)'"]
        var anchorOpenIdx: String.Index?
        for needle in needles {
            if let r = chapterText.range(of: needle) {
                anchorOpenIdx = r.lowerBound
                break
            }
        }
        guard let anchorOpenIdx else { return nil }

        // Find the closing `>` of the anchor's opening tag — that's
        // where the page body begins.
        guard let openTagClose = chapterText.range(
            of: ">", range: anchorOpenIdx..<chapterText.endIndex
        ) else { return nil }
        let bodyStart = openTagClose.upperBound

        // Find the next page anchor (any id matching `hu-page-N`)
        // after bodyStart. That's where this page's body ends.
        let bodyEnd: String.Index
        if let nextAnchor = nextHuPageAnchor(after: bodyStart, in: chapterText) {
            bodyEnd = nextAnchor
        } else if let bodyClose = chapterText.range(
            of: "</body>", options: [.caseInsensitive, .backwards]
        ) {
            bodyEnd = bodyClose.lowerBound
        } else {
            bodyEnd = chapterText.endIndex
        }

        // Pad with newlines so the splice sits cleanly between the
        // anchor span and whatever came after.
        let trimmed = newXHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        let spliced = "\n\(trimmed)\n"
        var result = chapterText
        result.replaceSubrange(bodyStart..<bodyEnd, with: spliced)
        return result
    }

    /// Find the start index of the next `<span … id="hu-page-N">`
    /// element after `idx`. Returns nil when no further page
    /// anchor exists (typical for the final page in a chapter).
    private static func nextHuPageAnchor(
        after idx: String.Index, in text: String
    ) -> String.Index? {
        var search = idx
        while search < text.endIndex {
            guard let openTag = text.range(
                of: "<span", options: .caseInsensitive,
                range: search..<text.endIndex
            ) else { return nil }
            guard let closeTag = text.range(
                of: ">", range: openTag.upperBound..<text.endIndex
            ) else { return nil }
            let tagBody = text[openTag.upperBound..<closeTag.lowerBound]
            if tagBody.range(
                of: #"id=["']hu-page-\d+["']"#,
                options: .regularExpression
            ) != nil {
                return openTag.lowerBound
            }
            search = closeTag.upperBound
        }
        return nil
    }
}
