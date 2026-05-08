import Foundation
import AI
import EPUB

/// Per-EPUB chat session: tracks message history, runs queries
/// through the keyword index, and asks Sonnet to answer using the
/// retrieved chapter texts. Lives on the `EditorViewModel` and is
/// recreated when a different EPUB is opened.
@MainActor
final class BookChatViewModel: ObservableObject {
    /// Replayable transcript. The user-facing pane renders this
    /// straight; assistant messages may carry citations parsed
    /// out of `[chapter:N]` markers in the model's response.
    @Published private(set) var messages: [BookChatMessage] = []
    @Published var input: String = ""
    @Published private(set) var isThinking: Bool = false
    /// Surfaces transient failures (no API key, network error,
    /// content-filter refusal, etc.) so the pane can show a banner.
    @Published var errorMessage: String?

    /// Shared keyword index. Built lazily on first send so opening
    /// the editor stays cheap even on large books.
    private var index: BookKeywordIndex?
    private(set) var book: EPUBBook
    private let bookTitle: String
    private let client: AnthropicAPIClient
    private let model: AnthropicModel
    private static let maxRetrievedChapters = 4
    private static let maxChapterChars = 8_000

    init(book: EPUBBook) {
        self.book = book
        self.bookTitle = book.metadata.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? book.sourceURL
            .deletingPathExtension()
            .lastPathComponent
        let keyStore = AnthropicAPIKeyStore()
        self.client = AnthropicAPIClient(
            apiKeyProvider: { keyStore.read() }
        )
        self.model = .sonnet4_6
    }

