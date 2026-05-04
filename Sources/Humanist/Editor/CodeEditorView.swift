import SwiftUI
import WebKit
import AppKit

/// Source editor pane backed by CodeMirror 5 hosted in a WKWebView.
///
/// Bridge:
///   * Swift → JS calls `humanistSetContent(text, mode)` whenever the
///     bound text changes from outside (file switch, programmatic
///     edit). Initial load defers until the JS posts `ready`.
///   * JS → Swift posts `{ type: "edit", text }` on every CodeMirror
///     change; the wrapper writes to the binding without echoing back.
///   * Cmd-F triggers CodeMirror's search dialog via `humanistFocusFind`.
///
/// Falls back to a plain `TextEditor` when the CodeMirror assets
/// aren't bundled (e.g. development builds where Resources/ wasn't
/// copied yet) so the source pane stays editable either way.
struct CodeEditorView: View {
    @Binding var text: String
    let language: Language
    /// Bumps when the parent wants the editor to discard local state
    /// (file switch). Same trick as `PreviewView.reloadTrigger`.
    let resetID: AnyHashable

    enum Language: String {
        case xml, htmlmixed, css, javascript

        /// Pick a sensible mode from a file URL's extension.
        static func from(url: URL) -> Language {
            switch url.pathExtension.lowercased() {
            case "xhtml", "html", "htm":  return .htmlmixed
            case "css":                    return .css
            case "js":                     return .javascript
            default:                       return .xml
            }
        }
    }

    var body: some View {
        if let indexURL = Self.bundledIndexHTML,
           let assetsRoot = Self.bundledAssetsRoot {
            CodeMirrorWebView(
                indexURL: indexURL,
                assetsRoot: assetsRoot,
                text: $text,
                language: language,
                resetID: resetID
            )
        } else {
            // CodeMirror assets weren't bundled. Plain TextEditor so
            // the source pane is at least editable.
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private static var bundledIndexHTML: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("codemirror", isDirectory: true)
            .appendingPathComponent("index.html")
    }
    private static var bundledAssetsRoot: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("codemirror", isDirectory: true)
    }
}

// MARK: - WKWebView wrapper

private struct CodeMirrorWebView: NSViewRepresentable {
    let indexURL: URL
    let assetsRoot: URL
    @Binding var text: String
    let language: CodeEditorView.Language
    let resetID: AnyHashable

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "humanist")
        cfg.userContentController = userContent
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view

        // WebKit's sandbox check is a strict path-prefix comparison —
        // canonicalize per the project memory (see URL+Canonical.swift).
        let canonicalIndex = indexURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let canonicalRoot = assetsRoot.standardizedFileURL
            .resolvingSymlinksInPath()
        view.loadFileURL(canonicalIndex, allowingReadAccessTo: canonicalRoot)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        // File switch: reset history + push fresh content.
        if coordinator.lastResetID != resetID {
            coordinator.lastResetID = resetID
            coordinator.lastPushedText = text
            coordinator.lastLanguage = language
            coordinator.pushContent(text: text, language: language, reason: .reset)
            return
        }
        // Same file, but the text changed externally (e.g. live preview
        // refresh wrote to the buffer). Push the change down too.
        if coordinator.lastPushedText != text {
            coordinator.lastPushedText = text
            coordinator.pushContent(text: text, language: language, reason: .external)
        }
        // Language might change without resetID changing if we ever
        // route the same buffer through different syntax modes.
        if coordinator.lastLanguage != language {
            coordinator.lastLanguage = language
            coordinator.pushLanguage(language)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler {
        @Binding var text: String
        weak var webView: WKWebView?

        var ready = false
        /// Snapshot of the text most recently pushed into JS. Used to
        /// (a) suppress the round-trip when JS posts the same content
        /// back to us, and (b) detect external edits worth re-pushing.
        var lastPushedText: String = ""
        var lastLanguage: CodeEditorView.Language = .xml
        var lastResetID: AnyHashable = AnyHashable("__init__")
        /// Pending push that came in before JS was ready.
        var pendingPush: (text: String, language: CodeEditorView.Language)?

        init(text: Binding<String>) {
            _text = text
        }

        enum PushReason {
            case reset, external
        }

        func pushContent(text: String,
                         language: CodeEditorView.Language,
                         reason: PushReason) {
            guard ready, let webView else {
                pendingPush = (text, language)
                return
            }
            let js = "humanistSetContent(\(jsString(text)), \(jsString(language.rawValue)));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func pushLanguage(_ language: CodeEditorView.Language) {
            guard ready, let webView else { return }
            let js = "humanistSetContent(humanistGetContent(), \(jsString(language.rawValue)));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                if let pending = pendingPush {
                    pendingPush = nil
                    pushContent(text: pending.text, language: pending.language, reason: .reset)
                }
            case "edit":
                if let newText = dict["text"] as? String {
                    // Update the binding without re-pushing — record the
                    // new value as `lastPushedText` so updateNSView's
                    // diff doesn't reflect this back.
                    lastPushedText = newText
                    DispatchQueue.main.async { [weak self] in
                        self?.text = newText
                    }
                }
            case "focus":
                // Reserved for future menu-enable wiring.
                break
            default:
                break
            }
        }

        /// Encode `s` as a JavaScript string literal.
        func jsString(_ s: String) -> String {
            // JSONSerialization gives us proper escaping (quotes, slashes,
            // unicode) for free; pull off the array brackets it adds.
            let array = (try? JSONSerialization.data(
                withJSONObject: [s], options: []
            )) ?? Data("[\"\"]".utf8)
            let str = String(data: array, encoding: .utf8) ?? "[\"\"]"
            return String(str.dropFirst().dropLast())
        }
    }
}
