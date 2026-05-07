import SwiftUI
import WebKit
import AppKit
import EPUB

/// Renders the currently selected file. Branches by file kind:
///
///   * XHTML / HTML / SVG → WKWebView with file-URL load and read
///     access scoped to the EPUB's working directory so relative CSS
///     and image references resolve.
///   * Image (png/jpg/gif/etc) → NSImage scaled to fit.
///   * Plain text / source → not handled here; the source pane shows it.
///   * Unknown binary → a placeholder.
struct PreviewView: View {
    let file: FileNode?
    let workingDirectory: URL
    /// Bumps when the on-disk copy of the current file changes (live
    /// preview write) so the underlying WebKit view reloads. Same URL
    /// + bumped trigger → `view.reload()`.
    let reloadTrigger: Int
    /// Pending "scroll the preview to this anchor" request from the
    /// linked-navigation feature (PDF page change). Nonce-tagged so a
    /// repeat request to the same anchor still fires onChange.
    let scrollRequest: EditorViewModel.AnchorScrollRequest?
    /// Reading preferences from the Settings pane — flow into the
    /// loaded XHTML via injected `<style>` overrides.
    let fontSize: Double
    let theme: String
    /// Callback fired when the JS-injected IntersectionObserver
    /// reports a new topmost-visible page anchor (back-sync from
    /// preview scroll → PDF page).
    let onAnchorVisible: ((String) -> Void)?
    /// Same shape, but for paragraph anchors (`hu-p-*`). Drives
    /// the paragraph-level source ↔ preview snap.
    let onParagraphVisible: ((String) -> Void)?

    var body: some View {
        Group {
            if let file, !file.isDirectory {
                content(for: file)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func content(for file: FileNode) -> some View {
        let ext = file.id.pathExtension.lowercased()
        if ["xhtml", "html", "htm", "svg"].contains(ext) {
            WebPreviewPane(
                url: file.id,
                accessRoot: workingDirectory,
                reloadTrigger: reloadTrigger,
                scrollRequest: scrollRequest,
                fontSize: fontSize,
                theme: theme,
                onAnchorVisible: onAnchorVisible,
                onParagraphVisible: onParagraphVisible
            )
        } else if isImage(ext) {
            ImagePreview(url: file.id)
        } else if EditorViewModel.isTextFile(file.id) {
            // Source pane already shows it; preview shows a small label.
            VStack {
                Text("Plain text").font(.headline).foregroundStyle(.secondary)
                Text("(see source pane)").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(file.name).font(.headline)
                Text("Binary file — no preview").font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "book.closed").font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Select a file in the sidebar")
                .foregroundStyle(.secondary)
        }
    }

    private func isImage(_ ext: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp"].contains(ext)
    }
}

// MARK: - WKWebView wrapper with visible diagnostics

/// Owns the load state for one WebPreview so the parent can render an
/// overlay/badge when something goes wrong. Bridges WKNavigationDelegate
/// and WKScriptMessageHandler callbacks into observable state +
/// closures the parent set up.
@MainActor
private final class WebPreviewModel: NSObject, ObservableObject,
                                     WKNavigationDelegate, WKScriptMessageHandler {
    enum Status: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published var status: Status = .idle
    var loadedURL: URL?
    /// Last `reloadTrigger` we acted on. Distinguishes "first load"
    /// from "same URL, content changed" so the live-preview reload
    /// path can call `view.reload()` instead of `loadFileURL` again.
    var loadedTrigger: Int = .min
    /// Last linked-nav scroll request nonce we honored. New request
    /// (different nonce) → re-issue the JS scroll call.
    var lastScrollNonce: Int = .min
    /// Anchor id we want to scroll to once loading completes. Set on
    /// scroll request before the page is ready; consumed in didFinish.
    var pendingScrollAnchor: String?
    /// Appearance overrides set before the page was ready. Flushed
    /// in `didFinish` once the document is loaded and queryable.
    var pendingFontSize: Double?
    var pendingTheme: String?
    /// Forwarded back to EditorViewModel when JS reports a new
    /// topmost-visible page anchor (`hu-page-*`).
    var onAnchorVisible: ((String) -> Void)?
    /// Forwarded when JS reports a new topmost-visible paragraph
    /// anchor (`hu-p-*`). Drives the source ↔ preview snap at
    /// paragraph granularity (Pass A of paragraph-level alignment).
    var onParagraphVisible: ((String) -> Void)?
    /// Reference back to the WKWebView so didFinish can run JS.
    weak var webView: WKWebView?

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.status = .loading }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.status = .loaded
            self.flushPendingScroll()
            self.flushPendingAppearance(webView: webView)
        }
    }

