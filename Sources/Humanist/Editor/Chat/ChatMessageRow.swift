import SwiftUI

/// Reusable transcript row + citation chip strip used by both the
/// per-book chat pane (`ChatPaneView`) and the library-scope chat
/// pane (`LibraryChatPaneView`). Lifted out of `ChatPaneView` when
/// `R-Library-Chat` introduced the second surface; nothing about
/// rendering a chat turn is book-specific.
struct ChatMessageRow: View {
    let message: BookChatMessage
    let onCitationTap: (BookChatCitation) -> Void
    /// Optional: copy one citation as a formatted reference
    /// string. Surfaced as a context menu on each citation chip
    /// when non-nil.
    var onCopyCitation: ((BookChatCitation) -> Void)? = nil
    /// Optional: copy the message's full citation list as a
    /// Markdown bibliography. Surfaced as a small button next to
    /// the citation strip when non-nil and the message has any
    /// citations.
    var onCopyBibliography: (([BookChatCitation]) -> Void)? = nil
    /// Optional citation-chip context-menu action for library-
    /// scope chats: "Exclude {Book Title} from chat." Hidden
    /// (no menu item) when nil or when the citation isn't a
    /// library citation.
    var onExcludeBook: ((BookChatCitation) -> Void)? = nil
    /// When true, assistant messages with retrieval data show a
    /// per-hit score / rank breakdown beneath their citation
    /// strip. Driven by a per-window toggle in the chat pane
    /// chrome — useful for diagnosing "why did this paragraph
    /// surface?" without reaching for a debugger.
    var showRetrievalDetail: Bool = false
    /// Non-nil → the "Select Text…" sheet is presented with that
    /// message text. User-message sheet only — assistant-side
    /// selection sheet is owned inside `MarkdownMessageBody`.
    @State private var userSelectionSheetText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: roleIcon)
                    .foregroundStyle(.secondary)
                Text(roleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Assistant replies routinely include Markdown
            // (**bold**, lists, headings, inline `code`); the user's
            // own input is plain text. Render via the
            // Markdown-aware body for assistant turns; keep the
            // raw `Text` for the user side both because it doesn't
            // need formatting and because rendering user-typed
            // asterisks as bold is the wrong behavior.
            Group {
                if message.role == .assistant {
                    MarkdownMessageBody(text: message.text)
                        .font(.callout)
                } else {
                    // Plain Text — see the matching comment in
                    // `MarkdownMessageBody` for why neither
                    // `.textSelection(.enabled)` nor the
                    // `SelectableMessageText` NSTextView wrapper
                    // works on macOS 26 without hanging the chat
                    // scroll. Selection is opt-in via the context
                    // menu's "Select Text…" sheet.
                    Text(message.text)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    message.text, forType: .string
                                )
                            } label: {
                                Label("Copy Message", systemImage: "doc.on.doc")
                            }
                            Button {
                                userSelectionSheetText = message.text
                            } label: {
                                Label("Select Text…", systemImage: "text.cursor")
                            }
                        }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(bubbleColor)
            )
            if !message.citations.isEmpty {
                FlowingCitationRow(
                    citations: message.citations,
                    onTap: onCitationTap,
                    onExcludeBook: onExcludeBook,
                    onCopyCitation: onCopyCitation
                )
                if let copyBib = onCopyBibliography {
                    Button {
                        copyBib(message.citations)
                    } label: {
                        Label(
                            "Copy bibliography",
                            systemImage: "list.bullet.clipboard"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy a Markdown bibliography of this answer's citations to the clipboard.")
                }
            }
            if showRetrievalDetail,
               let detail = message.retrievalDetail,
               !detail.hits.isEmpty {
                retrievalDetailView(detail)
            }
        }
        .sheet(item: Binding(
            get: { userSelectionSheetText.map(SelectionPayload.init) },
            set: { userSelectionSheetText = $0?.text }
        )) { payload in
            MessageSelectionSheet(text: payload.text) {
                userSelectionSheetText = nil
            }
        }
    }

    /// Wrap for `.sheet(item:)` since String isn't Identifiable.
    private struct SelectionPayload: Identifiable {
        let text: String
        var id: String { text }
    }

    @ViewBuilder
    private func retrievalDetailView(_ detail: RetrievalDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Retrieved \(detail.hits.count) paragraph\(detail.hits.count == 1 ? "" : "s")")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(Array(detail.hits.enumerated()), id: \.offset) { _, hit in
                Text(formatHit(hit))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    /// Single-line hit summary suited to a monospaced caption row.
    /// Library hits include the source book; per-book hits skip it.
    private func formatHit(_ hit: RetrievalDetail.Hit) -> String {
        var parts: [String] = []
        if let book = hit.bookTitle {
            parts.append(book)
        }
        parts.append("ch.\(hit.chapterIdx) ¶\(hit.paragraphIdx)")
        parts.append(String(format: "score=%.4f", hit.score))
        if let rank = hit.bm25Rank { parts.append("bm25=\(rank)") }
        if let rank = hit.embeddingRank { parts.append("emb=\(rank)") }
        if hit.hierarchyMatched { parts.append("hier✓") }
        if hit.entityMatched { parts.append("ent✓") }
        return parts.joined(separator: " · ")
    }

    private var roleLabel: String {
        message.role == .user ? "You" : "Assistant"
    }

    private var roleIcon: String {
        message.role == .user ? "person.fill" : "sparkle"
    }

    private var bubbleColor: Color {
        message.role == .user
            ? HumanistTheme.accent.opacity(0.10)
            : Color.secondary.opacity(0.08)
    }
}

