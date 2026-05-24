import Foundation
import AI
import LibraryIndexing

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

    /// JSON arguments for `search_topic` — the R-Chat-Cross-Corpus
    /// Phase 3 tool. Looks up book-level coverage for a named topic
    /// (entity / person / place / theme) in the federated
    /// `LibraryConceptGraph` and surfaces ranked books with mention
    /// counts + chapter spans. Different shape from `search_library`:
    /// that's per-paragraph retrieval, this is per-book coverage.
    ///
    /// Wire field is `topic` to match the user-facing vocabulary;
    /// the underlying data structure is still
    /// `LibraryConceptGraph` (named-entity rollup, not LDA-style
    /// topic modeling).
    struct SearchTopicArgs: Decodable {
        let topic: String
        let bookLimit: Int?

        private enum CodingKeys: String, CodingKey {
            case topic
            case bookLimit = "book_limit"
        }
    }

    /// Tool descriptors are intentionally cache-control-FREE — the
    /// system prompt's 1h cache breakpoint covers everything up to
    /// (and including) the tools block, so adding per-tool
    /// breakpoints would (a) burn against Anthropic's 4-breakpoint
    /// limit per request and (b) create the TTL-ordering trap
    /// (tools default to 5m, system is 1h, ordering violation).
    /// One system-level breakpoint caches the whole tools+system
    /// prefix together — exactly what we want for a stable session.
    ///
    /// `search_topic` tool descriptor. Complements `search_library`:
    /// where that returns paragraph-level hits from cosine + BM25 +
    /// entity fusion, this returns **book-level coverage** for a
    /// named topic — useful when the user asks "which of my books
    /// most engage with X?" rather than "what does X mean?" The
    /// model can chain a follow-up `search_library` if it wants
    /// specific paragraphs from one of the surfaced books.
    static let searchTopicTool: Tool = {
        let schemaJSON = """
        {
          "type": "object",
          "properties": {
            "topic": {
              "type": "string",
              "description": "Topic, named entity, or theme to look up (e.g. 'Foucault', 'phenomenology', 'mirror stage', 'Plato'). Matched case-insensitively against the library's named-entity index, with built-in aliases collapsing synonyms (e.g. 'America' resolves to 'United States')."
            },
            "book_limit": {
              "type": "integer",
              "description": "Max books to return. Defaults to 8; raise to 20 for broader sweeps."
            }
          },
          "required": ["topic"]
        }
        """
        return Tool(
            name: "search_topic",
            description: """
                Look up a topic or named entity across the user's library \
                and return book-level coverage: which books mention this \
                topic, how many times, and which chapters. Each surfaced \
                book gets a [book:N] index that you can cite. Useful when:

                  • the user asks "which books in my library most engage with X?"
                  • you want a corpus-level view before zooming into paragraphs
                  • you're comparing how different books treat the same topic

                Returns: ranked book list + related topics (by co-occurrence). \
                For specific paragraph text from one of these books, follow up \
                with search_library using a query that includes the topic + \
                the book title.

                If the topic isn't in the entity index, the result will tell \
                you — try a synonym (the alias map handles common ones) or fall \
                back to search_library for free-text retrieval.
                """,
            inputSchema: Data(schemaJSON.utf8)
        )
    }()

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
            inputSchema: Data(schemaJSON.utf8)
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

    /// Render a `search_topic` tool result as the text body
    /// the model reads on its next turn. Resolves `topic`
    /// against the graph with an alias-aware fuzzy match (exact
    /// canonical → alias-canonicalized → displayName-contains),
    /// extends the registry with the surfaced books so their
    /// [book:N] indices stay stable across follow-up tool calls,
    /// and surfaces related topics so the model can pivot.
    static func renderTopicToolResult(
        topic: String,
        graph: LibraryConceptGraph,
        registry: TurnBookRegistry,
        bookLimit: Int = 8,
        authorLookup: (URL) -> String? = { _ in nil }
    ) -> String {
        let raw = topic
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = ConceptAliases.canonical(for: raw)

        // Resolution chain: exact canonical → alias-canonical →
        // displayName contains. The last is forgiving for the
        // common case where the model passes a display form like
        // "Foucault" that lowercases to a stored canonical, but
        // also catches partial matches like "phenomenolog" → the
        // "phenomenology" row.
        let stats: LibraryConceptGraph.ConceptStats?
        if let exact = graph.concepts[canonical] {
            stats = exact
        } else {
            stats = graph.conceptsByBreadth().first { row in
                row.displayName.lowercased() == raw
                    || row.displayName.lowercased().contains(raw)
            }
        }

        guard let stats else {
            return """
            search_topic("\(topic)") found no matching topic in the \
            library's entity index. Try a synonym (the alias map covers \
            common ones like america/united states) or fall back to \
            search_library for free-text retrieval.
            """
        }

        let limited = Array(stats.coverage.prefix(bookLimit))
        var newBooks: [(idx: Int, title: String, author: String?)] = []
        var bookLines: [String] = []
        for row in limited {
            let knownBefore = registry.bookByIndex.values.contains { existing in
                existing.url == row.epubURL
            }
            let author = authorLookup(row.epubURL)
            let idx = registry.index(
                for: row.epubURL,
                title: row.bookTitle,
                author: author
            )
            if !knownBefore {
                newBooks.append((idx, row.bookTitle, author))
            }
            let chapterList = row.chapters.sorted()
            let shownChapters = chapterList.prefix(8)
                .map(String.init)
                .joined(separator: ", ")
            let truncated = chapterList.count > 8 ? ", …" : ""
            bookLines.append(
                "[book:\(idx)] \(row.mentionCount) mentions in chapters \(shownChapters)\(truncated)"
            )
        }

        var out = "search_topic(\"\(stats.displayName)\") matched "
            + "\(stats.bookCount) book\(stats.bookCount == 1 ? "" : "s") "
            + "across the library, \(stats.totalMentions) total mentions.\n\n"

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

        out += "Top \(limited.count) book"
            + (limited.count == 1 ? "" : "s") + " by mention count:\n"
        out += bookLines.joined(separator: "\n")

        let related = graph.related(to: stats.canonical, limit: 6)
        if !related.isEmpty {
            out += "\n\nRelated topics (paragraphs where they co-occur with \(stats.displayName)):\n"
            for entry in related {
                let display = graph.concepts[entry.concept]?.displayName
                    ?? entry.concept
                out += "  • \(display) (\(entry.count))\n"
            }
        }

        return out
    }

    /// Render the initial-turn context using the registry so the
    /// indices match what subsequent tool-result renders will use.
    /// Replaces the standalone `renderLibraryContext` for the
    /// agentic path; the legacy path's renderer stays put for the
    /// per-book chat which doesn't (yet) have tool use.
    ///
    /// `overview` is an optional preamble describing the library at
    /// a glance (total books, top authors). Without it, the model
    /// reads the "Books surfaced in this initial pass" list as if
    /// it were the whole corpus — leading to "your library doesn't
    /// have X" answers when the cosine pass missed authors that ARE
    /// represented. The library-scope chat VMs build it from their
    /// `LibraryStore` and pass it through; per-book chat in
    /// library scope can do the same.
    static func renderInitialContext(
        hits: [LibraryEmbeddingIndex.Hit],
        registry: TurnBookRegistry,
        maxParaChars: Int,
        overview: LibraryOverview? = nil
    ) -> String {
        guard !hits.isEmpty else {
            var out = ""
            if let overview {
                out += overview.render() + "\n\n"
            }
            out += """
            (No matching paragraphs were found across the user's \
            library on the initial pass. Call `search_library` with a \
            rephrased query, or `search_topic` if the user named an \
            author / person / work, before concluding the corpus \
            doesn't cover this.)
            """
            return out
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
        var out = ""
        if let overview {
            out += overview.render() + "\n\n"
        }
        // Label deliberately calls out that this is an INITIAL
        // PASS, not the whole library. Without this, the model
        // treats the slice as the entire universe and won't
        // broaden via the tools.
        out += "Books surfaced in this initial pass (call search_library / search_topic to surface more):\n"
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

    /// Library-at-a-glance preamble that anchors the model in the
    /// real corpus shape rather than the narrow initial-retrieval
    /// slice. Built from the `LibraryStore.entries` snapshot — no
    /// dependence on the federated index, sidecars, or chat state,
    /// so it's instant to compute regardless of cache warmth.
    ///
    /// Reports total book count and the top-N authors by book
    /// count. The top-authors list tells the model "this library
    /// has 73 books by Foucault, 42 by Deleuze, 38 by Heidegger,
    /// …" so it won't claim there's only one or two when a
    /// well-represented author comes up.
    struct LibraryOverview: Sendable {
        let totalBooks: Int
        let topAuthors: [(name: String, bookCount: Int)]

        /// Default top-author cap. Larger than the typical chat
        /// retrieval surface (~6 books) so the model sees breadth;
        /// small enough that it doesn't dominate the prompt token
        /// budget. Caller can override.
        static let defaultTopAuthors: Int = 25

        static func build(
            from entries: [LibraryEntry],
            topAuthorLimit: Int = defaultTopAuthors
        ) -> LibraryOverview {
            var counts: [String: Int] = [:]
            for entry in entries {
                guard let raw = entry.author?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { continue }
                counts[raw, default: 0] += 1
            }
            let top = counts
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }
                .prefix(topAuthorLimit)
                .map { (name: $0.key, bookCount: $0.value) }
            return LibraryOverview(
                totalBooks: entries.count,
                topAuthors: Array(top)
            )
        }

        /// Render as the prompt-ready preamble. Short and dense —
        /// the model can parse this in O(visual scan) before
        /// dropping into the retrieval slice.
        func render() -> String {
            var out = "Library at a glance: \(totalBooks) books total.\n"
            if !topAuthors.isEmpty {
                out += "Top authors by book count: "
                out += topAuthors
                    .map { "\($0.name) (\($0.bookCount))" }
                    .joined(separator: "; ")
            }
            return out
        }
    }
}