    func flushPendingAppearance(webView: WKWebView) {
        guard let size = pendingFontSize, let theme = pendingTheme
        else { return }
        pendingFontSize = nil
        pendingTheme = nil
        let css = WebPreview.overrideCSS(fontSize: size, theme: theme)
        let escaped = (try? JSONSerialization.data(
            withJSONObject: [css], options: []
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let cssLiteral = String(escaped.dropFirst().dropLast())
        let js = """
        (function() {
          var existing = document.getElementById('humanist-overrides');
          if (!existing) {
            existing = document.createElement('style');
            existing.id = 'humanist-overrides';
            document.head.appendChild(existing);
          }
          existing.textContent = \(cssLiteral);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.status = .failed(message)
            // Clear `loadedURL` so the next navigation request — even
            // to the same URL — triggers a fresh `loadFileURL` rather
            // than getting de-duplicated against the failed load.
            self.loadedURL = nil
        }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.status = .failed(message)
            self.loadedURL = nil
        }
    }

    func flushPendingScroll() {
        guard let webView, let id = pendingScrollAnchor else { return }
        pendingScrollAnchor = nil
        let safe = jsString(id)
        let js = """
        var el = document.getElementById(\(safe));
        if (el) el.scrollIntoView({block: 'start'});
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // WKScriptMessageHandler — JS → Swift back-sync

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String,
              let id = dict["id"] as? String
        else { return }
        switch type {
        case "anchor":    onAnchorVisible?(id)
        case "paragraph": onParagraphVisible?(id)
        default:          break
        }
    }

    private func jsString(_ s: String) -> String {
        let array = (try? JSONSerialization.data(
            withJSONObject: [s], options: []
        )) ?? Data("[\"\"]".utf8)
        let str = String(data: array, encoding: .utf8) ?? "[\"\"]"
        return String(str.dropFirst().dropLast())
    }
}

/// Composite view: the WKWebView itself + a status overlay so failures
/// (or "we never even tried to load") are visible in the editor.
private struct WebPreviewPane: View {
    let url: URL
    let accessRoot: URL
    let reloadTrigger: Int
    let scrollRequest: EditorViewModel.AnchorScrollRequest?
    let fontSize: Double
    let theme: String
    let onAnchorVisible: ((String) -> Void)?
    let onParagraphVisible: ((String) -> Void)?
    @StateObject private var model = WebPreviewModel()

    var body: some View {
        ZStack(alignment: .top) {
            WebPreview(
                url: url,
                accessRoot: accessRoot,
                reloadTrigger: reloadTrigger,
                scrollRequest: scrollRequest,
                fontSize: fontSize,
                theme: theme,
                model: model
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBadge
                .padding(.top, 8)
        }
        .onAppear {
            model.onAnchorVisible = onAnchorVisible
            model.onParagraphVisible = onParagraphVisible
        }
        .onChange(of: ObjectIdentifier(model)) { _, _ in
            // Belt-and-suspenders: re-bind closures if model identity
            // changes (shouldn't with @StateObject, but cheap).
            model.onAnchorVisible = onAnchorVisible
            model.onParagraphVisible = onParagraphVisible
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.status {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading preview…")
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
        case .loaded:
            EmptyView()
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Preview failed to load", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(url.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
        }
    }
}

private struct WebPreview: NSViewRepresentable {
    let url: URL
    let accessRoot: URL
    let reloadTrigger: Int
    let scrollRequest: EditorViewModel.AnchorScrollRequest?
    let fontSize: Double
    let theme: String
    let model: WebPreviewModel

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        // Inject the IntersectionObserver bridge into every loaded
        // page. Only fires for pages that actually have hu-page-*
        // anchors; otherwise it's a cheap no-op.
        userContent.addUserScript(WKUserScript(
            source: Self.intersectionObserverSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        userContent.add(model, name: "humanistPreview")
        cfg.userContentController = userContent
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.navigationDelegate = model
        model.webView = view
        load(into: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        load(into: nsView)
        applyScrollRequestIfNeeded(view: nsView)
        applyAppearanceOverrides(view: nsView)
    }

    /// Inject (or update) a `<style id="humanist-overrides">`
    /// element in the loaded XHTML's head whose content reflects
    /// the user's preview font size + theme. Re-running on every
    /// `updateNSView` is cheap; the JS replaces an existing element
    /// rather than appending a new one, so the style stays current.
    private func applyAppearanceOverrides(view: WKWebView) {
        guard model.status == .loaded else {
            // Defer until didFinish — flushPendingScroll's analog.
            model.pendingFontSize = fontSize
            model.pendingTheme = theme
            return
        }
        let css = Self.overrideCSS(fontSize: fontSize, theme: theme)
        let escaped = (try? JSONSerialization.data(
            withJSONObject: [css], options: []
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let cssLiteral = String(escaped.dropFirst().dropLast())
        let js = """
        (function() {
          var existing = document.getElementById('humanist-overrides');
          if (!existing) {
            existing = document.createElement('style');
            existing.id = 'humanist-overrides';
            document.head.appendChild(existing);
          }
          existing.textContent = \(cssLiteral);
        })();
        """
        view.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Render the `<style>` element's CSS for the current settings.
    /// Body font size cascades to descendants in points; the theme
    /// override class flips the document's color scheme via a
    /// `:where()` body selector that wins over the EPUB stylesheet
    /// without needing per-element overrides.
    static func overrideCSS(fontSize: Double, theme: String) -> String {
        let size = max(8, min(48, Int(fontSize)))
        var css = "html, body { font-size: \(size)px; }\n"
        switch theme {
        case "light":
            css += """
              :root { color-scheme: light; }
              body { background: #ffffff !important; color: #1d1d1d !important; }

            """
        case "dark":
            css += """
              :root { color-scheme: dark; }
              body { background: #1e1e1e !important; color: #d4d4d4 !important; }
              a { color: #6cb4f0 !important; }

            """
        default:
            // "system" — let CSS prefers-color-scheme handle it; we
            // don't override either way.
            break
        }
        return css
    }

    private func load(into view: WKWebView) {
        // WebKit's sandbox check is a strict path-prefix comparison;
        // canonicalize both sides via the shared helper so `/var/...`
        // vs `/private/var/...` doesn't trip "outside the sandbox."
        let resolvedURL = url.canonicalForFile
        let resolvedAccess = accessRoot.canonicalForFile
        let urlChanged = model.loadedURL != resolvedURL
        let triggerChanged = model.loadedTrigger != reloadTrigger
        guard urlChanged || triggerChanged else { return }

        // Always use `loadFileURL` (never `view.reload()`) for both
        // URL changes and same-URL refreshes. `reload()` on a `file://`
        // URL has shaky semantics: WebKit can re-parse the path and
        // misinterpret digit-only path segments (e.g. "chapter-010")
        // as port-like, throwing "not allowed to use restricted
        // network port" — and that error then poisons the WKWebView's
        // internal state so subsequent loadFileURL calls also fail.
        // Always-loadFileURL bypasses both quirks; the cost is one
        // extra repaint per content-only refresh, which is invisible
        // for our use case.
        //
        // `stopLoading()` cancels any in-flight nav before we kick
        // the new one, avoiding races where two loads compete and
        // leave the view in a half-loaded state.
        model.loadedURL = resolvedURL
        model.loadedTrigger = reloadTrigger
        model.status = .loading
        view.stopLoading()
        view.loadFileURL(resolvedURL, allowingReadAccessTo: resolvedAccess)
    }

    private func applyScrollRequestIfNeeded(view: WKWebView) {
        guard let req = scrollRequest else { return }
        guard model.lastScrollNonce != req.nonce else { return }
        model.lastScrollNonce = req.nonce
        // If the page is still loading, defer; didFinish flushes it.
        if model.status == .loaded {
            model.pendingScrollAnchor = req.anchorId
            model.flushPendingScroll()
        } else {
            model.pendingScrollAnchor = req.anchorId
        }
    }

    // MARK: - injected JS

    private static let intersectionObserverSource: String = """
    (function () {
      if (!('IntersectionObserver' in window)) return;
      if (!window.webkit || !window.webkit.messageHandlers
          || !window.webkit.messageHandlers.humanistPreview) return;

      function setup() {
        // Track BOTH page anchors (`hu-page-*`) and paragraph
        // anchors (`hu-p-*`). Page-level drives PDF / source
        // alignment at page granularity (existing behavior);
        // paragraph-level lands a finer-grained source ↔ preview
        // snap. We report each independently — the Swift side
        // dispatches by anchor type.
        var pageAnchors = document.querySelectorAll('[id^="hu-page-"]');
        var paraAnchors = document.querySelectorAll('[id^="hu-p-"]');
        if (!pageAnchors.length && !paraAnchors.length) return;

        var lastPageActive = null;
        var lastParaActive = null;

        function topmostVisible(entries) {
          var visible = entries.filter(function (e) { return e.isIntersecting; });
          if (!visible.length) return null;
          visible.sort(function (a, b) {
            return a.boundingClientRect.top - b.boundingClientRect.top;
          });
          return visible[0].target.id;
        }

        function post(typeKey, id) {
          try {
            window.webkit.messageHandlers.humanistPreview.postMessage({
              type: typeKey, id: id
            });
          } catch (e) {}
        }

        if (pageAnchors.length) {
          var pageIO = new IntersectionObserver(function (entries) {
            var topId = topmostVisible(entries);
            if (topId && topId !== lastPageActive) {
              lastPageActive = topId;
              // Existing 'anchor' message kind preserved for
              // backward compatibility — Swift's existing handler
              // expects this for page anchors.
              post('anchor', topId);
            }
          }, { rootMargin: '0px 0px -80% 0px', threshold: 0 });
          for (var i = 0; i < pageAnchors.length; i++) {
            pageIO.observe(pageAnchors[i]);
          }
        }

        if (paraAnchors.length) {
          var paraIO = new IntersectionObserver(function (entries) {
            var topId = topmostVisible(entries);
            if (topId && topId !== lastParaActive) {
              lastParaActive = topId;
              post('paragraph', topId);
            }
          }, { rootMargin: '0px 0px -80% 0px', threshold: 0 });
          for (var j = 0; j < paraAnchors.length; j++) {
            paraIO.observe(paraAnchors[j]);
          }
        }
      }

      if (document.readyState === 'complete'
          || document.readyState === 'interactive') {
        setup();
      } else {
        document.addEventListener('DOMContentLoaded', setup);
      }
    })();
    """
}

// MARK: - image fallback

private struct ImagePreview: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding()
        } else {
            Text("Could not load image")
                .foregroundStyle(.secondary)
        }
    }
}
