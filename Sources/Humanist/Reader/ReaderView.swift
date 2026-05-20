import SwiftUI
import AppKit
import WebKit
import EPUB

/// R-Reader. Standalone EPUB reading window. NavigationSplitView
/// with a stub TOC sidebar + a single-column scrolling chapter
/// pane backed by WKWebView. Commit 1 ships the skeleton; later
/// commits in the phase wire real TOC titles, default-open
/// routing, and reading-position persistence.
struct ReaderView: View {
    /// Bounds for the reader's font-size stepper. Local to the
    /// reader for now; the editor's preview has its own picker
    /// without bounds so we don't share constants.
    static let fontSizeMin: Double = 10
    static let fontSizeMax: Double = 36

    let epubURL: URL

    @StateObject private var vm: ReaderViewModel
    @Environment(\.openWindow) private var openWindow
    /// Font-size preference for the chapter pane. Shared with the
    /// editor's preview pane keys so adjustments in either surface
    /// stay consistent. Persisted via @AppStorage.
    @AppStorage(EditorSettingsKeys.previewFontSize)
    private var fontSize: Double = EditorSettingsDefaults.previewFontSize

    init(epubURL: URL) {
        self.epubURL = epubURL
        _vm = StateObject(wrappedValue: ReaderViewModel(epubURL: epubURL))
    }

