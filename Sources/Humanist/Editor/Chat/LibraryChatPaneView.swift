import SwiftUI

/// Library-scope chat pane. Lives inside the Library window's split
/// view; same overall shape as `ChatPaneView` but trimmed for the
/// always-library scope:
///  * no scope picker (the scope *is* library)
///  * no per-book embedding-build banner — federated retrieval
///    reads from already-built sidecars
///  * a federated-index status row at the top reports how many
///    books participate in the current backend's vector space
///  * a fallback-note strip when the embedding backend silently
///    degraded (e.g. Voyage key rotated → NLEmbedding)
struct LibraryChatPaneView: View {
    @ObservedObject var vm: LibraryChatViewModel
    let onCitationTap: (BookChatCitation) -> Void

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            Divider()
            transcript
            Divider()
            fallbackStrip
            inputRow
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - status strip

    @ViewBuilder
    private var statusStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .foregroundStyle(.secondary)
            Text("Library chat")
                .font(.callout.weight(.medium))
            Spacer()
            switch vm.libraryStatus {
            case .idle:
                Text("Index will build on the next message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .building:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Building library index…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .ready(let indexed, let unindexed, let mismatch):
                Text(libraryReadySummary(
                    indexed: indexed,
                    unindexed: unindexed,
                    mismatch: mismatch
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Button {
                    vm.invalidateLibraryIndex()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("Rebuild the federated index from current sidecars")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !vm.messages.isEmpty {
                Button {
                    vm.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("Clear this transcript (deletes the persisted chat)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func libraryReadySummary(
        indexed: Int, unindexed: Int, mismatch: Int
    ) -> String {
        let total = indexed + unindexed + mismatch
        var parts: [String] = ["\(indexed) of \(total) books indexed"]
        if mismatch > 0 {
            parts.append("\(mismatch) on a different backend")
        }
        if unindexed > 0 {
            parts.append("\(unindexed) not yet indexed")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - transcript

    @ViewBuilder
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if vm.messages.isEmpty {
                        emptyState
                    }
                    ForEach(vm.messages) { message in
                        ChatMessageRow(
                            message: message,
                            onCitationTap: onCitationTap
                        )
                        .id(message.id)
                    }
                    if vm.isThinking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
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
            Image(systemName: "books.vertical.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Ask about your library")
                .font(.headline)
            Text("""
                Try “which books mention Bourdieu?”, “summarize \
                what my library says about heterotopia”, or \
                “compare Foucault's view of power to Deleuze's”. \
                Replies cite each source book; click a citation \
                to open that book in a new editor window.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    // MARK: - fallback strip

    @ViewBuilder
    private var fallbackStrip: some View {
        if let note = vm.fallbackNote {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.orange)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.06))
        } else {
            EmptyView()
        }
    }

    // MARK: - input row

    @ViewBuilder
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Ask a question across your library…",
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
