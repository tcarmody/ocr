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
    /// Shared coordinator — observed so the chat pane can show a
    /// "wait for indexing" banner and disable the send button
    /// while a bulk indexer or importer is in flight. Reading from
    /// sidecars during a write gives inconsistent results, so
    /// blocking the user here matches the model.
    @ObservedObject private var indexCoordinator
        = VectorIndexCoordinator.shared
    let onCitationTap: (BookChatCitation) -> Void
    @State private var showRetrievalDetail: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            if !indexCoordinator.isStable {
                indexBusyBanner
            }
            Divider()
            transcript
            Divider()
            fallbackStrip
            inputRow
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Banner shown when something is actively mutating the vector
    /// index (bulk indexer, EPUB importer with sidecar build, etc.)
    /// — chat reads are gated until it clears. Distinct visual
    /// posture from `mainStatusRow` so the user sees this as a
    /// transient block, not a permanent state.
    @ViewBuilder
    private var indexBusyBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(indexCoordinator.activeDescription
                 ?? "Library indexing in progress")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Send disabled")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }

    // MARK: - status strip

    @ViewBuilder
    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            mainStatusRow
            if vm.scopedURLs != nil {
                scopedStatusRow
            }
            if !vm.excludedBookURLs.isEmpty {
                exclusionStatusRow
            }
        }
    }

    @ViewBuilder
    private var mainStatusRow: some View {
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
            Button {
                vm.useLongFormSynthesis.toggle()
            } label: {
                Image(systemName: vm.useLongFormSynthesis
                      ? "doc.text.fill"
                      : "doc.text")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help(vm.useLongFormSynthesis
                  ? "Switch back to short chat-shaped answers"
                  : "Longer-form: a few well-developed paragraphs instead of one or two")
            Button {
                showRetrievalDetail.toggle()
            } label: {
                Image(systemName: showRetrievalDetail
                      ? "info.circle.fill"
                      : "info.circle")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help(showRetrievalDetail
                  ? "Hide retrieval detail under each answer"
                  : "Show retrieval detail under each answer")
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

    /// Banner that surfaces the active retrieval scope. Renders
    /// only when the user has flipped to a subset via "Chat with
    /// Selected" in the Library window. Lists up to three book
    /// titles inline; longer scopes get the count + "…".
    @ViewBuilder
    private var scopedStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .foregroundStyle(Color.accentColor)
                .imageScale(.small)
            Text(scopeSummary())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("Clear") { vm.clearScope() }
                .controlSize(.small)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.06))
    }

    private func scopeSummary() -> String {
        let titles = vm.scopedTitles
        if titles.isEmpty { return "Scoped retrieval" }
        if titles.count <= 3 {
            return "Scoped to: \(titles.joined(separator: ", "))"
        }
        let head = titles.prefix(3).joined(separator: ", ")
        return "Scoped to \(titles.count) books — \(head), …"
    }

    /// Banner that surfaces deny-listed books — populated when
    /// the user right-clicks a citation chip and picks
    /// "Exclude {Book} from chat." Mirrors the scoped-row layout
    /// for visual consistency.
    @ViewBuilder
    private var exclusionStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.orange)
                .imageScale(.small)
            Text(exclusionSummary())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("Clear") { vm.clearExclusions() }
                .controlSize(.small)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.06))
    }

    private func exclusionSummary() -> String {
        let titles = vm.excludedBookURLs
            .compactMap { vm.excludedBookTitles[$0] }
            .sorted()
        if titles.isEmpty {
            return "Excluded \(vm.excludedBookURLs.count) book(s)"
        }
        if titles.count <= 3 {
            return "Excluded: \(titles.joined(separator: ", "))"
        }
        let head = titles.prefix(3).joined(separator: ", ")
        return "Excluded \(titles.count) books — \(head), …"
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
                            onCitationTap: onCitationTap,
                            onFollowUpTap: { question in
                                guard !vm.isThinking else { return }
                                vm.input = question
                                Task { await vm.send() }
                            },
                            onExcludeBook: { citation in
                                guard let url = citation.bookEpubURL,
                                      let title = citation.bookTitle
                                else { return }
                                vm.excludeBook(url: url, title: title)
                            },
                            showRetrievalDetail: showRetrievalDetail
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
        ChatInputRow(
            text: $vm.input,
            placeholder: "Ask a question across your library…",
            isThinking: vm.isThinking,
            isBlocked: !indexCoordinator.isStable,
            onSend: { Task { await vm.send() } }
        )
    }
}
