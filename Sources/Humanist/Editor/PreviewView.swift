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
            WebPreview(url: file.id, accessRoot: workingDirectory)
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

// MARK: - WKWebView wrapper

private struct WebPreview: NSViewRepresentable {
    let url: URL
    let accessRoot: URL  // grant the webview read access to this dir
                          // so file:// CSS/image references resolve.

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.setValue(false, forKey: "drawsBackground")
        load(into: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        load(into: nsView)
    }

    private func load(into view: WKWebView) {
        // loadFileURL scopes read access. Without `allowingReadAccessTo`
        // pointing at the working dir, WKWebView refuses CSS in a
        // sibling folder.
        view.loadFileURL(url, allowingReadAccessTo: accessRoot)
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
