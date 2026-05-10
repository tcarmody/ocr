import SwiftUI

/// "Chat with this book" pane. Scrolling transcript + input row
/// at the bottom; assistant messages render their citations as
/// clickable chips that ask the editor to select the cited
/// chapter.
struct ChatPaneView: View {
    @ObservedObject var vm: BookChatViewModel
    /// Forwarded to the editor when the user clicks a citation.
    let onCitationTap: (BookChatCitation) -> Void
    /// Per-window toggle that reveals the retrieval-debug
    /// disclosure beneath each assistant message. Useful when
    /// retrieval misfires and the user wants to see *why* each
    /// paragraph was picked. Persisted across sends but not
    /// across editor reopen — debug state is ephemeral by design.
    @State private var showRetrievalDetail: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            scopeStrip
            if !vm.excludedLibraryBookURLs.isEmpty,
               vm.chatScope == .library {
                exclusionStatusRow
            }
            Divider()
            transcript
            Divider()
            indexingStrip
            fallbackStrip
            inputRow
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Library-scope deny-list banner. Mirrors the equivalent
    /// row in the dedicated library chat pane — appears only when
    /// the user has right-click → Exclude'd a citation in
    /// library scope.
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
            Button("Clear") { vm.clearLibraryExclusions() }
                .controlSize(.small)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.06))
    }

    private func exclusionSummary() -> String {
        let titles = vm.excludedLibraryBookURLs
            .compactMap { vm.excludedLibraryBookTitles[$0] }
            .sorted()
        if titles.isEmpty {
            return "Excluded \(vm.excludedLibraryBookURLs.count) book(s)"
        }
        if titles.count <= 3 {
            return "Excluded: \(titles.joined(separator: ", "))"
        }
        let head = titles.prefix(3).joined(separator: ", ")
        return "Excluded \(titles.count) books — \(head), …"
    }

    /// Surfaces a silent backend fallback so the user notices when
    /// their chosen embedding backend (Ollama / Voyage / Gemini)
    /// isn't actually serving requests and NLEmbedding has taken
    /// over.
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

    /// Scope picker at the top of the chat pane. Lets the user flip
    /// between "current book only" and "whole library" retrieval
    /// without leaving the chat. The library row also surfaces an
    /// "X of Y indexed for current backend" hint so the user knows
    /// what's actually participating.
    @ViewBuilder
    private var scopeStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("Scope", selection: $vm.chatScope) {
                    ForEach(ChatScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
                Button {
                    vm.useLongFormSynthesis.toggle()
                } label: {
                    Image(systemName: vm.useLongFormSynthesis
                          ? "doc.text.fill"
                          : "doc.text")
                }
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
                .buttonStyle(.borderless)
                .help(showRetrievalDetail
                      ? "Hide retrieval detail under each answer"
                      : "Show retrieval detail under each answer")
            }
            if vm.chatScope == .library {
                libraryStatusLabel
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var libraryStatusLabel: some View {
        switch vm.libraryStatus {
        case .idle:
            Text("Federated retrieval will build on the next message.")
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
            let total = indexed + unindexed + mismatch
            Text(libraryReadySummary(
                indexed: indexed, unindexed: unindexed,
                mismatch: mismatch, total: total
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func libraryReadySummary(
        indexed: Int, unindexed: Int, mismatch: Int, total: Int
    ) -> String {
        var parts: [String] = []
        parts.append("\(indexed) of \(total) books indexed")
        if mismatch > 0 {
            parts.append("\(mismatch) on a different backend")
        }
        if unindexed > 0 {
            parts.append("\(unindexed) not yet indexed")
        }
        return parts.joined(separator: " · ")
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
                        ChatMessageRow(
                            message: message,
                            onCitationTap: onCitationTap,
                            onFollowUpTap: { question in
                                // Populate the input field and
                                // send immediately. Skips when
                                // a previous send is still in
                                // flight to avoid concurrent
                                // streamTask races.
                                guard !vm.isThinking else { return }
                                vm.input = question
                                Task { await vm.send() }
                            },
                            onExcludeBook: { citation in
                                guard let url = citation.bookEpubURL,
                                      let title = citation.bookTitle
                                else { return }
                                vm.excludeLibraryBook(url: url, title: title)
                            },
                            showRetrievalDetail: showRetrievalDetail
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
        ChatInputRow(
            text: $vm.input,
            placeholder: "Ask a question…",
            isThinking: vm.isThinking,
            onSend: { Task { await vm.send() } }
        )
    }
}