    /// Submit `input` as the next user turn. No-op on empty / while
    /// already thinking. Builds the index if needed, runs retrieval,
    /// fires the request, appends both the user and assistant
    /// messages on completion.
    func send() async {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isThinking else { return }
        input = ""
        errorMessage = nil
        let userMessage = BookChatMessage(role: .user, text: query)
        messages.append(userMessage)
        isThinking = true
        defer { isThinking = false }

        if index == nil {
            index = buildIndex()
        }
        let hits = index?.search(query: query, topK: Self.maxRetrievedChapters) ?? []
        let context = renderContext(hits: hits)

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: 1500,
            system: .cached(systemPrompt, ttl: .oneHour),
            messages: [
                Message(role: .user, content: .plain(
                    context + "\n\nQuestion: " + query
                ))
            ],
            thinking: .disabled
        )
        do {
            let response = try await client.send(request)
            let raw = response.firstText() ?? ""
            let cited = parseCitations(in: raw, allowedHits: hits)
            messages.append(BookChatMessage(
                role: .assistant,
                text: cited.cleaned,
                citations: cited.citations
            ))
        } catch let error as AnthropicAPIError {
            messages.append(BookChatMessage(
                role: .assistant,
                text: "Couldn't answer that — \(error.localizedDescription)."
            ))
        } catch {
            messages.append(BookChatMessage(
                role: .assistant,
                text: "Couldn't answer that — \(error.localizedDescription)."
            ))
        }
    }

    /// Wipe the transcript. Doesn't touch the keyword index — the
    /// index is per-book, not per-session.
    func clear() {
        messages.removeAll()
        errorMessage = nil
    }

    /// Called by the editor when the book reloads from disk (after
    /// a save, after Bulk Re-OCR, etc.). Drop the keyword index
    /// so the next query rebuilds against the freshest text;
    /// keep the transcript so the user doesn't lose context.
    func bookDidReload(_ updated: EPUBBook) {
        self.book = updated
        self.index = nil
    }

    // MARK: - retrieval

    private func buildIndex() -> BookKeywordIndex {
        let chapters: [BookKeywordIndex.Chapter] = book.spine.compactMap { id in
            guard let resource = book.resourcesByID[id],
                  let xhtml = resource.text else { return nil }
            return BookKeywordIndex.Chapter(
                id: id,
                title: chapterTitle(from: xhtml),
                text: stripTags(xhtml)
            )
        }
        return BookKeywordIndex(chapters: chapters)
    }

    private func renderContext(hits: [BookKeywordIndex.Hit]) -> String {
        guard !hits.isEmpty else {
            return """
            (No chapters in this book scored above zero on a keyword \
            match for the question. Answer from the chapter list \
            alone if possible; otherwise say you can't find a match.)
            """
        }
        var out = "Available chapters from \"\(bookTitle)\":\n\n"
        for hit in hits {
            let body = hit.chapter.text
                .prefix(Self.maxChapterChars)
            let title = hit.chapter.title?.nonEmpty
                ?? "Chapter \(hit.chapterIndex + 1)"
            out += "[chapter:\(hit.chapterIndex)] \(title)\n"
            out += String(body)
            out += "\n\n---\n\n"
        }
        return out
    }

    // MARK: - chapter parsing

    /// Pull the chapter title from the first `<h1>` / `<h2>` / `<title>`
    /// in the XHTML. Falls back to nil; the renderer substitutes
    /// "Chapter N" in that case.
    private func chapterTitle(from xhtml: String) -> String? {
        for tag in ["h1", "h2", "title"] {
            if let range = xhtml.range(
                of: "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>",
                options: .regularExpression
            ) {
                let chunk = String(xhtml[range])
                let inner = chunk
                    .replacingOccurrences(
                        of: "<[^>]+>",
                        with: "",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { return inner }
            }
        }
        return nil
    }

    /// Strip every HTML/XHTML tag and decode the small set of named
    /// entities (`&amp;` / `&lt;` / `&gt;` / `&quot;` / `&apos;`)
    /// — same posture as the existing PlainTextWriter for the
    /// sibling `.txt` output. Numeric refs (`&#160;` etc.) pass
    /// through unchanged; the model sees the raw codepoint as a
    /// plain space at most, which is fine.
    private func stripTags(_ xhtml: String) -> String {
        var s = xhtml.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression
        )
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&nbsp;": " ",
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - citation extraction

    private struct CitationParse {
        let cleaned: String
        let citations: [BookChatCitation]
    }

    /// Extract `[chapter:N]` markers from the model's reply. Replace
    /// each occurrence with a tagged span so the renderer can
    /// produce a clickable button; collect the unique
    /// `(chapterIndex, title)` pairs as `BookChatCitation` values
    /// for the message footer.
    private func parseCitations(
        in text: String, allowedHits: [BookKeywordIndex.Hit]
    ) -> CitationParse {
        let allowedIndices = Set(allowedHits.map(\.chapterIndex))
        var seen: [Int: BookChatCitation] = [:]
        let pattern = "\\[chapter:(\\d+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return CitationParse(cleaned: text, citations: [])
        }
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        var cleaned = text
        for match in matches.reversed() {
            guard match.numberOfRanges == 2 else { continue }
            let raw = nsText.substring(with: match.range(at: 1))
            guard let idx = Int(raw),
                  allowedIndices.contains(idx),
                  let resource = chapterResource(for: idx)
            else {
                // Drop the marker even if it's bogus — keeps the
                // visible text clean.
                let nsRange = match.range(at: 0)
                if let r = Range(nsRange, in: cleaned) {
                    cleaned.removeSubrange(r)
                }
                continue
            }
            let title = chapterTitleFromHits(idx, hits: allowedHits)
            seen[idx] = BookChatCitation(
                chapterIndex: idx,
                title: title ?? "Chapter \(idx + 1)",
                resourceID: resource.id
            )
            // Replace the inline marker with a parenthesized
            // shorthand so the prose still reads — the citation
            // chip below the message carries the click target.
            let nsRange = match.range(at: 0)
            if let r = Range(nsRange, in: cleaned) {
                cleaned.replaceSubrange(r, with: "(see \(title ?? "Chapter \(idx + 1)"))")
            }
        }
        let citations = Array(seen.values)
            .sorted { $0.chapterIndex < $1.chapterIndex }
        return CitationParse(cleaned: cleaned, citations: citations)
    }

    private func chapterResource(for index: Int) -> Resource? {
        guard index >= 0, index < book.spine.count else { return nil }
        return book.resourcesByID[book.spine[index]]
    }

    private func chapterTitleFromHits(
        _ idx: Int, hits: [BookKeywordIndex.Hit]
    ) -> String? {
        hits.first(where: { $0.chapterIndex == idx })?.chapter.title?.nonEmpty
    }

    // MARK: - prompt

    private var systemPrompt: String {
        """
        You are a research assistant embedded in an EPUB editor. \
        The user has opened "\(bookTitle)" and is asking questions \
        about its contents.

        For each question, you'll receive a small set of chapters \
        retrieved from the book (the highest-scoring on a keyword \
        match for the question). Answer the question using only \
        the supplied chapter text.

        When you reference a specific chapter in your answer, mark \
        the reference inline as `[chapter:N]` where N is the index \
        from the supplied chapter headers. The user's interface \
        renders these markers as clickable links to the chapter.

        If the supplied chapters don't contain enough information to \
        answer, say so plainly — don't guess. Quote brief passages \
        when they directly support the answer; cite their chapter \
        with `[chapter:N]`.

        Keep replies tight: a short paragraph or two is plenty for \
        most questions. The user is reading the answer in a sidebar \
        pane, not a full window.
        """
    }
}

// MARK: - Helpers

private extension AnthropicMessageResponse {
    /// Concatenate every text block in the first content piece. The
    /// chat path expects plain prose; multi-block tool-use responses
    /// don't apply.
    func firstText() -> String? {
        for block in content {
            if case .text(let str) = block { return str }
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
