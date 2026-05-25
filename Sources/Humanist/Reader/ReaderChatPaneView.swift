import SwiftUI
import AppKit

/// R-Reader Phase 2. Chat-with-this-book pane embedded in the
/// reader window. Strips the editor's `ChatPaneView` down to
/// what makes sense for a reading surface:
///
///   * **No scope picker** — chat is always about the open book.
///     Library-scope chat keeps its dedicated home in the Library
///     window where the federated-index status, exclusion list,
///     and collection scoping have room to breathe.
///   * **No exclusion banner** — only meaningful in library scope.
///   * **No federated-index status** — same reason.
///   * Keeps: transcript scroll, indexing strip, fallback strip,
///     input row, citation chips that snap the reading pane to
///     the cited chapter.
struct ReaderChatPaneView: View {
    @ObservedObject var vm: BookChatViewModel
    /// Forwarded by the parent reader view — taps the citation
    /// chip and the reader jumps the WKWebView pane to the cited
    /// spine index.
    let onCitationTap: (BookChatCitation) -> Void
    /// Per-window retrieval-detail toggle. Same idea as the
    /// editor's chat pane — useful when retrieval looks off and
    /// the user wants to see why each paragraph got picked.
    @State private var showRetrievalDetail: Bool = false
    /// Mirrors the editor chat pane's briefing-sheet trigger.
    /// Local @State so re-renders from the streaming
    /// BookBriefingService stay contained inside the sheet's
    /// container view (same cascade-avoidance pattern as
    /// ChatPaneView).
    @State private var showBriefingSheet: Bool = false

    // Chat appearance — same three knobs as the editor's
    // ChatPaneView; @AppStorage keys shared via ChatAppearance.Keys
    // so all chat surfaces agree.
    @AppStorage(ChatAppearance.Keys.fontFamily)
    private var appearanceFontFamilyRaw: String = ChatAppearance.FontFamily.system.rawValue
    @AppStorage(ChatAppearance.Keys.fontSize)
    private var appearanceFontSizeRaw: String = ChatAppearance.FontSize.medium.rawValue
    @AppStorage(ChatAppearance.Keys.colorMode)
    private var appearanceColorModeRaw: String = ChatAppearance.ColorMode.auto.rawValue

    private var resolvedAppearance: ChatAppearance.Resolved {
        ChatAppearance.resolve(
            family: ChatAppearance.FontFamily(rawValue: appearanceFontFamilyRaw)
                ?? .system,
            size: ChatAppearance.FontSize(rawValue: appearanceFontSizeRaw)
                ?? .medium,
            mode: ChatAppearance.ColorMode(rawValue: appearanceColorModeRaw)
                ?? .auto
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            Divider()
            transcript
            Divider()
            indexingStrip
            fallbackStrip
            inputRow
        }
        .background(Color(nsColor: .textBackgroundColor))
        .preferredColorScheme(resolvedAppearance.colorScheme)
        .sheet(isPresented: $showBriefingSheet) {
            BriefingSheetContainer(
                book: vm.book,
                bookTitle: vm.book.metadata.title ?? "this book",
                entry: vm.library?.entries.first {
                    $0.epubURL.canonicalForFile
                        == vm.epubURL.canonicalForFile
                },
                library: vm.library,
                onDismiss: { showBriefingSheet = false }
            )
        }
    }

    // MARK: - Chrome (top row above the transcript)

    /// Minimal chrome — long-form synthesis toggle + retrieval
    /// detail toggle + export. No scope picker; scope is locked
    /// to `.currentBook` on the VM. Mirrors the editor's chrome
    /// minus the scope strip so users moving between editor +
    /// reader keep their muscle memory.
    @ViewBuilder
    private var chrome: some View {
        HStack(spacing: 8) {
            Text("Chat with this book")
                .font(.callout.weight(.medium))
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
            .accessibilityLabel(vm.useLongFormSynthesis
                  ? "Switch to short answers"
                  : "Switch to long-form answers")
            Button {
                showBriefingSheet = true
            } label: {
                Image(systemName: "text.book.closed")
            }
            .buttonStyle(.borderless)
            .help("Pre-reading briefing: what this book is doing, what tradition it sits in, what to watch for")
            .accessibilityLabel("Pre-reading briefing")
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
            .accessibilityLabel(showRetrievalDetail
                  ? "Hide retrieval detail"
                  : "Show retrieval detail")
            if !vm.messages.isEmpty {
                Button { exportTranscript() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("Export this transcript as Markdown (citations resolved) to the clipboard")
                .accessibilityLabel("Export chat transcript")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Indexing / fallback strips

    /// Slim status strip above the input row. Identical posture
    /// to the editor's `indexingStrip` — silent during the
    /// common case (cached index ready), visible while a build
    /// is in flight or after a failure.
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

    /// Silent-fallback notice — same posture as the editor's
    /// `fallbackStrip`. Surfaces when the chosen embedding backend
    /// (Ollama / Voyage / Gemini) silently failed and the chat
    /// dropped back to NLEmbedding without a visible signal
    /// otherwise.
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

    // MARK: - Transcript

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
                            onCopyCitation: copyCitation,
                            onCopyBibliography: copyBibliography,
                            // Reader chat is locked to current-book
                            // scope — citations never carry a
                            // bookEpubURL, so exclude-from-library
                            // can't fire. Pass a no-op so the row
                            // doesn't show the action in its
                            // context menu.
                            onExcludeBook: { _ in },
                            showRetrievalDetail: showRetrievalDetail,
                            appearance: resolvedAppearance
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
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Ask about this book")
                .font(.headline)
            Text("""
                Replies cite the chapters they pull from. Click a \
                citation to jump there in the reading pane.
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

    // MARK: - Export / copy helpers

    private func exportTranscript() {
        let markdown = ChatCitationFormatter.transcript(
            messages: vm.messages,
            library: vm.library,
            title: "Book chat transcript"
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }

    private func copyCitation(_ citation: BookChatCitation) {
        let entry = vm.library?.entries.first {
            $0.epubURL.canonicalForFile
                == citation.bookEpubURL?.canonicalForFile
        }
        let line = ChatCitationFormatter.format(
            citation: citation, entry: entry
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(line, forType: .string)
    }

    private func copyBibliography(_ citations: [BookChatCitation]) {
        let markdown = ChatCitationFormatter.bibliography(
            citations: citations, library: vm.library
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }
}