    var body: some View {
        Group {
            switch vm.state {
            case .loading:
                ProgressView("Opening \(epubURL.lastPathComponent)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                failureView(message)
            case .ready:
                if let book = vm.book {
                    readyBody(book: book)
                } else {
                    failureView("Reader is ready but no book was loaded.")
                }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .humanistChrome()
    }

    // MARK: - Ready body

    @ViewBuilder
    private func readyBody(book: EPUBBook) -> some View {
        NavigationSplitView {
            tocSidebar(book: book)
                .frame(minWidth: 200, idealWidth: 240)
        } detail: {
            detailPane(book: book)
        }
        .navigationTitle(vm.displayTitle)
        .navigationSubtitle(vm.currentChapterLabel)
        .toolbar { toolbarContent }
    }

    /// Detail column. Always shows the reading pane; adds the
    /// chat pane on the right when `vm.showChatPane` is on. Uses
    /// HSplitView so the user can drag the divider — matches the
    /// editor's pane behavior.
    @ViewBuilder
    private func detailPane(book: EPUBBook) -> some View {
        if vm.showChatPane, let chatVM = vm.chatViewModel {
            HSplitView {
                readingPane(book: book)
                    .frame(minWidth: 360)
                ReaderChatPaneView(
                    vm: chatVM,
                    onCitationTap: { citation in
                        // Tap a citation chip → snap the reading
                        // pane to the cited chapter. Library-scope
                        // citations (which carry a bookEpubURL)
                        // can't appear in reader chat because
                        // scope is locked to .currentBook on the
                        // VM, but defend anyway: only navigate
                        // when the citation targets this book.
                        guard citation.bookEpubURL == nil else { return }
                        if let paraIdx = citation.paragraphIndex {
                            vm.jumpToParagraph(
                                chapterIdx: citation.chapterIndex,
                                paragraphIdx: paraIdx
                            )
                        } else {
                            vm.jump(toSpineIndex: citation.chapterIndex)
                        }
                    }
                )
                .frame(minWidth: 320, idealWidth: 380)
            }
        } else {
            readingPane(book: book)
        }
    }

    /// TOC sidebar. Titles come from `ReaderTOC.build` — preferring
    /// the EPUB's `nav.xhtml` when present, falling back to per-
    /// spine-item `<title>` / first heading / filename otherwise.
    /// Always-flat list for v1; sub-section hierarchy lands in v2
    /// of the reader.
    @ViewBuilder
    private func tocSidebar(book: EPUBBook) -> some View {
        let entries = vm.toc.entries
        List(selection: Binding(
            get: { vm.spineIndex },
            set: { if let new = $0 { vm.jump(toSpineIndex: new) } }
        )) {
            ForEach(entries) { entry in
                Text(entry.title)
                    .lineLimit(2)
                    .tag(Optional(entry.spineIndex))
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func readingPane(book: EPUBBook) -> some View {
        if let chapterURL = vm.currentChapterURL {
            // Only pass the anchor / fraction through when it
            // targets the currently-loaded spine index — otherwise
            // the WKWebView would try to scroll the wrong chapter's
            // DOM. The VM updates spineIndex first, so by the time
            // updateNSView runs the target's spineIndex matches.
            let anchor: ReaderViewModel.ScrollAnchor? = {
                guard let a = vm.pendingScrollAnchor,
                      a.spineIndex == vm.spineIndex
                else { return nil }
                return a
            }()
            let fractionReq: ReaderViewModel.ScrollFractionRequest? = {
                guard let f = vm.pendingScrollFraction,
                      f.spineIndex == vm.spineIndex
                else { return nil }
                return f
            }()
            WebReaderPane(
                url: chapterURL,
                accessRoot: book.workingDirectory,
                reloadTrigger: vm.reloadTrigger,
                fontSize: fontSize,
                scrollAnchor: anchor,
                scrollFraction: fractionReq,
                onScrollUpdate: { fraction in
                    vm.didReportScrollFraction(fraction)
                }
            )
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "book.closed")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("This book has no readable chapters.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Could not open EPUB").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { vm.previousChapter() } label: {
                Label("Previous Chapter", systemImage: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!vm.canGoPrevious)

            Button { vm.nextChapter() } label: {
                Label("Next Chapter", systemImage: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!vm.canGoNext)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 4) {
                Button {
                    fontSize = max(Self.fontSizeMin,
                                   fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("Decrease font size")
                .disabled(fontSize <= Self.fontSizeMin)

                Text("\(Int(fontSize))")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 22)

                Button {
                    fontSize = min(Self.fontSizeMax,
                                   fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("Increase font size")
                .disabled(fontSize >= Self.fontSizeMax)
            }

            Button {
                vm.showChatPane.toggle()
            } label: {
                Label(
                    "Chat",
                    systemImage: vm.showChatPane
                        ? "bubble.left.and.text.bubble.right.fill"
                        : "bubble.left.and.text.bubble.right"
                )
            }
            .help(vm.showChatPane
                  ? "Hide chat sidebar (⌥⌘C)"
                  : "Chat with this book (⌥⌘C)")
            .keyboardShortcut("c", modifiers: [.command, .option])

            Button {
                openWindow(id: "editor", value: epubURL)
            } label: {
                Label("Edit Source…", systemImage: "pencil")
            }
            .help("Open this book in the Editor (⌥⌘O)")
            .keyboardShortcut("o", modifiers: [.command, .option])
        }
    }
}

// MARK: - WKWebView reader pane

/// Minimal WKWebView wrapper for the reader's chapter pane. Far
/// simpler than the editor's `PreviewView` — no IntersectionObserver
/// bridge, no anchor-scroll requests, no JS message channel. Reads
/// the chapter file URL with the EPUB's working directory as the
/// allowed-access root so relative CSS / image references resolve.
///
/// Font-size injection lives in a tiny `<style id="humanist-reader-
/// override">` element added on `didFinish`. Re-injecting on every
/// load keeps the override consistent across chapter changes.
private struct WebReaderPane: NSViewRepresentable {
    let url: URL
    let accessRoot: URL
    let reloadTrigger: Int
    let fontSize: Double
    /// Optional scroll target — when the spine index matches this
    /// pane's chapter and the nonce hasn't been flushed yet, scroll
    /// the WKWebView to the matching element id after load (or
    /// immediately if already loaded).
    var scrollAnchor: ReaderViewModel.ScrollAnchor? = nil
    /// Optional scroll-fraction restore target. Same shape as
    /// `scrollAnchor` but targets a normalized position
    /// (0.0–1.0) instead of an element id — used by the
    /// position-persistence path so reopening a book lands at
    /// the exact spot you stopped reading.
    var scrollFraction: ReaderViewModel.ScrollFractionRequest? = nil
    /// Live scroll-position callback. The injected JS posts
    /// `{type: "scroll", fraction: 0.42}` on each scroll event;
    /// this callback fires on the main actor with the new
    /// fraction. Caller debounces persistence.
    var onScrollUpdate: ((Double) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "reader")
        // Inject the scroll-tracking script at document end so it
        // runs once the body exists. No-op on documents without
        // a scrollable body.
        userContent.addUserScript(WKUserScript(
            source: Self.scrollBridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        cfg.userContentController = userContent
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.fontSize = fontSize
        context.coordinator.onScrollUpdate = onScrollUpdate
        load(into: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.fontSize = fontSize
        context.coordinator.onScrollUpdate = onScrollUpdate
        load(into: nsView, coordinator: context.coordinator)
        context.coordinator.applyFontSizeIfReady(view: nsView)
        // Stash the most recent pending anchor; the coordinator
        // flushes it either right now (page already loaded) or on
        // the next didFinish (load in flight).
        if let anchor = scrollAnchor,
           context.coordinator.lastFlushedAnchorNonce != anchor.nonce {
            context.coordinator.pendingAnchorID = anchor.elementID
            context.coordinator.pendingAnchorNonce = anchor.nonce
            context.coordinator.flushPendingAnchorIfReady(view: nsView)
        }
        if let req = scrollFraction,
           context.coordinator.lastFlushedFractionNonce != req.nonce {
            context.coordinator.pendingFraction = req.fraction
            context.coordinator.pendingFractionNonce = req.nonce
            context.coordinator.flushPendingFractionIfReady(view: nsView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// JS injected on every chapter load. Tracks scroll position
    /// + posts it on a debounce so the Swift side gets one
    /// message per ~250ms of quiet instead of one per wheel
    /// tick. Posts `0` for pages that aren't scrollable
    /// (`scrollMaxY <= 0`) so the Swift side knows the chapter
    /// is fully visible without scrolling.
    private static let scrollBridgeJS = """
    (function() {
      var pending = false;
      function post() {
        try {
          var maxY = (document.documentElement.scrollHeight
                      - document.documentElement.clientHeight);
          var f = 0;
          if (maxY > 0) { f = window.scrollY / maxY; }
          if (window.webkit
              && window.webkit.messageHandlers
              && window.webkit.messageHandlers.reader) {
            window.webkit.messageHandlers.reader.postMessage({
              type: 'scroll', fraction: f,
            });
          }
        } catch (e) {}
      }
      function schedulePost() {
        if (pending) return;
        pending = true;
        setTimeout(function() { pending = false; post(); }, 250);
      }
      window.addEventListener('scroll', schedulePost, { passive: true });
      // Fire one immediately so the Swift side knows the
      // starting position (typically 0 unless restored).
      post();
    })();
    """

    private func load(into view: WKWebView, coordinator: Coordinator? = nil) {
        let resolvedURL = url.canonicalForFile
        let resolvedAccess = accessRoot.canonicalForFile
        let coord = coordinator ?? (view.navigationDelegate as? Coordinator)
        let urlChanged = coord?.loadedURL != resolvedURL
        let triggerChanged = coord?.loadedTrigger != reloadTrigger
        guard urlChanged || triggerChanged else { return }
        coord?.loadedURL = resolvedURL
        coord?.loadedTrigger = reloadTrigger
        // Reset isLoaded so a queued anchor doesn't try to flush
        // against the previous chapter's DOM while the new one
        // is loading. `didFinish` re-sets it after the next
        // navigation completes.
        coord?.isLoaded = false
        view.stopLoading()
        view.loadFileURL(resolvedURL, allowingReadAccessTo: resolvedAccess)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedURL: URL?
        var loadedTrigger: Int = -1
        var fontSize: Double = EditorSettingsDefaults.previewFontSize
        weak var lastFinishedView: WKWebView?
        /// Pending anchor id to scroll to. Set by `updateNSView`
        /// from the binding; flushed by `didFinish` once the
        /// page is loaded, or immediately by
        /// `flushPendingAnchorIfReady` when the load already
        /// completed (same-chapter citation taps).
        var pendingAnchorID: String?
        /// Nonce of the in-flight anchor request. Stored
        /// post-flush as `lastFlushedAnchorNonce` so identical
        /// repeat-tap requests skip re-flushing.
        var pendingAnchorNonce: UUID?
        /// Nonce of the most recently flushed anchor request.
        /// `updateNSView` compares against the binding's nonce
        /// to decide whether a new scroll should fire.
        var lastFlushedAnchorNonce: UUID?
        /// Pending scroll-fraction restore (0.0–1.0). Same shape
        /// as the anchor pair above; flushed by `didFinish` or
        /// `flushPendingFractionIfReady`.
        var pendingFraction: Double?
        var pendingFractionNonce: UUID?
        var lastFlushedFractionNonce: UUID?
        /// True once the WKWebView's didFinish has fired for the
        /// current `loadedURL`. Until then, anchor flushes get
        /// deferred — `getElementById` would otherwise return
        /// null before the document is parsed.
        var isLoaded: Bool = false
        /// Live scroll-update callback. Fires on the main actor
        /// with the new fraction each time the JS bridge posts
        /// a scroll event. nil → ignore (no listener wired).
        var onScrollUpdate: ((Double) -> Void)?
        /// True while we're programmatically scrolling (anchor
        /// flush or fraction restore). The JS bridge can fire
        /// a scroll event from the scrollIntoView itself, which
        /// would otherwise feed back as "user scrolled to here"
        /// and persist the restored position immediately.
        var suppressScrollReports: Bool = false

        nonisolated func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastFinishedView = webView
                self.isLoaded = true
                self.applyFontSizeIfReady(view: webView)
                self.flushPendingAnchorIfReady(view: webView)
                self.flushPendingFractionIfReady(view: webView)
            }
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "reader",
                  let dict = message.body as? [String: Any],
                  (dict["type"] as? String) == "scroll",
                  let fraction = dict["fraction"] as? Double else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Filter out programmatic-scroll feedback. The
                // JS bridge fires immediately after a restore,
                // which we don't want to interpret as a user-
                // initiated change.
                if self.suppressScrollReports { return }
                self.onScrollUpdate?(fraction)
            }
        }

        /// Inject (or update) the `<style id="humanist-reader-override">`
        /// element with the current font size. Idempotent — running
        /// twice with the same value is cheap and a no-op visually.
        func applyFontSizeIfReady(view: WKWebView) {
            guard view.url != nil else { return }
            let css = "body { font-size: \(Int(fontSize))px !important; }"
            let js = """
            (function() {
              var s = document.getElementById('humanist-reader-override');
              if (!s) {
                s = document.createElement('style');
                s.id = 'humanist-reader-override';
                document.head.appendChild(s);
              }
              s.textContent = \(stringLiteral(css));
            })();
            """
            view.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Scroll the WKWebView to the element with id
        /// `pendingAnchorID` if the page has finished loading.
        /// Otherwise no-op — `didFinish` calls back into this
        /// method once the document parses. `getElementById`
        /// returning null (the EPUB lacks our `hu-p-*` anchors)
        /// is treated as a silent miss; same posture as the
        /// editor's preview pane.
        func flushPendingAnchorIfReady(view: WKWebView) {
            guard isLoaded,
                  let anchorID = pendingAnchorID,
                  let nonce = pendingAnchorNonce,
                  lastFlushedAnchorNonce != nonce
            else { return }
            let escaped = stringLiteral(anchorID)
            // Smooth scroll into view, biased toward the top so
            // the user lands above the fold even when the
            // surrounding paragraphs occupy the viewport.
            let js = """
            (function() {
              var el = document.getElementById(\(escaped));
              if (el) {
                el.scrollIntoView({ behavior: 'smooth', block: 'start' });
              }
            })();
            """
            // Suppress feedback for ~1s — the smooth scroll
            // generates intermediate scroll events that would
            // otherwise be interpreted as user scrolls.
            suppressScrollReports = true
            view.evaluateJavaScript(js, completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.suppressScrollReports = false
            }
            lastFlushedAnchorNonce = nonce
            pendingAnchorID = nil
            pendingAnchorNonce = nil
        }

        /// Restore a saved sub-chapter scroll position. Computes
        /// the target Y from the fraction × document height
        /// and jumps the WKWebView there. Like the anchor flush,
        /// silently no-ops on documents with `scrollMaxY == 0`
        /// (chapters that fit in the viewport).
        func flushPendingFractionIfReady(view: WKWebView) {
            guard isLoaded,
                  let fraction = pendingFraction,
                  let nonce = pendingFractionNonce,
                  lastFlushedFractionNonce != nonce
            else { return }
            let js = """
            (function() {
              var maxY = (document.documentElement.scrollHeight
                          - document.documentElement.clientHeight);
              if (maxY > 0) {
                window.scrollTo({
                  top: \(fraction) * maxY,
                  behavior: 'auto'
                });
              }
            })();
            """
            // Same suppression as anchor flush — the programmatic
            // scrollTo emits a scroll event we don't want to
            // mis-interpret.
            suppressScrollReports = true
            view.evaluateJavaScript(js, completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.suppressScrollReports = false
            }
            lastFlushedFractionNonce = nonce
            pendingFraction = nil
            pendingFractionNonce = nil
        }

        /// Turn a Swift String into a safely-escaped JS string
        /// literal. Avoids the brittleness of hand-escaping quotes
        /// across two languages.
        private func stringLiteral(_ s: String) -> String {
            let data = (try? JSONSerialization.data(
                withJSONObject: [s], options: []
            )) ?? Data("[\"\"]".utf8)
            let str = String(data: data, encoding: .utf8) ?? "[\"\"]"
            return String(str.dropFirst().dropLast())
        }
    }
}
