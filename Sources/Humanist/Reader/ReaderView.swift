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
                        vm.jump(toSpineIndex: citation.chapterIndex)
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
            WebReaderPane(
                url: chapterURL,
                accessRoot: book.workingDirectory,
                reloadTrigger: vm.reloadTrigger,
                fontSize: fontSize
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

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.fontSize = fontSize
        load(into: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.fontSize = fontSize
        load(into: nsView, coordinator: context.coordinator)
        context.coordinator.applyFontSizeIfReady(view: nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func load(into view: WKWebView, coordinator: Coordinator? = nil) {
        let resolvedURL = url.canonicalForFile
        let resolvedAccess = accessRoot.canonicalForFile
        let coord = coordinator ?? (view.navigationDelegate as? Coordinator)
        let urlChanged = coord?.loadedURL != resolvedURL
        let triggerChanged = coord?.loadedTrigger != reloadTrigger
        guard urlChanged || triggerChanged else { return }
        coord?.loadedURL = resolvedURL
        coord?.loadedTrigger = reloadTrigger
        view.stopLoading()
        view.loadFileURL(resolvedURL, allowingReadAccessTo: resolvedAccess)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var loadedTrigger: Int = -1
        var fontSize: Double = EditorSettingsDefaults.previewFontSize
        weak var lastFinishedView: WKWebView?

        nonisolated func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastFinishedView = webView
                self.applyFontSizeIfReady(view: webView)
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
