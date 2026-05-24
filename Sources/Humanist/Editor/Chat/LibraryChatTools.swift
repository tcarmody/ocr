import Foundation
import AI

/// Tool surface advertised to the model for library-scope chat,
/// plus the per-turn machinery that keeps `[book:N]` citation
/// indices consistent across multiple tool calls within a single
/// answer.
///
/// Why tool use: the rigid retrieve→answer pipeline was the
/// ceiling on hard questions. With `search_library` exposed as a
/// tool, the model can broaden / refine retrieval mid-answer
/// instead of being stuck with whatever the initial cosine pass
/// surfaced — query-rewriting, multi-hop questions, and "I need
/// more from author X" all fall out naturally.
enum LibraryChatTools {

    /// JSON arguments Claude emits for a `search_library` call.
    /// Decoded from the opaque bytes carried on `ResponseBlock
    /// .toolUse` so the dispatcher can call into the federated
    /// retriever with typed inputs.
    struct SearchLibraryArgs: Decodable {
        let query: String
        let topK: Int?

        private enum CodingKeys: String, CodingKey {
            case query
            case topK = "top_k"
        }
    }

    /// `search_library` tool descriptor. Schema is intentionally
    /// minimal — `query` + optional `top_k` — to keep the model's
    /// tool-use surface small and reliable. More dimensions (book
    /// restriction, author filter) can land as follow-up tools
    /// without touching this one. `cacheControl` is set so the
    /// tools-block prefix is cached alongside the system prompt
    /// across the multi-turn session.
    static let searchLibraryTool: Tool = {
        let schemaJSON = """
        {
          "type": "object",
          "properties": {
            "query": {
              "type": "string",
              "description": "Natural-language search query. The library is indexed via embeddings + per-book BM25 + named-entity boosts, so author names, work titles, and concept phrases all work."
            },
            "top_k": {
              "type": "integer",
              "description": "Number of paragraph hits to return. Defaults to 12; bump higher (up to 30) for broader sweeps, lower for tight follow-ups."
            }
          },
          "required": ["query"]
        }
        """
        return Tool(
            name: "search_library",
            description: """
                Search the user's library for paragraphs relevant to a query. \
                Returns a small set of paragraphs across books that match the \
                query, prefixed with their book metadata so you can cite them \
                with [book:N chapter:M para:K] markers. Call this when:

                  • the initial context doesn't seem to cover the question
                  • you want to broaden the search with a rephrased query
                  • you need additional perspectives from different books
                  • the user asks a follow-up that pivots topics

                Book indices in your response refer to the master Books-in-scope \
                list; each tool result extends that list with any new books found.
                """,
            inputSchema: Data(schemaJSON.utf8),
            cacheControl: CacheControl(type: .ephemeral)
        )
    }()

    /// Tracks the `[book:N]` index assigned to each EPUB URL across
    /// multiple tool calls within a single answer. Without this,
    /// each tool result would restart numbering at 0 and the model
    /// would lose track of which `[book:5]` from an earlier turn
    /// matches a follow-up search's results.
    ///
    /// Insertion-ordered: the first time a book appears (initial
    /// retrieval or any tool result), it gets the next available
    /// index. Subsequent appearances reuse it.
    final class TurnBookRegistry {
        private(set) var ordered: [(url: URL, title: String, author: String?)] = []
        private var indexByURL: [URL: Int] = [:]

        func index(
            for url: URL, title: String, author: String?
        ) -> Int {
            if let existing = indexByURL[url] { return existing }
            let idx = ordered.count
            indexByURL[url] = idx
            ordered.append((url, title, author))
            return idx
        }

        /// `[Int: (url, title)]` shape the citation parser expects.
        var bookByIndex: [Int: (url: URL, title: String)] {
            var out: [Int: (url: URL, title: String)] = [:]
            for (i, entry) in ordered.enumerated() {
                out[i] = (entry.url, entry.title)
            }
            return out
        }
    }

    /// Render hits as a tool_result body — the same shape the
    /// initial-context renderer uses, but only listing books that
    /// are NEW to this turn's registry (the model already saw the
    /// previously-listed ones). Returns a self-describing block
    /// the model can read and cite from on its next turn.
    static func renderToolResult(
        query: String,
        hits: [LibraryEmbeddingIndex.Hit],
        registry: TurnBookRegistry,
        maxParaChars: Int
    ) -> String {
        guard !hits.isEmpty else {
            return "search_library(\"\(query)\") returned no matching paragraphs."
        }
        var newBooks: [(idx: Int, title: String, author: String?)] = []
        var paragraphLines: [String] = []
        for hit in hits {
            let knownBefore = registry.bookByIndex.keys.contains { idx in
                registry.bookByIndex[idx]?.url == hit.epubURL
            }
            let idx = registry.index(
                for: hit.epubURL,
                title: hit.bookTitle,
                author: hit.bookAuthor
            )
            if !knownBefore {
                newBooks.append((idx, hit.bookTitle, hit.bookAuthor))
            }
            let text = (hit.text ?? "").prefix(maxParaChars)
            paragraphLines.append(
                "[book:\(idx) chapter:\(hit.chapterIdx) para:\(hit.paragraphIdx)]\n  • \(text)"
            )
        }
        var out = "search_library(\"\(query)\") found \(hits.count) paragraphs.\n\n"
        if !newBooks.isEmpty {
            out += "New books in this result (master indexing continues):\n"
            for book in newBooks {
                if let author = book.author, !author.isEmpty {
                    out += "[book:\(book.idx)] \"\(book.title)\" — \(author)\n"
                } else {
                    out += "[book:\(book.idx)] \"\(book.title)\"\n"
                }
            }
            out += "\n"
        }
        out += "Relevant paragraphs:\n"
        out += paragraphLines.joined(separator: "\n")
        return out
    }

    /// Render the initial-turn context using the registry so the
    /// indices match what subsequent tool-result renders will use.
    /// Replaces the standalone `renderLibraryContext` for the
    /// agentic path; the legacy path's renderer stays put for the
    /// per-book chat which doesn't (yet) have tool use.
    static func renderInitialContext(
        hits: [LibraryEmbeddingIndex.Hit],
        registry: TurnBookRegistry,
        maxParaChars: Int
    ) -> String {
        guard !hits.isEmpty else {
            return """
            (No matching paragraphs were found across the user's \
            library on the initial pass. Call `search_library` with a \
            rephrased query if you think material exists; otherwise \
            tell the user the corpus doesn't seem to cover this.)
            """
        }
        var paragraphLines: [String] = []
        for hit in hits {
            let idx = registry.index(
                for: hit.epubURL,
                title: hit.bookTitle,
                author: hit.bookAuthor
            )
            let text = (hit.text ?? "").prefix(maxParaChars)
            paragraphLines.append(
                "[book:\(idx) chapter:\(hit.chapterIdx) para:\(hit.paragraphIdx)]\n  • \(text)"
            )
        }
        var out = "Books in scope:\n"
        for (i, entry) in registry.ordered.enumerated() {
            if let author = entry.author, !author.isEmpty {
                out += "[book:\(i)] \"\(entry.title)\" — \(author)\n"
            } else {
                out += "[book:\(i)] \"\(entry.title)\"\n"
            }
        }
        out += "\nRelevant paragraphs:\n"
        out += paragraphLines.joined(separator: "\n")
        return out
    }
}
