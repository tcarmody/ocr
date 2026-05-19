import Foundation
import SwiftUI
import EPUB

/// R-Reader. Per-window state for the EPUB reader scene.
///
/// Loads the EPUB into an in-memory `EPUBBook`, walks the spine,
/// surfaces the current chapter as a file URL the reader's
/// embedded WKWebView can load directly. No editor coupling — the
/// reader reads from disk only; "Edit Source…" hands off to the
/// existing editor scene via `openWindow(id:value:)`.
@MainActor
final class ReaderViewModel: ObservableObject {

    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: LoadState = .loading
    /// In-memory model of the open EPUB. Owns the working
    /// directory's lifecycle (cleaned up on deinit unless ownership
    /// is reassigned — none of the reader's paths do that).
    @Published private(set) var book: EPUBBook?
    /// Parsed table of contents for the sidebar. Built once on
    /// load. Always populated when the book has at least one
    /// readable spine item (the parser falls back to spine
    /// filenames so the sidebar never goes blank).
    @Published private(set) var toc: ReaderTOC = ReaderTOC(entries: [])
    /// Zero-based position in the spine. Drives the chapter URL,
    /// prev/next button enablement, and (in a follow-up) the
    /// reading-position sidecar.
    @Published private(set) var spineIndex: Int = 0
    /// Bumps each time the reader requests a chapter re-load — the
    /// embedded WKWebView observes this through `WebReaderPane` so
    /// font-size changes / future theme changes trigger a refresh
    /// without changing the URL.
    @Published private(set) var reloadTrigger: Int = 0

    /// Pending paragraph-anchor scroll request. Set by
    /// `jumpToParagraph` when a chat citation chip is tapped
    /// with a paragraph index; consumed by `WebReaderPane`'s
    /// coordinator after the chapter's WKWebView finishes
    /// loading, then cleared. Anchor IDs follow the
    /// `hu-p-{chapterIdx}-{paragraphIdx}` convention written by
    /// `XHTMLWriter` on Humanist-converted EPUBs; third-party
    /// EPUBs that lack the anchors silently land at the chapter
    /// top.
    @Published var pendingScrollAnchor: ScrollAnchor?

    /// Anchor scroll request keyed by spine index + element id.
    /// Nonce-tagged so two requests to the same anchor still
    /// fire `onChange` in `WebReaderPane` — repeat-clicks on the
    /// same citation chip should re-scroll, not be coalesced.
    struct ScrollAnchor: Equatable {
        let spineIndex: Int
        let elementID: String
        let nonce: UUID
    }

    let epubURL: URL
    /// SHA-256 of the EPUB file. Populated asynchronously after
    /// `load()` finishes so the reader open isn't gated on
    /// hashing a 50 MB book. Used to key the
    /// `ReadingPositionStore` sidecar so positions survive
    /// file moves and multi-machine syncs.
    @Published private(set) var contentHash: String?

    /// Chat-sidebar visibility. Off by default — Cloud-mode chat
    /// costs API tokens per question, and the reader's posture is
    /// distraction-light; opt-in via the toolbar button (⌥⌘C). The
    /// toggle persists across windows via `@AppStorage`-style
    /// UserDefaults so the user's preference sticks.
    @Published var showChatPane: Bool {
        didSet {
            UserDefaults.standard.set(showChatPane, forKey: Self.chatPaneKey)
            if showChatPane { ensureChatViewModel() }
        }
    }

    /// Per-book chat session. Lazy: only allocated when the chat
    /// pane is first revealed, so opening a book to read stays
    /// cheap (no embedding-index build kicked off for users who
    /// only ever scroll).
    @Published private(set) var chatViewModel: BookChatViewModel?

    private static let chatPaneKey = "humanist.reader.showChatPane"

    static func defaultShowChatPane() -> Bool {
        if let v = UserDefaults.standard.object(forKey: chatPaneKey) as? Bool {
            return v
        }
        return false
    }

    init(epubURL: URL) {
        self.epubURL = epubURL
        self.showChatPane = Self.defaultShowChatPane()
        Task { await load() }
    }

