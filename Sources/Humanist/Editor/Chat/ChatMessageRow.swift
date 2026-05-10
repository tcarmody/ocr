import SwiftUI

/// Reusable transcript row + citation chip strip used by both the
/// per-book chat pane (`ChatPaneView`) and the library-scope chat
/// pane (`LibraryChatPaneView`). Lifted out of `ChatPaneView` when
/// `R-Library-Chat` introduced the second surface; nothing about
/// rendering a chat turn is book-specific.
struct ChatMessageRow: View {
    let message: BookChatMessage
    let onCitationTap: (BookChatCitation) -> Void

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
        }
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
    /// citations show just the chapter title (the book is implicit
    /// in the active editor window).
    private func citationLabel(_ citation: BookChatCitation) -> String {
        if let book = citation.bookTitle {
            return "\(book) — ch. \(citation.chapterIndex + 1)"
        }
        return citation.title
    }

    private func citationHelpText(_ citation: BookChatCitation) -> String {
        if citation.bookEpubURL != nil {
            return "Open in a new editor window"
        }
        return "Open \(citation.title)"
    }
}
