import SwiftUI
import EPUB

/// Standalone chat window for one EPUB. Hosts the same
/// `ChatPaneView` the editor's embedded pane uses, but in its own
/// `WindowGroup` scene so it doesn't share an SwiftUI update graph
/// with the editor's heavy view tree (source pane + preview).
///
/// Why this exists: the embedded chat pane in the editor window
/// inherits layout invalidation from the editor's source/preview
/// NSTextViews. SwiftUI's LazySubviewPlacements pass cascades
/// through ALL of the editor window's chrome on every render,
/// dragging the chat transcript into per-frame layout work. A
/// separate window isolates the chat's view graph, so scroll +
/// hover stay smooth even on long transcripts.
///
/// Transcript persistence is keyed by the EPUB URL — pane and
/// window share the on-disk JSON. Real-time state isn't shared
/// (each VM has its own messages array in memory), so a message
/// sent in the pane won't show in the window until the window
/// VM is recreated, and vice versa. Acceptable for v1 since the
/// expected workflow is "use the window OR the pane, not both."
struct BookChatWindowView: View {
    let epubURL: URL
    /// Library reference wired by the window's `.task` after
    /// `OpenRouter.library` becomes available. Same reason the
    /// editor pane needs it: chat library-scope retrieval reads
    /// the live catalog rather than instantiating its own
    /// `LibraryStore()` per send.
    @State private var loadState: LoadState = .loading

    var body: some View {
        contents
            .frame(minWidth: 480, minHeight: 540)
            .task { await load() }
    }

    @ViewBuilder
    private var contents: some View {
        switch loadState {
        case .loading:
            ProgressView("Opening book…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Couldn't open this book for chat")
                    .font(.headline)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let vm):
            ChatPaneView(vm: vm, onCitationTap: { _ in })
        }
    }

    @MainActor
    private func load() async {
        // Already loaded? Refreshing the window keeps the same VM
        // so the transcript / in-flight stream survives a window-
        // hide/show cycle.
        if case .ready = loadState { return }
        do {
            let book = try EPUBBook.open(epubURL: epubURL)
            let vm = BookChatViewModel(book: book, epubURL: epubURL)
            vm.library = OpenRouter.library
            loadState = .ready(vm)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private enum LoadState {
        case loading
        case failed(String)
        case ready(BookChatViewModel)
    }
}
