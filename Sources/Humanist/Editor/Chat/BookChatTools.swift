import Foundation
import AI
import LibraryIndexing

/// Tool surface advertised to the model for per-book chat (the
/// `.currentBook` scope). Distinct from `LibraryChatTools`:
///
///   * No `TurnBookRegistry` — there's exactly one book in scope,
///     so citations are `[chapter:N para:M]` rather than
///     `[book:N chapter:M para:M]`.
///   * Tools are book-shaped: search WITHIN the open book,
///     expand a single chapter to full text, list the chapter
///     titles. No cross-book operations.
///
/// Why per-book tools: per-book chat was single-shot until now —
/// initial cosine + BM25 + entity fusion ran once, and if the
/// slice didn't cover the question, the model had no escape
/// hatch. With these tools the model can re-search with a
/// rephrased query, expand a chapter the initial slice clipped
/// off, or pull the TOC to orient when the user asks a structural
/// question.
enum BookChatTools {

    // MARK: - Tool args

    /// `search_book` re-runs the same hybrid retriever the initial
    /// pass used, with a new query. `top_k` defaults to the VM's
    /// `maxRetrievedParagraphs` when omitted.
    struct SearchBookArgs: Decodable {
        let query: String
        let topK: Int?

        private enum CodingKeys: String, CodingKey {
            case query
            case topK = "top_k"
        }
    }

    /// `expand_chapter` returns the full text of one chapter.
    /// Useful when the initial retrieval surfaced a paragraph from
    /// a chapter and the model wants surrounding context, or when
    /// the user explicitly asks about a chapter ("what's in
    /// chapter 3?").
    struct ExpandChapterArgs: Decodable {
        let chapter: Int

        private enum CodingKeys: String, CodingKey {
            case chapter
        }
    }

    /// `list_chapter_titles` takes no args — JSON Schema is the
    /// empty-properties object. Decode tolerates any inbound
    /// payload (most models pass `{}`; some pass nothing).
    struct ListChapterTitlesArgs: Decodable {}

    // MARK: - Tool descriptors

    /// `search_book` re-runs the per-book hybrid retriever (cosine
    /// + BM25 + entity fusion) on a new query. Same dispatcher
    /// shape as library-scope's `search_library` but bounded to
    /// the open book. Cache-controlled so the tools-block prefix
    /// is cached alongside the system prompt across the multi-
    /// turn session.
    static let searchBookTool: Tool = {
        let schemaJSON = """
        {
          "type": "object",
          "properties": {
            "query": {
              "type": "string",
              "description": "Natural-language search query inside the open book. Cosine + BM25 + named-entity fusion — author names, work titles, characters, concepts all work."
            },
            "top_k": {
              "type": "integer",
              "description": "Number of paragraph hits to return. Defaults to 12; bump up to 24 for broader sweeps."
            }
          },
          "required": ["query"]
        }
        """
        return Tool(
            name: "search_book",
            description: """
                Search the open book for paragraphs relevant to a query. \
                Returns matching paragraphs with [chapter:N para:M] \
                citations. Call this when:

                  • the initial paragraphs don't cover the question
                  • you want to broaden via a rephrased query
                  • a follow-up turn pivots topics within the same book

                Bounded to THIS book — to ask about other books, the \
                user needs to be on library chat.
                """,
            inputSchema: Data(schemaJSON.utf8),
            cacheControl: CacheControl(type: .ephemeral)
        )
    }()

    /// `expand_chapter` returns one chapter's full text. The
    /// length cap is applied at render time so the model can ask
    /// for any chapter without worrying about context budget — the
    /// renderer truncates and tells the model what was clipped.
    static let expandChapterTool: Tool = {
        let schemaJSON = """
        {
          "type": "object",
          "properties": {
            "chapter": {
              "type": "integer",
              "description": "1-based chapter number as the user thinks of it. Chapter 1 is the first chapter of the book; numbering matches what list_chapter_titles returns."
            }
          },
          "required": ["chapter"]
        }
        """
        return Tool(
            name: "expand_chapter",
            description: """
                Return the full text of one chapter in the open book. \
                Use this when the initial retrieval surfaced a \
                paragraph from a chapter and you need surrounding \
                context, when the user explicitly asks about a \
                chapter, or when a search_book hit looks promising \
                but clipped. Long chapters get truncated at the \
                renderer's character limit — the result will tell \
                you when truncation happened.
                """,
            inputSchema: Data(schemaJSON.utf8),
            cacheControl: CacheControl(type: .ephemeral)
        )
    }()

