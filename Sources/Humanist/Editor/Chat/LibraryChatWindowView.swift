import SwiftUI

/// Standalone library-chat window. Hosts the same
/// `LibraryChatPaneView` the library window embeds, but in its
/// own `Window` scene so its view graph is isolated from the
/// library window's table + sidebar + cover-thumbnail churn.
///
/// Why: the embedded library chat pane sits inside the library
/// window's split view alongside the books table. SwiftUI's
/// LazySubviewPlacements pass cascades through the whole window's
/// chrome on every render — the table publishes a lot, covers
/// load asynchronously, the sidebar updates, etc. — and drags the
/// chat transcript into per-frame layout work. Scroll + hover
/// pin the main thread. A standalone window detaches chat from
/// all of that.
///
/// Transcript persistence is keyed by the fixed
/// `~/Library/Application Support/Humanist/Chats/library.json`
/// path — pane and window share the on-disk JSON. Real-time state
/// isn't shared (each VM holds its own messages array in memory),
/// so a message sent in the pane won't show in the window until
/// the window VM is recreated, and vice versa.
struct LibraryChatWindowView: View {
    /// VM created when the window first appears. `@StateObject`
    /// keeps the VM alive across SwiftUI re-renders of the
    /// window; the VM's transcript is loaded fresh from disk in
    /// `init`, so closing + reopening the window picks up any
    /// messages saved by the pane meanwhile.
    @StateObject private var vm = LibraryChatViewModel()

    var body: some View {
        LibraryChatPaneView(vm: vm)
            .frame(minWidth: 520, minHeight: 600)
            .task {
                // Wire the live LibraryStore reference once the
                // window is on screen — matches what the library
                // window does for its own pane VM. Without this,
                // every federated-index build path would
                // instantiate a fresh `LibraryStore()` per send
                // and pay the load() cost on the main thread.
                vm.library = OpenRouter.library
            }
    }
}
