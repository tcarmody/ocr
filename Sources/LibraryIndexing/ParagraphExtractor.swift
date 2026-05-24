import Foundation
import CryptoKit
import EPUB

/// Pulls paragraph-level chunks out of an EPUB's spine. Each chunk is
/// the visible text inside one `<p>`, `<h1>`–`<h6>`, `<blockquote>`,
/// or `<li>` element, with inner tags stripped and a small named-
/// entity decode applied (same posture as `BookChatViewModel.stripTags`).
///
/// Whitespace-only or single-character chunks are dropped — they don't
/// carry retrieval signal and they'd inflate the index. Long chunks
/// (>3000 chars) are kept whole; sentence-level chunking is a future
/// optimization that mostly helps on textbook-style content.
///
/// Lives in `LibraryIndexing` (split out of `BookEmbeddingIndex`) so
/// both the Humanist app and `humanist-cli` can drive the same
/// paragraph-extraction pass without the latter pulling in the rest
/// of the chat view-model surface.
public enum ParagraphExtractor {
    public struct Item: Sendable {
        public let chapterIdx: Int
        public let paragraphIdx: Int
        public let text: String
        public let textHash: String

        public init(
            chapterIdx: Int,
            paragraphIdx: Int,
            text: String,
            textHash: String
        ) {
            self.chapterIdx = chapterIdx
            self.paragraphIdx = paragraphIdx
            self.text = text
            self.textHash = textHash
        }
    }

    /// Walk the book's spine and emit one Item per paragraph-level
    /// element in source order. `chapterIdx` is the spine position;
    /// `paragraphIdx` increments per item within the chapter.
    public static func extract(from book: EPUBBook) -> [Item] {
        var out: [Item] = []
        for (chapterIdx, resourceID) in book.spine.enumerated() {
            guard let resource = book.resourcesByID[resourceID],
                  let xhtml = resource.text else { continue }
            let chunks = paragraphs(in: xhtml)
            for (paragraphIdx, text) in chunks.enumerated() {
                out.append(Item(
                    chapterIdx: chapterIdx,
                    paragraphIdx: paragraphIdx,
                    text: text,
                    textHash: hash(text)
                ))
            }
        }
        return out
    }

    /// Plain-text paragraphs from one chapter's XHTML, in source
    /// order. Visible for unit tests.
    public static func paragraphs(in xhtml: String) -> [String] {
        // Match every paragraph-bearing element. `[\\s\\S]*?` is the
        // non-greedy any-char (including newlines) match; Swift's
        // NSRegularExpression doesn't accept the inline `s` flag,
        // so the explicit char class stands in.
        let pattern = "<(p|h[1-6]|blockquote|li)\\b[^>]*>([\\s\\S]*?)</\\1>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return [] }
        let nsText = xhtml as NSString
        var out: [String] = []
        let matches = regex.matches(
            in: xhtml,
            range: NSRange(location: 0, length: nsText.length)
        )
        for match in matches {
            guard match.numberOfRanges == 3 else { continue }
            let inner = nsText.substring(with: match.range(at: 2))
            let stripped = stripInnerTags(inner)
            // Skip empty / single-glyph chunks. They're chapter
            // separators or ornaments, not retrieval-worthy text.
            if stripped.count >= 2 {
                out.append(stripped)
            }
        }
        return out
    }

    /// Strip every nested tag from a paragraph's inner XHTML and
    /// decode the small set of named entities the chat path already
    /// handles. Numeric refs pass through; the embedder treats them
    /// as opaque tokens.
    ///
    /// Tags get replaced with a space (not empty) so that adjacent
    /// inline tags don't fuse the words on either side
    /// (`a<em>b</em>c` shouldn't read as `abc`). The post-pass
    /// collapses whitespace runs and tightens spaces before
    /// punctuation that the tag substitution may have introduced
    /// (`link ./` → `link.` after closing-tag-followed-by-period).
    private static func stripInnerTags(_ inner: String) -> String {
        var s = inner.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression
        )
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&nbsp;": " ",
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }
        s = s.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: " ([.,;:!?])", with: "$1", options: .regularExpression
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SHA-256 hex of the paragraph text. Used to invalidate stale
    /// vectors when a paragraph is edited — the textHash diverges
    /// from what's in the sidecar and the build() pass re-embeds it.
    public static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
