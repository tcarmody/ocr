import SwiftUI

/// Reusable transcript row + citation chip strip used by both the
/// per-book chat pane (`ChatPaneView`) and the library-scope chat
/// pane (`LibraryChatPaneView`). Lifted out of `ChatPaneView` when
/// `R-Library-Chat` introduced the second surface; nothing about
/// rendering a chat turn is book-specific.
struct ChatMessageRow: View {
    let message: BookChatMessage
    let onCitationTap: (BookChatCitation) -> Void
    /// When true, assistant messages with retrieval data show a
    /// per-hit score / rank breakdown beneath their citation
    /// strip. Driven by a per-window toggle in the chat pane
    /// chrome — useful for diagnosing "why did this paragraph
    /// surface?" without reaching for a debugger.
    var showRetrievalDetail: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: roleIcon)
                    .foregroundStyle(.secondary)
                Text(roleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(bubbleColor)
                )
            if !message.citations.isEmpty {
                FlowingCitationRow(
                    citations: message.citations,
                    onTap: onCitationTap
                )
            }
            if showRetrievalDetail,
               let detail = message.retrievalDetail,
               !detail.hits.isEmpty {
                retrievalDetailView(detail)
            }
        }
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
            ? Color.accentColor.opacity(0.10)
            : Color.secondary.opacity(0.08)
    }
}

/// Wraps citations into a multi-line row. SwiftUI's HStack
/// doesn't reflow, and on a tight chat pane the chip strip needs
/// to wrap when there are several.
struct FlowingCitationRow: View {
    let citations: [BookChatCitation]
    let onTap: (BookChatCitation) -> Void

    var body: some View {
        // ViewThatFits + horizontal layouts handles the common
        // 2–4 citation case cleanly without a custom Layout.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { content }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { content }
            }
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
                    Capsule().fill(Color.accentColor.opacity(0.14))
                )
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(citationHelpText(citation))
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