    /// `list_chapter_titles` returns the table of contents — useful
    /// for orienting when the user asks structural questions ("how
    /// is this book organized?", "what's in chapter 3?") or when
    /// the model needs to pick a chapter index for `expand_chapter`
    /// from a vague reference.
    static let listChapterTitlesTool: Tool = {
        let schemaJSON = """
        {
          "type": "object",
          "properties": {}
        }
        """
        return Tool(
            name: "list_chapter_titles",
            description: """
                Return the book's table of contents — every chapter \
                title with its 1-based number. Useful when the user \
                asks about structure, or when you need to map a \
                vague chapter reference ("the introduction", \
                "the discipline chapter") to a numbered chapter for \
                expand_chapter.
                """,
            inputSchema: Data(schemaJSON.utf8),
            cacheControl: CacheControl(type: .ephemeral)
        )
    }()

    // MARK: - Renderers

    /// Render `search_book` tool result as the model-readable text
    /// body. Mirrors `LibraryChatTools.renderToolResult` shape but
    /// without the master `[book:N]` index — citations are
    /// `[chapter:M para:K]`. Empty result hands back a no-match
    /// message that explicitly suggests the next tool to try.
    static func renderSearchBookResult(
        query: String,
        hits: [HybridRetrieverHitLike],
        maxParaChars: Int
    ) -> String {
        guard !hits.isEmpty else {
            return """
            search_book("\(query)") returned no matching paragraphs. \
            Try a rephrased query, or call list_chapter_titles to \
            find a chapter to expand directly.
            """
        }
        var lines: [String] = []
        for hit in hits {
            let text = hit.text.prefix(maxParaChars)
            lines.append(
                "[chapter:\(hit.chapterIdx) para:\(hit.paragraphIdx)]\n  • \(text)"
            )
        }
        var out = "search_book(\"\(query)\") found \(hits.count) paragraphs.\n\n"
        out += "Relevant paragraphs:\n"
        out += lines.joined(separator: "\n")
        return out
    }

    /// Render `expand_chapter` result. `chapterIdx` here is 0-based
    /// (the internal spine index); the user-facing number in
    /// citations is `chapterIdx + 1`. `truncated` is true when the
    /// renderer hit the char cap — the model needs to know so it
    /// can ask for surrounding chapters or quote what it has.
    static func renderExpandChapterResult(
        chapterIdx: Int,
        title: String,
        text: String,
        truncated: Bool
    ) -> String {
        let header = "[chapter:\(chapterIdx)] \(title)"
        var out = "expand_chapter(\(chapterIdx + 1)) returned:\n\n"
        out += header + "\n\n" + text
        if truncated {
            out += "\n\n(Chapter text truncated at the renderer's limit. " +
                "Quote selectively rather than restating the entire chapter.)"
        }
        return out
    }

    /// Render `list_chapter_titles` result as a numbered list. Uses
    /// the hierarchy index for proper TOC ordering; falls back to a
    /// generic "Chapter N" label when a node has no title.
    static func renderListChapterTitlesResult(
        hierarchy: BookHierarchyIndex?,
        chapterCount: Int
    ) -> String {
        guard let hierarchy, !hierarchy.nodes.isEmpty else {
            // No nav — fall back to "Chapter 1..N" placeholders.
            // Still useful so the model knows the count.
            var out = "list_chapter_titles returned \(chapterCount) chapters (no titles available in the book's nav).\n"
            for i in 0..<chapterCount {
                out += "  \(i + 1). Chapter \(i + 1)\n"
            }
            return out
        }
        var out = "list_chapter_titles returned the book's table of contents:\n"
        // Walk top-level nodes only; nested sections would clutter
        // the model's view without changing the addressable chapter
        // index. Sub-sections still surface via expand_chapter on
        // the parent chapter.
        for node in hierarchy.nodes {
            let displayNumber = node.chapterIdx >= 0
                ? "\(node.chapterIdx + 1)."
                : "—"
            out += "  \(displayNumber) \(node.title)\n"
        }
        return out
    }

    // MARK: - Hit shim

    /// Bridge type so `renderSearchBookResult` doesn't need to
    /// import `HybridRetriever` (which lives in Humanist) into a
    /// rendering helper. Caller projects each `HybridRetriever.Hit`
    /// onto this shape; the renderer stays purely about formatting.
    struct HybridRetrieverHitLike: Sendable {
        let chapterIdx: Int
        let paragraphIdx: Int
        let text: String
    }
}
