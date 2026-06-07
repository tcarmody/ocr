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

    /// Current scroll fraction inside the active chapter
    /// (0.0 = top, 1.0 = bottom). Updated live by
    /// `WebReaderPane`'s JS bridge as the user scrolls.
    /// Persisted to `ReadingPositionStore` on a debounce so the
    /// next reopen restores both the chapter AND the position
    /// within it.
    @Published private(set) var scrollFraction: Double = 0

    /// Pending scroll-fraction request for a chapter load.
    /// Set by `restorePositionIfAvailable` after the user's
    /// saved position is read off disk; consumed by
    /// `WebReaderPane` once the chapter's WKWebView finishes
    /// loading, then cleared. Same nonce-tagged shape as
    /// `pendingScrollAnchor` so identical re-requests still
    /// fire (defensive — restore only happens once per open).
    @Published var pendingScrollFraction: ScrollFractionRequest?

    /// Scroll fraction restore request keyed by spine index +
    /// target fraction. Nonce-tagged for the same reason as
    /// `ScrollAnchor`.
    struct ScrollFractionRequest: Equatable {
        let spineIndex: Int
        let fraction: Double
        let nonce: UUID
    }

    /// In-memory cache of the book's annotations (bookmarks +
    /// highlights + passages). Loaded after the content hash
    /// resolves; mutated by the bookmark / highlight / note
    /// actions; written back to `AnnotationStore` on every
    /// change so a window close mid-edit doesn't lose work.
    @Published private(set) var annotations: [Annotation] = []

    /// Paginated-layout toggle. When on, the WKWebView applies a
    /// CSS `column-width: 100vw` layout to the loaded chapter and
    /// the reader navigates by pages instead of scrolling. Off
    /// (default) keeps the original vertical-scroll behavior.
    /// Persisted globally so a user who prefers paginated mode
    /// gets it on every book open.
    @Published var isPaginated: Bool {
        didSet {
            UserDefaults.standard.set(
                isPaginated, forKey: Self.paginatedKey
            )
            // Reset page state on toggle; the JS bridge re-reports
            // these once it applies / removes the CSS.
            currentPage = 0
            pageCount = 0
        }
    }
    private static let paginatedKey = "humanist.reader.paginated"

    /// Current page in the active chapter (0-based). Updated by
    /// the JS pagination bridge each time the user advances a
    /// page or the chapter re-paginates after a window resize.
    /// Meaningful only in paginated mode.
    @Published private(set) var currentPage: Int = 0
    /// Total pages in the active chapter (paginated mode). 0 means
    /// "not yet measured" (chapter still loading or scroll mode).
    @Published private(set) var pageCount: Int = 0

    /// Set when the editor saves this book while the reader is
    /// open. Drives the "Book changed on disk — Reload" banner
    /// so the user can refresh on their own schedule rather
    /// than getting auto-yanked mid-paragraph.
    @Published var bookChangedOnDisk: Bool = false

    /// Token from the NotificationCenter observer set up in
    /// `init` for `.humanistEPUBSavedFromEditor`. Removed in
    /// deinit so a closed reader doesn't keep a dangling
    /// observer hanging around. `nonisolated(unsafe)` because
    /// the token is opaque (NSObjectProtocol), only touched in
    /// init + deinit, and never races with the main-actor
    /// notification callback — same posture as
    /// `BookChatViewModel.backendChangeObserver`.
    private nonisolated(unsafe) var editorSaveObserver: (any NSObjectProtocol)?
    /// Observer token for `.humanistOpenAtParagraph` — fires when
    /// a library-scope chat citation tap routes through
    /// `OpenRouter.openInReader`. Same lifecycle posture as
    /// `editorSaveObserver`.
    private nonisolated(unsafe) var paragraphJumpObserver: (any NSObjectProtocol)?
    /// Buffered jump request the reader stashes when the
    /// `.humanistOpenAtParagraph` notification arrives BEFORE
    /// `load()` finishes — newly-spawned reader windows can't run
    /// `jumpToParagraph` until `book` is non-nil, so we hold the
    /// request and apply it at the end of `load()`. Nil once
    /// consumed (or when no jump is queued).
    private var pendingParagraphJump: (chapterIdx: Int, paragraphIdx: Int)?
    /// Pending page-navigation request — caught by `WebReaderPane`
    /// and translated into a JS call. Nonce-tagged so repeat
    /// presses on the same button re-fire instead of being
    /// coalesced as a duplicate value.
    @Published var pageNavRequest: PageNavRequest?

    /// One page-navigation action. `direction` semantics:
    ///   * `.next`: go forward one page, or to the next chapter's
    ///     first page when already on the last page of the
    ///     current chapter.
    ///   * `.previous`: mirror — back one page, or to the
    ///     previous chapter's last page.
    ///   * `.toPage(N)`: absolute jump within the current
    ///     chapter (used by position restore).
    struct PageNavRequest: Equatable {
        let direction: Direction
        let nonce: UUID
        enum Direction: Equatable {
            case next, previous, toPage(Int)
        }
    }

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

    /// Stable storage key for this book's annotations. Derived from the
    /// EPUB's package identifier when present (so marks survive the
    /// content-hash churn of editor saves / re-OCR), else the content
    /// hash. Resolved alongside `contentHash` in
    /// `restorePositionIfAvailable`; `nil` until then. See
    /// `AnnotationKey`.
    private var annotationStoreKey: String?

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
        self.isPaginated = UserDefaults.standard
            .bool(forKey: Self.paginatedKey)
        // Listen for editor saves on this same URL. The
        // notification's userInfo carries the saved URL; we
        // only flip the banner flag when it matches ours.
        // Canonical-path compare to handle the /var ↔ /private/var
        // symlink quirk that bites cross-process URL comparisons.
        let watchedURL = epubURL.canonicalForFile
        self.editorSaveObserver = NotificationCenter.default
            .addObserver(
                forName: .humanistEPUBSavedFromEditor,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let saved = notification.userInfo?["url"] as? URL
                else { return }
                if saved.canonicalForFile == watchedURL {
                    Task { @MainActor in
                        self.bookChangedOnDisk = true
                    }
                }
            }
        // Citation-tap hand-off observer. When a chat citation
        // routes through OpenRouter.openInReader, the matching
        // reader window's VM either jumps immediately (book
        // already loaded) or stashes the request for load() to
        // consume.
        self.paragraphJumpObserver = NotificationCenter.default
            .addObserver(
                forName: .humanistOpenAtParagraph,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let target = notification.userInfo?["url"] as? URL,
                      target.canonicalForFile == watchedURL,
                      let chapter = notification.userInfo?["chapter"] as? Int,
                      let paragraph = notification.userInfo?["paragraph"] as? Int
                else { return }
                Task { @MainActor in
                    if self.book != nil {
                        self.jumpToParagraph(
                            chapterIdx: chapter, paragraphIdx: paragraph
                        )
                    } else {
                        self.pendingParagraphJump = (chapter, paragraph)
                    }
                }
            }
        Task { await load() }
    }

    deinit {
        if let observer = editorSaveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = paragraphJumpObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        scrollPersistTask?.cancel()
    }

    /// Reload the EPUB from disk after the editor saved over
    /// it. Re-opens via `EPUBBook.open` (which re-unzips the
    /// freshly-written file), refreshes the TOC + annotations,
    /// keeps the current spineIndex when valid, clears the
    /// stale-on-disk banner. Reading position within the
    /// chapter is preserved through the live `scrollFraction`
    /// (the bridge re-reports after the reload).
    func reloadFromDisk() async {
        let url = epubURL
        let previousSpineIndex = spineIndex
        do {
            let opened = try await Task.detached(priority: .userInitiated) {
                try EPUBBook.open(epubURL: url)
            }.value
            self.book = opened
            self.toc = ReaderTOC.build(from: opened)
            // Preserve the user's chapter when the new spine
            // still has it; otherwise clamp to the new spine
            // length.
            if !opened.spine.isEmpty {
                self.spineIndex = max(
                    0, min(previousSpineIndex, opened.spine.count - 1)
                )
            } else {
                self.spineIndex = 0
            }
            self.reloadTrigger += 1
            self.bookChangedOnDisk = false
            // Re-pull annotations under the stable key. The editor's
            // save changes the content hash but not the book identity,
            // so the marks key is unaffected; a sync conflict could
            // still rewrite the sidecar, hence the refresh.
            if let key = self.annotationStoreKey {
                self.annotations = AnnotationStore.load(
                    forContentHash: key
                ).annotations
            }
        } catch {
            // Leave the banner up so the user knows the reload
            // didn't take. A re-open from the Library row is
            // the recovery path.
            NSLog(
                "Humanist: reader reload-from-disk failed: %@",
                error.localizedDescription
            )
        }
    }

    // MARK: - Pagination

    /// Advance the WKWebView's pagination by one page, or roll
    /// over to the next chapter's first page when already on
    /// the last page. Bumps the nonce so consecutive ⌘→ /
    /// space presses each fire individually instead of being
    /// coalesced. Caller (WebReaderPane / ReaderView) gates on
    /// `isPaginated` before invoking.
    func nextPage() {
        // Roll over at the last page — `pageCount` of 0 means
        // "not measured yet," in which case we let the JS
        // bridge handle the no-op via clamp.
        if pageCount > 0 && currentPage >= pageCount - 1 {
            if canGoNext { nextChapter() }
            return
        }
        pageNavRequest = PageNavRequest(direction: .next, nonce: UUID())
    }

    func previousPage() {
        if currentPage <= 0 {
            if canGoPrevious {
                // Going back into the previous chapter: queue a
                // "jump to last page once measured" request via
                // a pending-page flag the JS bridge consumes on
                // didFinish. For v1 just open at chapter top —
                // the user can press ← again to keep paging.
                previousChapter()
            }
            return
        }
        pageNavRequest = PageNavRequest(
            direction: .previous, nonce: UUID()
        )
    }

    /// JS-bridge callback when the chapter's pagination
    /// measures or re-measures (initial load, window resize).
    /// Updates the published `currentPage` + `pageCount` so the
    /// toolbar's "page X of Y" indicator stays accurate.
    func didReportPagination(currentPage: Int, pageCount: Int) {
        self.currentPage = max(0, currentPage)
        self.pageCount = max(0, pageCount)
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
            // Citation-tap hand-off: if a humanistOpenAtParagraph
            // notification arrived between init and load() finish
            // (the common case when the reader was freshly
            // spawned by a chat tap), apply the queued jump now
            // that `book` is non-nil. Consumed in this block so a
            // later restore can't replay it.
            if let pending = pendingParagraphJump {
                pendingParagraphJump = nil
                jumpToParagraph(
                    chapterIdx: pending.chapterIdx,
                    paragraphIdx: pending.paragraphIdx
                )
            } else {
                // No queued jump → restore the user's saved
                // reading position. We skip restore when a chat
                // hand-off is in flight so the citation lands on
                // the cited paragraph instead of bouncing to the
                // user's bookmark.
                await restorePositionIfAvailable()
            }
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
        // Stamp the hash onto the library row so the Library
        // window's reading-progress column can find this
        // book's saved position without re-hashing the EPUB.
        // No-op when the book isn't in the catalog.
        OpenRouter.library?.recordEPUBContentHash(
            hash, forEPUB: url
        )
        // Resolve the stable annotation key (book identity, not file
        // bytes) and load marks under it. One-time migration: a book
        // whose marks still live under the legacy content-hash key gets
        // them adopted into the stable key on first open, so an editor
        // save no longer orphans them.
        let key = AnnotationKey.resolve(
            bookID: self.book?.metadata.bookID, contentHash: hash
        )
        self.annotationStoreKey = key
        var bundle = AnnotationStore.load(forContentHash: key)
        if bundle.annotations.isEmpty, key != hash {
            let legacy = AnnotationStore.load(forContentHash: hash)
            if !legacy.annotations.isEmpty {
                bundle = AnnotationsBundle(
                    contentHash: key, annotations: legacy.annotations
                )
                AnnotationStore.save(bundle)
            }
        }
        self.annotations = bundle.annotations
        guard !userHasNavigated else { return }
        guard let saved = ReadingPositionStore.load(
            forContentHash: hash
        ) else { return }
        guard !userHasNavigated else { return }
        // Jump to the saved spine index unless we're already
        // there (chapter 0). Either way, queue a scroll-
        // fraction request so the WebReaderPane scrolls to the
        // saved sub-chapter offset on load — fully restores
        // "where I was reading," not just which chapter.
        if saved.spineIndex > 0 && saved.spineIndex != spineIndex {
            spineIndex = saved.spineIndex
            reloadTrigger += 1
        }
        // Skip the scroll-restore step when the saved fraction
        // is at or near the top — no point in firing a
        // scrollTo(0) and reset the chapter's natural starting
        // viewport.
        if saved.scrollFraction > 0.01 {
            pendingScrollFraction = ScrollFractionRequest(
                spineIndex: saved.spineIndex,
                fraction: saved.scrollFraction,
                nonce: UUID()
            )
        }
        // Seed the live fraction so a subsequent navigation-
        // triggered persist doesn't write 0 before the JS
        // bridge has reported the restored position.
        scrollFraction = saved.scrollFraction
    }

    /// Persist the current position to the store. Called from
    /// every spine-changing path (`previousChapter`,
    /// `nextChapter`, `jump`) and from the scroll-update path
    /// (debounced). Writes are cheap (one tiny JSON file).
    private func persistCurrentPosition() {
        guard let hash = contentHash else { return }
        let position = ReadingPosition(
            contentHash: hash,
            spineIndex: spineIndex,
            scrollFraction: scrollFraction,
            updatedAt: Date()
        )
        // Hop off the main actor — disk I/O shouldn't block the
        // chapter-change repaint, however cheap.
        Task.detached(priority: .utility) {
            ReadingPositionStore.save(position)
        }
    }

    /// Debounce timer for scroll-position writes. The WKWebView
    /// fires scroll events at ~60 Hz; we coalesce into one
    /// disk write per ~750ms of quiet so the SSD isn't being
    /// hammered on every wheel tick.
    private var scrollPersistTask: Task<Void, Never>?

    /// JS-side scroll bridge callback. Called every time the
    /// reader's WKWebView reports a new scroll fraction.
    /// Updates the live `scrollFraction` and schedules a
    /// debounced persistence write.
    func didReportScrollFraction(_ fraction: Double) {
        // Clamp defensively — JS can occasionally report
        // negatives during overscroll and >1 during bouncing.
        let clamped = max(0, min(1, fraction))
        scrollFraction = clamped
        // Don't persist sub-chapter scroll until the user has
        // explicitly navigated this session — otherwise the
        // first auto-scroll during chapter load would clobber
        // their saved position with 0.
        guard userHasNavigated else { return }
        scrollPersistTask?.cancel()
        scrollPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.persistCurrentPosition()
            }
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
        scrollFraction = 0
        pendingScrollAnchor = nil
        pendingScrollFraction = nil
        persistCurrentPosition()
    }

    func nextChapter() {
        guard canGoNext else { return }
        userHasNavigated = true
        spineIndex += 1
        reloadTrigger += 1
        scrollFraction = 0
        pendingScrollAnchor = nil
        pendingScrollFraction = nil
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
        pendingScrollFraction = nil
        // New chapter starts at the top; the JS bridge will
        // confirm via a scroll-event once the page loads.
        scrollFraction = 0
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

    // MARK: - Annotations

    /// Add a bookmark at the given paragraph anchor.
    /// `paragraphAnchorId` carries the `hu-p-N-M` id from the
    /// reader pane's JS capture; nil → bookmark the chapter
    /// itself (third-party EPUBs without anchors). Persists
    /// immediately + updates the in-memory list.
    func addBookmark(
        chapterIdx: Int, paragraphAnchorId: String?
    ) {
        guard annotationStoreKey != nil else { return }
        let bookmark = Annotation(
            chapterIdx: chapterIdx,
            paragraphAnchorId: paragraphAnchorId,
            kind: .bookmark
        )
        annotations.append(bookmark)
        persistAnnotations()
    }

    /// Persist the current in-memory `annotations` array as the
    /// whole per-book bundle. The in-memory list is the single
    /// source of truth; the store just mirrors it to disk. (We
    /// used to load → mutate → save per change, which kept two
    /// copies in lockstep and risked a disk-derived write
    /// clobbering in-memory state.) No-op until the stable annotation
    /// key has resolved.
    private func persistAnnotations() {
        guard let key = annotationStoreKey else { return }
        AnnotationStore.save(
            AnnotationsBundle(contentHash: key, annotations: annotations)
        )
    }

    /// Add a highlight at the given selection. Used by Phase D
    /// (highlight gesture). `selectedText` is the verbatim
    /// selection; `selectionRange` is the character-offset
    /// fallback for restore when the text gets edited away.
    /// The caller may pass a pre-minted `id` when it has
    /// already used that id elsewhere (the highlight gesture
    /// mints the id up front so the JS-wrapped span and the
    /// persisted Annotation share it for later delete-by-id);
    /// otherwise one is generated.
    @discardableResult
    func addHighlight(
        id: UUID = UUID(),
        chapterIdx: Int,
        paragraphAnchorId: String?,
        selectedText: String,
        selectionRange: Annotation.TextRange?,
        paragraphFingerprint: String? = nil
    ) -> Annotation? {
        // Guard the storage key up front (mirrors addBookmark) so we
        // never create a phantom in-memory highlight that can't be
        // persisted and silently vanishes on reload.
        guard annotationStoreKey != nil else { return nil }
        let highlight = Annotation(
            id: id,
            chapterIdx: chapterIdx,
            paragraphAnchorId: paragraphAnchorId,
            selectedText: selectedText,
            selectionRange: selectionRange,
            paragraphFingerprint: paragraphFingerprint,
            kind: .highlight
        )
        annotations.append(highlight)
        persistAnnotations()
        return highlight
    }

    /// Edit the note on an existing annotation. Setting a
    /// non-empty note on a highlight promotes it to `.passage`;
    /// clearing the note on a passage demotes back to
    /// `.highlight`. Bookmarks can also carry notes but stay
    /// `.bookmark` kind (their distinction is the anchor-only
    /// shape, not the note presence).
    func updateAnnotationNote(id: UUID, note: String?) {
        guard let idx = annotations.firstIndex(
            where: { $0.id == id }
        ) else { return }
        let trimmed = note?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        annotations[idx].note = (trimmed?.isEmpty == false)
            ? trimmed
            : nil
        annotations[idx].updatedAt = Date()
        // Promote highlight ↔ passage based on note presence.
        // Bookmarks keep their kind (anchor-only marker).
        switch annotations[idx].kind {
        case .highlight, .passage:
            annotations[idx].kind = annotations[idx].note != nil
                ? .passage
                : .highlight
        case .bookmark:
            break
        }
        persistAnnotations()
    }

    /// Drop an annotation. The reader-side renderer (Phase D)
    /// observes `annotations` and removes any visual highlight
    /// for the dropped id on next chapter re-render.
    func removeAnnotation(id: UUID) {
        annotations.removeAll { $0.id == id }
        persistAnnotations()
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
