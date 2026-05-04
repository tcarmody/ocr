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
                reloadTrigger: reloadTrigger
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
/// callbacks into `@Published` state — Console.app filtering is finicky
/// and "the preview is just blank" is the worst possible bug to debug
/// without a status visible in-app.
@MainActor
private final class WebPreviewModel: NSObject, ObservableObject, WKNavigationDelegate {
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

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.status = .loading }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.status = .loaded }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.status = .failed(message) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.status = .failed(message) }
    }
}

/// Composite view: the WKWebView itself + a status overlay so failures
/// (or "we never even tried to load") are visible in the editor.
private struct WebPreviewPane: View {
    let url: URL
    let accessRoot: URL
    let reloadTrigger: Int
    @StateObject private var model = WebPreviewModel()

    var body: some View {
        ZStack(alignment: .top) {
            WebPreview(
                url: url,
                accessRoot: accessRoot,
                reloadTrigger: reloadTrigger,
                model: model
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBadge
                .padding(.top, 8)
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
    let model: WebPreviewModel

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = model
        load(into: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        load(into: nsView)
    }

    private func load(into view: WKWebView) {
        // WebKit's sandbox check is a strict path-prefix comparison;
        // canonicalize both sides via the shared helper so `/var/...`
        // vs `/private/var/...` doesn't trip "outside the sandbox."
        let resolvedURL = url.canonicalForFile
        let resolvedAccess = accessRoot.canonicalForFile
        if model.loadedURL != resolvedURL {
            // URL change: full load.
            model.loadedURL = resolvedURL
            model.loadedTrigger = reloadTrigger
            model.status = .loading
            view.loadFileURL(resolvedURL, allowingReadAccessTo: resolvedAccess)
        } else if model.loadedTrigger != reloadTrigger {
            // Same URL, on-disk content changed (live preview write).
            // `view.reload()` re-fetches the same URL with the updated
            // bytes — cheaper than loadFileURL, no flicker.
            model.loadedTrigger = reloadTrigger
            model.status = .loading
            view.reload()
        }
    }
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