    /// Open + parse the EPUB. Failure surfaces in `state.failed`;
    /// the reader view renders an error placeholder.
    func load() async {
        let url = epubURL
        do {
            let opened = try await Task.detached(priority: .userInitiated) {
                try EPUBBook.open(epubURL: url)
            }.value
            self.book = opened
            self.toc = ReaderTOC.build(from: opened)
            self.spineIndex = 0
            self.state = .ready
            // Pre-warm the chat VM regardless of `showChatPane`
            // so its background embedding-index build runs in
            // parallel with the user reading. By the time they
            // ⌥⌘C to ask a question, the index is ready and
            // the first send doesn't pay the 10–60s cold-start
            // delay. The transcript / BM25 / entity-index init
            // is cheap; the embedding build is what we're
            // pre-warming.
            ensureChatViewModel()
            // Hash + restore in the background. Don't gate the
            // reader window on this; the user can start reading
            // immediately and we'll jump them to the saved
            // position when the hash + lookup complete (usually
            // a fraction of a second on Apple Silicon).
            await restorePositionIfAvailable()
        } catch {
            self.state = .failed(error.localizedDescription)
        }
    }

    /// Compute the content hash off the main actor, look up the
    /// saved position, and jump to its spine index. No-op when
    /// no position is stored yet (first open of this book).
    /// `userHasNavigated` guards against racing the user — if
    /// they clicked a TOC entry between book-open and hash-
    /// done, don't yank them away from their click.
    private var userHasNavigated: Bool = false

    private func restorePositionIfAvailable() async {
        let url = epubURL
        let hash = await Task.detached(priority: .utility) {
            return try? ContentHash.sha256(of: url)
        }.value
        guard let hash else { return }
        self.contentHash = hash
        guard !userHasNavigated else { return }
        guard let saved = ReadingPositionStore.load(
            forContentHash: hash
        ) else { return }
        // Only jump when the saved position is past chapter 0 —
        // otherwise we'd issue a redundant load that flickers.
        guard saved.spineIndex > 0 else { return }
        guard !userHasNavigated else { return }
        jump(toSpineIndex: saved.spineIndex)
    }

    /// Persist the current position to the store. Called from
    /// every spine-changing path (`previousChapter`,
    /// `nextChapter`, `jump`). Writes are cheap (one tiny JSON
    /// file) so we don't bother debouncing at the spine
    /// granularity; per-scroll persistence (when it lands) will
    /// need debouncing.
    private func persistCurrentPosition() {
        guard let hash = contentHash else { return }
        let position = ReadingPosition(
            contentHash: hash,
            spineIndex: spineIndex,
            scrollFraction: 0,
            updatedAt: Date()
        )
        // Hop off the main actor — disk I/O shouldn't block the
        // chapter-change repaint, however cheap.
        Task.detached(priority: .utility) {
            ReadingPositionStore.save(position)
        }
    }

    // MARK: - Spine navigation

    /// Absolute URL on disk of the currently-selected spine chapter,
    /// or nil when the book isn't ready / the spine is empty.
    var currentChapterURL: URL? {
        guard let book, !book.spine.isEmpty,
              spineIndex >= 0, spineIndex < book.spine.count
        else { return nil }
        let resourceID = book.spine[spineIndex]
        guard let resource = book.resourcesByID[resourceID] else { return nil }
        return book.absoluteURL(for: resource)
    }

    /// Human-readable title of the current chapter for the toolbar.
    /// Prefers the TOC's title when the current spine index has
    /// one; falls back to the filename stem otherwise.
    var currentChapterLabel: String {
        if let entry = toc.entries.first(where: { $0.spineIndex == spineIndex }) {
            return entry.title
        }
        guard let book, !book.spine.isEmpty,
              spineIndex >= 0, spineIndex < book.spine.count
        else { return "" }
        let resourceID = book.spine[spineIndex]
        if let resource = book.resourcesByID[resourceID] {
            return (resource.hrefRelativeToOPF as NSString)
                .lastPathComponent
                .replacingOccurrences(of: ".xhtml", with: "")
                .replacingOccurrences(of: ".html", with: "")
        }
        return "Chapter \(spineIndex + 1)"
    }

