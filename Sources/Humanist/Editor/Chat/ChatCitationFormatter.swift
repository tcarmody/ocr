import Foundation

/// Turn chat citations into reference strings the user can drop
/// into research notes. Chicago note-style for v1 — the most
/// academic-relevant style for the user's actual workflow. MLA /
/// APA layer on later if needed.
///
/// Resolution path: chat citations carry `bookEpubURL` for
/// library-scope chats and chapter / paragraph indices for both
/// scopes. Library lookups against the live `LibraryStore` give
/// the entry's title + author. Year, publisher, and ISBN live in
/// the EPUB OPF rather than the catalog today, so v1 formats
/// what we have on `LibraryEntry` and falls through gracefully
/// when fields are missing. A future revision can enrich
/// `LibraryEntry` with the OPF year/publisher fields without
/// changing this formatter's surface.
struct ChatCitationFormatter {
    enum Style: String, CaseIterable, Sendable {
        case chicagoNote = "Chicago (note)"
        // MLA / APA can layer on later.
    }

    /// Format one citation as a single-line reference string.
    /// `entry` is the catalog match (looked up by the caller via
    /// `bookEpubURL`); nil when the citation didn't resolve to a
    /// catalog row (per-book chat, or a library entry that's
    /// since been removed).
    static func format(
        citation: BookChatCitation,
        entry: LibraryEntry?,
        style: Style = .chicagoNote
    ) -> String {
        switch style {
        case .chicagoNote:
            return chicagoNote(citation: citation, entry: entry)
        }
    }

    /// Markdown bulleted bibliography for the citations in one
    /// chat message. Numbered list; duplicates collapsed via the
    /// citation's id so re-citing the same passage doesn't
    /// repeat in the bibliography. `@MainActor` because the
    /// LibraryStore lookup hits @Published catalog state.
    @MainActor
    static func bibliography(
        citations: [BookChatCitation],
        library: LibraryStore?,
        style: Style = .chicagoNote
    ) -> String {
        let unique = uniqued(citations)
        guard !unique.isEmpty else { return "" }
        let lines = unique.enumerated().map { idx, citation in
            let entry = library?.entries.first {
                $0.epubURL.canonicalForFile == citation.bookEpubURL?.canonicalForFile
            }
            return "\(idx + 1). \(format(citation: citation, entry: entry, style: style))"
        }
        return lines.joined(separator: "\n")
    }

    /// Full transcript as Markdown — alternating user / assistant
    /// turns, citation chips inline as footnote markers, a single
    /// "Sources" section at the end with the deduplicated
    /// bibliography. Drops into Obsidian / a writing tool as a
    /// ready-to-edit research note.
    @MainActor
    static func transcript(
        messages: [BookChatMessage],
        library: LibraryStore?,
        style: Style = .chicagoNote,
        title: String = "Library chat transcript"
    ) -> String {
        var output: [String] = []
        output.append("# \(title)")
        output.append("")
        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }()
        output.append("*Exported \(dateFormatter.string(from: Date()))*")
        output.append("")

        // Build a stable footnote-id map across all assistant
        // messages: the first time a citation appears it gets
        // index N; subsequent references reuse N. Reader-friendly
        // when the same passage is cited multiple times.
        var citationOrder: [String: Int] = [:]
        var orderedCitations: [BookChatCitation] = []
        for message in messages where message.role == .assistant {
            for citation in message.citations {
                if citationOrder[citation.id] == nil {
                    citationOrder[citation.id] = orderedCitations.count + 1
                    orderedCitations.append(citation)
                }
            }
        }

        for message in messages {
            switch message.role {
            case .user:
                output.append("## You")
                output.append("")
                output.append(message.text)
            case .assistant:
                output.append("## Assistant")
                output.append("")
                // Append footnote markers at the end of the
                // message rather than re-inserting into the text
                // (which would require parsing the inline
                // `[book:N chapter:M]` markers — out of scope for
                // v1). Compact: `Sources: ¹ ² ⁵.`
                output.append(message.text)
                if !message.citations.isEmpty {
                    let markers = message.citations
                        .compactMap { citationOrder[$0.id] }
                        .map { "[^\($0)]" }
                        .joined(separator: " ")
                    if !markers.isEmpty {
                        output.append("")
                        output.append("Sources: \(markers)")
                    }
                }
            }
            output.append("")
            output.append("---")
            output.append("")
        }

        // Strip the trailing `---\n` if the last message produced
        // one — Markdown looks cleaner without a divider before
        // the Sources heading.
        if output.last == "" { output.removeLast() }
        if output.last == "---" { output.removeLast() }
        if output.last == "" { output.removeLast() }

        if !orderedCitations.isEmpty {
            output.append("")
            output.append("## Sources")
            output.append("")
            for (idx, citation) in orderedCitations.enumerated() {
                let entry = library?.entries.first {
                    $0.epubURL.canonicalForFile == citation.bookEpubURL?.canonicalForFile
                }
                let line = format(citation: citation, entry: entry, style: style)
                output.append("[^\(idx + 1)]: \(line)")
            }
        }

        return output.joined(separator: "\n")
    }

    // MARK: - Chicago note-style

    /// Chicago note-style citation. Examples:
    ///
    ///   Michel Foucault, *Discipline and Punish*, ch. 5, ¶ 12.
    ///   *Discipline and Punish*, ch. 5, ¶ 12.   ← no author
    ///   Michel Foucault, *Discipline and Punish*, ch. 5.        ← no para
    ///
    /// Falls back to the citation's own `bookTitle` / chapter
    /// title when the catalog entry is missing — covers per-book
    /// chat and library entries that have been removed.
    private static func chicagoNote(
        citation: BookChatCitation, entry: LibraryEntry?
    ) -> String {
        var parts: [String] = []
        if let author = entry?.author, !author.isEmpty {
            parts.append(author)
        }
        let title = entry?.title ?? citation.bookTitle ?? "Untitled book"
        parts.append("*\(title)*")
        // Chapter — use chapter title when present; falls back to
        // numbered ("ch. N", 1-based). The user-visible numbering
        // matches how the chip surfaces in the chat.
        let chapter = citation.title.isEmpty
            ? "ch. \(citation.chapterIndex + 1)"
            : "“\(citation.title)”"
        parts.append(chapter)
        if let paragraphIdx = citation.paragraphIndex {
            parts.append("¶ \(paragraphIdx + 1)")
        }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - dedup

    private static func uniqued(
        _ citations: [BookChatCitation]
    ) -> [BookChatCitation] {
        var seen = Set<String>()
        var out: [BookChatCitation] = []
        for c in citations where seen.insert(c.id).inserted {
            out.append(c)
        }
        return out
    }
}
