import Foundation
import EPUB

/// R-EPUB-Import: walk an XHTML resource's `<p>` opening tags and
/// inject `id="hu-p-{chapter}-{para}"` on elements that don't already
/// have an `id` attribute.
///
/// The conversion path (`XHTMLWriter`) emits these anchors as it
/// renders chapters from a `Chapter` IR. Imported EPUBs skip the IR
/// entirely — they arrive as XHTML — so this helper does the same
/// thing at the source level. Citation chips, paragraph-precision
/// PDF-to-source sync, and the editor's `requestParagraphScroll`
/// path all target `<p id="hu-p-N-M">`, so an imported EPUB without
/// these anchors silently degrades all three.
///
/// Idempotent on re-import: any `<p>` that already has an `id`
/// attribute (Humanist's or anyone else's) is left untouched. A book
/// converted once and re-imported is a no-op, and a mixed book
/// (some paragraphs already anchored, others not) gets anchors
/// added only where they're missing.
///
/// Per-chapter paragraph counter increments on every `<p>` we
/// encounter (even ones we skip because they already have an `id`),
/// so the visible numbering reflects document order rather than the
/// arbitrary "first untagged paragraph in chapter" ordering. Same
/// shape as the conversion path's `paraIdx`.
public enum ParagraphAnchorInjector {

    /// One chapter's transform result.
    public struct ChapterResult: Sendable, Equatable {
        public let xhtml: String
        public let paragraphsScanned: Int
        public let anchorsAdded: Int
    }

    /// Walk every spine resource of `book`, inject anchors where
    /// missing, and write the updated XHTML back into the resource
    /// (which marks it dirty for the next `EPUBBookSaver.save`).
    /// Returns total counts so callers can surface "added N anchors
    /// across M chapters" feedback.
    @discardableResult
    public static func injectAnchors(in book: EPUBBook) -> Summary {
        var totalScanned = 0
        var totalAdded = 0
        var chaptersTouched = 0
        for (chapterIdx, resourceID) in book.spine.enumerated() {
            guard let resource = book.resourcesByID[resourceID],
                  resource.isText,
                  let xhtml = resource.text else { continue }
            let result = inject(xhtml: xhtml, chapterIndex: chapterIdx)
            totalScanned += result.paragraphsScanned
            totalAdded += result.anchorsAdded
            if result.anchorsAdded > 0 {
                resource.text = result.xhtml
                chaptersTouched += 1
            }
        }
        return Summary(
            paragraphsScanned: totalScanned,
            anchorsAdded: totalAdded,
            chaptersTouched: chaptersTouched
        )
    }

    /// Inject `id="hu-p-{chapterIndex}-{paraIdx}"` on `<p>` opening
    /// tags inside `xhtml` that don't already declare an `id`.
    /// Returns the rewritten XHTML and counters.
    public static func inject(
        xhtml: String, chapterIndex: Int
    ) -> ChapterResult {
        // Opening `<p` tag with the optional rest of attributes
        // captured up through the `>`. Self-closing `<p/>` is
        // exceedingly rare in EPUBs but we'd skip them anyway —
        // there's no body to anchor to.
        //
        // `<p\\b` rather than `<p[ />]` so `<para>` etc. don't
        // match. `[^>]*` captures the attribute payload without
        // crossing into the next tag.
        let pattern = "<p\\b([^>]*)>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else {
            return ChapterResult(
                xhtml: xhtml, paragraphsScanned: 0, anchorsAdded: 0
            )
        }
        let nsText = xhtml as NSString
        let matches = regex.matches(
            in: xhtml,
            range: NSRange(location: 0, length: nsText.length)
        )
        // Walk matches in document order; rewrite in reverse so
        // index shifts from earlier injections don't invalidate
        // later ones.
        var paraIdx = 0
        var injectionPlan: [(matchRange: NSRange, paraIdx: Int)] = []
        for match in matches {
            let attrRange = match.range(at: 1)
            let attrs = attrRange.location == NSNotFound
                ? ""
                : nsText.substring(with: attrRange)
            if !Self.hasIDAttribute(attrs) {
                injectionPlan.append((match.range, paraIdx))
            }
            paraIdx += 1
        }
        var rewritten = nsText
        for (matchRange, idx) in injectionPlan.reversed() {
            let attrRange = NSRange(
                location: matchRange.location + 2,  // skip `<p`
                length: matchRange.length - 3       // drop `<p` and `>`
            )
            let existingAttrs = rewritten
                .substring(with: attrRange)
            let id = "hu-p-\(chapterIndex)-\(idx)"
            // Preserve any existing leading whitespace; the
            // conversion path emits `<p id="...">` with no other
            // attributes, but real-world EPUBs carry class /
            // lang / role etc.
            let rebuilt = "<p id=\"\(id)\"\(existingAttrs)>"
            rewritten = rewritten
                .replacingCharacters(in: matchRange, with: rebuilt) as NSString
        }
        return ChapterResult(
            xhtml: rewritten as String,
            paragraphsScanned: paraIdx,
            anchorsAdded: injectionPlan.count
        )
    }

    /// Tolerant `id=` detection — accepts the attribute name with
    /// any surrounding whitespace, single or double quotes, and
    /// arbitrary value. Rejects `xml:id`, `aria-labelledby`, etc.,
    /// by anchoring on a word boundary before `id`.
    private static func hasIDAttribute(_ attrs: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: "(^|\\s)id\\s*=",
            options: [.caseInsensitive]
        ) else { return false }
        let ns = attrs as NSString
        return regex.firstMatch(
            in: attrs,
            range: NSRange(location: 0, length: ns.length)
        ) != nil
    }

    public struct Summary: Sendable, Equatable {
        public let paragraphsScanned: Int
        public let anchorsAdded: Int
        public let chaptersTouched: Int
    }
}