    var canGoPrevious: Bool {
        guard let book else { return false }
        return !book.spine.isEmpty && spineIndex > 0
    }

    var canGoNext: Bool {
        guard let book else { return false }
        return !book.spine.isEmpty && spineIndex < book.spine.count - 1
    }

    func previousChapter() {
        guard canGoPrevious else { return }
        userHasNavigated = true
        spineIndex -= 1
        reloadTrigger += 1
        persistCurrentPosition()
    }

    func nextChapter() {
        guard canGoNext else { return }
        userHasNavigated = true
        spineIndex += 1
        reloadTrigger += 1
        persistCurrentPosition()
    }

    /// Jump to an arbitrary spine index. Clamped to the valid range
    /// so a stale TOC entry or restored position past the spine end
    /// lands somewhere sensible rather than crashing. Bumps the
    /// reload trigger so the WKWebView re-loads even when the
    /// target is the current chapter (used by "Start of Chapter"
    /// scroll-reset behavior).
    func jump(toSpineIndex idx: Int) {
        guard let book, !book.spine.isEmpty else { return }
        let clamped = max(0, min(idx, book.spine.count - 1))
        userHasNavigated = true
        spineIndex = clamped
        reloadTrigger += 1
        // Clear any pending paragraph anchor — the user is doing
        // a chapter-top jump (TOC click, prev/next), not a
        // citation tap.
        pendingScrollAnchor = nil
        persistCurrentPosition()
    }

    /// Jump to a specific paragraph in a chapter — used by chat
    /// citation chips that carry a `paragraphIndex`. Loads the
    /// chapter if it isn't already current, then queues a
    /// scroll-to-anchor request that `WebReaderPane`'s coordinator
    /// flushes once the page finishes loading. Anchor format
    /// matches `XHTMLWriter`'s `hu-p-{chapterIdx}-{paragraphIdx}`
    /// convention. Third-party EPUBs without the anchor land
    /// silently at the chapter top.
    func jumpToParagraph(chapterIdx: Int, paragraphIdx: Int) {
        guard let book, !book.spine.isEmpty else { return }
        let clamped = max(0, min(chapterIdx, book.spine.count - 1))
        userHasNavigated = true
        let anchorID = "hu-p-\(clamped)-\(paragraphIdx)"
        if spineIndex != clamped {
            spineIndex = clamped
            reloadTrigger += 1
        }
        // Set the pending anchor either way — for same-chapter
        // taps the WKWebView is already loaded and the
        // coordinator flushes immediately; for cross-chapter
        // taps the load-finish handler picks it up.
        pendingScrollAnchor = ScrollAnchor(
            spineIndex: clamped,
            elementID: anchorID,
            nonce: UUID()
        )
        persistCurrentPosition()
    }

    /// Window title shown in the toolbar / titlebar.
    var displayTitle: String {
        book?.displayTitle ?? epubURL.deletingPathExtension().lastPathComponent
    }

    // MARK: - Chat

    /// Build the chat VM on first show. Same pattern as the
    /// editor's `EditorViewModel.ensureChatViewModel`, with one
    /// difference: scope is locked to `.currentBook` and never
    /// flipped. The reader's chat is intentionally focused on the
    /// open book — library-scope chat lives in the Library window
    /// where its full UI (federated index status, exclusion list,
    /// per-collection scoping) makes sense.
    func ensureChatViewModel() {
        guard chatViewModel == nil, let book = book else { return }
        let vm = BookChatViewModel(book: book, epubURL: epubURL)
        // Locked scope — even if a future code path flips this,
        // ReaderChatPaneView doesn't show the scope picker so the
        // user can't toggle it from the reader. Per-book embedding
        // index builds on first send; library federation never
        // engages.
        vm.chatScope = .currentBook
        vm.library = OpenRouter.library
        chatViewModel = vm
    }
}