/// Wraps citations into a multi-line row. SwiftUI's HStack
/// doesn't reflow, and on a tight chat pane the chip strip needs
/// to wrap when there are several.
struct FlowingCitationRow: View {
    let citations: [BookChatCitation]
    let onTap: (BookChatCitation) -> Void
    /// Optional secondary action surfaced via context menu —
    /// "Exclude this book from chat." Only meaningful for
    /// library-scope citations (those carry `bookEpubURL`); the
    /// menu item suppresses itself when the citation has no book.
    var onExcludeBook: ((BookChatCitation) -> Void)? = nil
    /// Optional context-menu action: "Copy citation." Wired from
    /// the chat pane, which has the library reference needed to
    /// look up author / title metadata for the formatter.
    /// Suppresses when nil so non-library-scope callers don't
    /// see a useless action.
    var onCopyCitation: ((BookChatCitation) -> Void)? = nil

    var body: some View {
        // Plain HStack — was `ViewThatFits` with two variants but
        // SwiftUI re-measured both on every parent body recompute,
        // and per-frame measurement of all the citation chips
        // dominated scroll cost on long transcripts (sampled
        // cascade pinned in `LazyHVStack.lengthAndSpacing` from
        // the inner HStack inside ViewThatFits). Citations now
        // overflow + truncate on tight panes; proper wrapping
        // would need a custom `Layout` — queued as a follow-up.
        HStack(spacing: 6) {
            content
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        ForEach(citations) { citation in
            Button {
                onTap(citation)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: citation.bookEpubURL == nil
                          ? "book.closed" : "books.vertical")
                        .imageScale(.small)
                    Text(citationLabel(citation))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(HumanistTheme.accent.opacity(0.14))
                )
                .foregroundStyle(HumanistTheme.accent)
            }
            .buttonStyle(.plain)
            .help(citationHelpText(citation))
            .contextMenu {
                if let copy = onCopyCitation {
                    Button {
                        copy(citation)
                    } label: {
                        Label(
                            "Copy citation",
                            systemImage: "doc.on.doc"
                        )
                    }
                }
                if let exclude = onExcludeBook,
                   citation.bookEpubURL != nil,
                   let title = citation.bookTitle {
                    Button {
                        exclude(citation)
                    } label: {
                        Label(
                            "Exclude \(title) from chat",
                            systemImage: "minus.circle"
                        )
                    }
                }
            }
        }
    }

    /// Library citations show "Book Title — ch. N"; per-book
    /// citations show the chapter title. Both append "¶ M" when
    /// the citation carries a paragraph index so the user sees
    /// at a glance that the chip jumps to a specific paragraph
    /// rather than the chapter top.
    private func citationLabel(_ citation: BookChatCitation) -> String {
        let paraSuffix = citation.paragraphIndex
            .map { " ¶\($0)" } ?? ""
        if let book = citation.bookTitle {
            return "\(book) — ch. \(citation.chapterIndex + 1)\(paraSuffix)"
        }
        return "\(citation.title)\(paraSuffix)"
    }

    private func citationHelpText(_ citation: BookChatCitation) -> String {
        if citation.bookEpubURL != nil {
            return "Open in a new editor window"
        }
        if citation.paragraphIndex != nil {
            return "Scroll to this paragraph in \(citation.title)"
        }
        return "Open \(citation.title)"
    }
}
