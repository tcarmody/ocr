import Foundation
import Document
import EPUB

/// Build a list of `Chapter` values suitable for feeding to
/// `BookCoherenceAnalyzer` (Cloud or AFM) from an in-memory
/// `EPUBBook` — without a full XHTML → Chapter parser.
///
/// The analyzer's `buildDigest` only consumes chapter titles and
/// the first ~200 chars of each chapter's body. The applier filters
/// suggestions through a docText built from every text-bearing run.
/// Both consumers want plain text by chapter — no figure / table /
/// anchor fidelity needed. We can therefore lift the same regex
/// extraction pattern already used by `EPUBImporter.buildMinimalChapter`
/// for the chapter classifier, raise the body-char cap, and capture
/// enough headings + paragraphs to feed both digest and docText
/// without round-tripping through `Chapter` IR.
///
/// Used only by the import-time coherence path. The PDF conversion
/// pipeline keeps using `Chapter` directly since it builds the IR
/// from scratch.
public enum CoherenceDigestSampler {

    /// Default body-char cap per chapter when sampling for digest +
    /// docText together. Higher than the classifier's 800-char cap
    /// because the docText guardrails (`shouldApply`) count
    /// `wrong`-string occurrences against the assembled text — too
    /// little text per chapter and the occurrence floor (`≥ 3`)
    /// never triggers on legitimate recurring errors.
    public static let defaultBodyCharCap = 2_000

    /// Walk every spine resource and build a digest-suitable
    /// `Chapter`. Returns chapters in spine order. Empty when no
    /// spine resource yields text — caller should skip the
    /// coherence pass in that case.
    ///
    /// Each returned chapter carries:
    ///   * `title` — first `<h1>` / `<title>` content (same
    ///     extractor the classifier uses).
    ///   * `blocks` — a sequence of `.heading` / `.paragraph` runs
    ///     mirroring the source's reading order, with text content
    ///     stripped of inline tags. Capped at `bodyCharCap` chars
    ///     of body text per chapter so a 200-chapter book stays
    ///     well under the analyzer's 8 KB digest budget.
    public static func sampleChapters(
        from book: EPUBBook,
        bodyCharCap: Int = defaultBodyCharCap
    ) -> [Chapter] {
        var chapters: [Chapter] = []
        for resourceID in book.spine {
            guard let resource = book.resourcesByID[resourceID],
                  resource.isText,
                  let xhtml = resource.text
            else { continue }
            let chapter = sampleChapter(
                from: xhtml, bodyCharCap: bodyCharCap
            )
            // Drop chapters with no extractable text — they contribute
            // nothing to digest or docText and just clutter the array.
            if chapter.title == nil && chapter.blocks.isEmpty {
                continue
            }
            chapters.append(chapter)
        }
        return chapters
    }

    /// Sample one XHTML resource into a digest-suitable `Chapter`.
    /// Public for tests; production callers go through
    /// `sampleChapters(from:bodyCharCap:)`.
    public static func sampleChapter(
        from xhtml: String,
        bodyCharCap: Int = defaultBodyCharCap
    ) -> Chapter {
        let title = extractFirstTitle(from: xhtml)
        let blocks = extractBlocks(from: xhtml, maxChars: bodyCharCap)
        return Chapter(title: title, blocks: blocks)
    }

    // MARK: - regex extraction

    /// First `<h1>...</h1>` content (stripped of inline tags), or
    /// the `<title>...</title>` tag's content as a fallback. Nil
    /// when neither is present or both are empty.
    static func extractFirstTitle(from xhtml: String) -> String? {
        for pattern in ["<h1\\b[^>]*>([\\s\\S]*?)</h1>",
                        "<title\\b[^>]*>([\\s\\S]*?)</title>"] {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else { continue }
            let ns = xhtml as NSString
            guard let match = regex.firstMatch(
                in: xhtml,
                range: NSRange(location: 0, length: ns.length)
            ), match.numberOfRanges == 2 else { continue }
            let inner = ns.substring(with: match.range(at: 1))
            let plain = stripXHTML(inner)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty { return plain }
        }
        return nil
    }

    /// Extract `.heading` and `.paragraph` blocks in document order
    /// until the accumulated body text hits `maxChars`. Inline tags
    /// are stripped — runs carry plain `text` only since the
    /// coherence pass operates on text content. Headings preserve
    /// their level (1-6).
    static func extractBlocks(
        from xhtml: String, maxChars: Int
    ) -> [Block] {
        let pattern = "<(h[1-6]|p|blockquote|li)\\b[^>]*>([\\s\\S]*?)</\\1>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return [] }
        let ns = xhtml as NSString
        let matches = regex.matches(
            in: xhtml,
            range: NSRange(location: 0, length: ns.length)
        )
        var blocks: [Block] = []
        var bodyChars = 0
        for match in matches {
            guard match.numberOfRanges == 3 else { continue }
            let tag = ns.substring(with: match.range(at: 1))
                .lowercased()
            let inner = ns.substring(with: match.range(at: 2))
            let plain = stripXHTML(inner)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.isEmpty { continue }
            let run = InlineRun(plain)
            if let level = headingLevel(for: tag) {
                blocks.append(.heading(level: level, runs: [run]))
            } else {
                blocks.append(.paragraph(runs: [run]))
            }
            bodyChars += plain.count
            if bodyChars >= maxChars { break }
        }
        return blocks
    }

    /// 1–6 for `<h1>` … `<h6>`; nil for paragraph-shaped tags
    /// (`<p>`, `<blockquote>`, `<li>`).
    private static func headingLevel(for tag: String) -> Int? {
        guard tag.count == 2, tag.hasPrefix("h"),
              let digit = Int(String(tag.last!)),
              (1...6).contains(digit)
        else { return nil }
        return digit
    }

    /// Strip XHTML tags and decode the handful of entities we care
    /// about so the resulting plain text is comparable across
    /// resources. Same minimal posture as
    /// `EPUBImporter.stripXHTML` — we don't need a full HTML parser
    /// because the coherence pass only looks for recurring
    /// substring patterns; whitespace collapse + tag removal is
    /// enough.
    static func stripXHTML(_ s: String) -> String {
        var result = s
        // Drop tags.
        if let regex = try? NSRegularExpression(
            pattern: "<[^>]+>", options: []
        ) {
            let ns = result as NSString
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: ""
            )
        }
        // Common entities only — anything exotic stays escaped,
        // which is harmless since the coherence pass compares
        // strings to themselves at apply-time.
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&nbsp;", " "),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(
                of: entity, with: replacement
            )
        }
        // Collapse runs of whitespace so newlines / tabs / multiple
        // spaces inside XHTML markup don't fragment substring
        // matching.
        if let regex = try? NSRegularExpression(
            pattern: "\\s+", options: []
        ) {
            let ns = result as NSString
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: " "
            )
        }
        return result
    }
}
