import SwiftUI

/// "Chat with this book" pane. Scrolling transcript + input row
/// at the bottom; assistant messages render their citations as
/// clickable chips that ask the editor to select the cited
/// chapter.
struct ChatPaneView: View {
    @ObservedObject var vm: BookChatViewModel
    /// Forwarded to the editor when the user clicks a citation.
    let onCitationTap: (BookChatCitation) -> Void

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            indexingStrip
            inputRow
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Slim status strip above the input row. Only renders when the
    /// embedding index is mid-build or failed — silent when idle /
    /// ready / user-disabled. Keeps the chat pane visually quiet
    /// during the common case (cached index ready in a few seconds).
    @ViewBuilder
    private var indexingStrip: some View {
        switch vm.embeddingStatus {
        case .building:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Indexing for chat-with-book — keyword retrieval until done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.05))
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Embedding indexing failed: \(message). Falling back to keyword retrieval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.06))
        case .idle, .ready, .disabled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if vm.messages.isEmpty {
                        emptyState
                    }
                    ForEach(vm.messages) { message in
                        MessageRow(
                            message: message,
                            onCitationTap: onCitationTap
                        )
                        .id(message.id)
                    }
                    if vm.isThinking {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Thinking…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Ask about this book")
                .font(.headline)
            Text("""
                Try “where does Weber discuss charismatic authority?” \
                or “summarize chapter 3”. Replies cite the chapters \
                they pull from; click a citation to jump there.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Ask a question…",
                text: $vm.input,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...5)
            .onSubmit { Task { await vm.send() } }
            Button {
                Task { await vm.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(vm.input.trimmingCharacters(in: .whitespaces).isEmpty
                      || vm.isThinking)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - row

private struct MessageRow: View {
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
                citationStrip
            }
        }
    }

    @ViewBuilder
    private var citationStrip: some View {
        FlowingCitationRow(
            citations: message.citations,
            onTap: onCitationTap
        )
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
private struct FlowingCitationRow: View {
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
                    Image(systemName: "book.closed")
                        .imageScale(.small)
                    Text(citation.title)
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
            .help("Open \(citation.title)")
        }
    }
}
