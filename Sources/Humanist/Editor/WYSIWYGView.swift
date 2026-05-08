import SwiftUI
import AppKit
import WebKit

/// Rich WYSIWYG pane backed by a `WKWebView` with `contenteditable`
/// turned on. The user edits the chapter visually; on file change
/// or pane re-mount, the view loads the chapter's `<body>`
/// contents into the page; on edit, it pushes the modified body
/// HTML back into the binding so the source pane (and the save
/// path) see the new content.
///
/// The HTML envelope is built once on initial load — book CSS,
/// editor chrome, the body content. Subsequent file selections
/// trigger a full reload. Subsequent edits *don't* reload (would
/// destroy the cursor); they only flow out via the JS bridge.
///
/// The toolbar dispatches `WYSIWYGCommand` actions through the
/// `commandRequest` binding; the coordinator translates each into
/// the right `document.execCommand` (or custom DOM manipulation
/// when execCommand has no equivalent).
struct WYSIWYGView: NSViewRepresentable {
    /// Two-way binding to the buffered XHTML for this chapter.
    /// On load + on resetID change we pull the body out and
    /// inject it; edits in the WebView push back the rebuilt
    /// XHTML envelope.
    @Binding var xhtml: String
    /// Resets the WebView contents when this token changes (e.g.
    /// the user picks a different file in the sidebar).
    let resetID: AnyHashable
    /// Path to the unpacked book's `OEBPS/css/book.css`. The
    /// rendered view inlines a `<base>` and a `<link>` so the
    /// book's typography matches what the EPUB reader shows.
    let cssURL: URL?
    /// Outbound formatting commands from the toolbar. The
    /// coordinator drains these on every update.
    @Binding var commandRequest: WYSIWYGCommand?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "wysiwyg")
        config.userContentController = userContent
        // Letting links navigate inside the editing surface would
        // strand the user on a different document. Block it at the
        // delegate; clicks on links inside the chapter are inert.
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.loadInitial()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        if context.coordinator.lastResetID != resetID {
            context.coordinator.lastResetID = resetID
            context.coordinator.loadInitial()
        }
        if let cmd = commandRequest {
            coord.applyCommand(cmd)
            DispatchQueue.main.async {
                self.commandRequest = nil
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: WYSIWYGView
        weak var webView: WKWebView?
        var lastResetID: AnyHashable?
        /// HTML the coordinator most-recently received from the
        /// WebView. Compared against the binding on every update so
        /// outside-driven changes (e.g. a source-pane edit) trigger
        /// a reload, while our own edits don't loop.
        var lastObservedBodyHTML: String = ""
        /// Set to true from the moment the WebView starts loading
        /// until the navigation completes. JS calls before that
        /// silently fail (no content yet); we queue them so the
        /// toolbar still works on a freshly-mounted pane.
        var isReady: Bool = false
        var pendingJS: [String] = []

        init(parent: WYSIWYGView) {
            self.parent = parent
            super.init()
            self.lastResetID = parent.resetID
        }

        func loadInitial() {
            isReady = false
            let html = renderEnvelope(
                bodyContents: WYSIWYGHTML.extractBody(from: parent.xhtml),
                cssURL: parent.cssURL
            )
            // Use the EPUB working directory as the read-access
            // base so relative `<img>` / CSS paths resolve.
            let baseURL = parent.cssURL?
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            webView?.loadHTMLString(html, baseURL: baseURL)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "wysiwyg",
                  let dict = message.body as? [String: Any] else { return }
            switch dict["type"] as? String {
            case "edit":
                if let body = dict["body"] as? String {
                    lastObservedBodyHTML = body
                    let updated = WYSIWYGHTML.replaceBody(
                        in: parent.xhtml, with: body
                    )
                    if updated != parent.xhtml {
                        // Avoid reloading the WebView in response
                        // to our own outbound update — store the
                        // previous body so the coordinator's
                        // resetID-based load logic doesn't fire.
                        parent.xhtml = updated
                    }
                }
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            isReady = true
            // Drain any toolbar commands that landed before the
            // page finished loading.
            for js in pendingJS {
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            pendingJS.removeAll()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Only allow the initial about:blank / file:// load. Any
            // user-triggered navigation (link click) would replace
            // the editing context and lose unsaved work.
            switch navigationAction.navigationType {
            case .linkActivated, .formSubmitted, .formResubmitted, .reload, .backForward:
                decisionHandler(.cancel)
            case .other:
                decisionHandler(.allow)
            @unknown default:
                decisionHandler(.allow)
            }
        }

        func applyCommand(_ command: WYSIWYGCommand) {
            let js = command.javaScript
            if isReady {
                webView?.evaluateJavaScript(js, completionHandler: nil)
            } else {
                pendingJS.append(js)
            }
        }
    }
}

/// Toolbar-driven action a `WYSIWYGView` can dispatch into the
/// running editor surface. Each case translates to a concrete
/// JavaScript call inside the editing iframe.
enum WYSIWYGCommand: Equatable {
    case bold
    case italic
    case inlineCode
    case superscript
    case `subscript`
    case heading(Int)
    case paragraph
    case blockquote
    case bulletList
    case numberedList
    case horizontalRule
    case link(String)
    case languageTag(String)
    case smartQuotes

    var javaScript: String {
        switch self {
        case .bold:
            return "humanistExec('bold')"
        case .italic:
            return "humanistExec('italic')"
        case .inlineCode:
            return "humanistWrap('code')"
        case .superscript:
            return "humanistExec('superscript')"
        case .subscript:
            return "humanistExec('subscript')"
        case .heading(let n):
            return "humanistExec('formatBlock', 'H\(n)')"
        case .paragraph:
            return "humanistExec('formatBlock', 'P')"
        case .blockquote:
            return "humanistExec('formatBlock', 'BLOCKQUOTE')"
        case .bulletList:
            return "humanistExec('insertUnorderedList')"
        case .numberedList:
            return "humanistExec('insertOrderedList')"
        case .horizontalRule:
            return "humanistExec('insertHorizontalRule')"
        case .link(let url):
            let escaped = url
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            return "humanistExec('createLink', '\(escaped)')"
        case .languageTag(let code):
            let escaped = code
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            return "humanistWrapLang('\(escaped)')"
        case .smartQuotes:
            return "humanistSmartQuotes()"
        }
    }
}

// MARK: - HTML envelope + body splice helpers

enum WYSIWYGHTML {
    /// Pull the body contents out of a chapter XHTML buffer.
    /// Falls back to the entire string when the buffer doesn't
    /// look like wrapped XHTML — better to display the raw text
    /// than nothing.
    static func extractBody(from xhtml: String) -> String {
        guard let openRange = xhtml.range(of: "<body", options: .caseInsensitive),
              let openEnd = xhtml.range(
                of: ">",
                range: openRange.upperBound..<xhtml.endIndex
              ),
              let closeRange = xhtml.range(
                of: "</body>",
                options: [.caseInsensitive, .backwards]
              )
        else { return xhtml }
        return String(xhtml[openEnd.upperBound..<closeRange.lowerBound])
    }

    /// Replace the body contents in `xhtml` with `newBody`, leaving
    /// the head / opening `<body>` tag attributes / any trailing
    /// content untouched.
    static func replaceBody(in xhtml: String, with newBody: String) -> String {
        guard let openRange = xhtml.range(of: "<body", options: .caseInsensitive),
              let openEnd = xhtml.range(
                of: ">",
                range: openRange.upperBound..<xhtml.endIndex
              ),
              let closeRange = xhtml.range(
                of: "</body>",
                options: [.caseInsensitive, .backwards]
              )
        else { return xhtml }
        let prefix = String(xhtml[..<openEnd.upperBound])
        let suffix = String(xhtml[closeRange.lowerBound...])
        return prefix + "\n" + newBody + "\n" + suffix
    }
}

private func renderEnvelope(bodyContents: String, cssURL: URL?) -> String {
    let cssLink: String
    if let cssURL = cssURL {
        cssLink = "<link rel=\"stylesheet\" href=\"\(cssURL.absoluteString)\">"
    } else {
        cssLink = ""
    }
    // The editing helpers live in <head> and bind on
    // DOMContentLoaded. Putting the <script> inside <body> would
    // make `document.body.innerHTML` (the value we ship back to
    // the buffer on every edit) include the script tag itself —
    // a closed loop that pollutes the user's chapter source on
    // the first keystroke. Even script tags placed *after*
    // </body> get parsed back into the body by the HTML parser,
    // so head is the only safe home.
    return """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      \(cssLink)
      <style>
        html, body {
          margin: 0; padding: 0;
          height: 100%;
          background: \(systemBackgroundCSS);
          color: \(systemTextCSS);
        }
        body {
          padding: 1.25rem 1.5rem 5rem;
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue",
                       "Segoe UI", system-ui, serif;
          line-height: 1.5;
          font-size: 16px;
          outline: none;
          caret-color: \(systemTextCSS);
        }
        body[contenteditable="true"]:focus { outline: none; }
        body * { max-width: 38rem; margin-left: auto; margin-right: auto; }
        h1, h2, h3, h4, h5, h6 { font-weight: 600; }
        a { color: -apple-system-blue; }
        :focus-visible { outline: 2px solid -apple-system-blue; outline-offset: 2px; }
      </style>
      <script>
      (function() {
        function postEdit() {
          // Defensive: clone the body and strip any <script> /
          // <style> / <link> nodes before serializing. The editor
          // helpers should only ever live in <head>, but if
          // something ever leaks into body the safest answer is
          // not to bake it into the chapter source.
          const clone = document.body.cloneNode(true);
          for (const node of clone.querySelectorAll('script, style, link')) {
            node.remove();
          }
          const body = clone.innerHTML;
          window.webkit.messageHandlers.wysiwyg.postMessage({
            type: 'edit',
            body: body,
          });
        }
        let pending = false;
        function scheduleEdit() {
          if (pending) return;
          pending = true;
          // Coalesce multi-keystroke runs into a single round-trip.
          setTimeout(() => { pending = false; postEdit(); }, 250);
        }
        window.humanistExec = function(cmd, value) {
          document.execCommand(cmd, false, value);
          document.body.focus();
          postEdit();
        };
        window.humanistWrap = function(tagName) {
          const sel = window.getSelection();
          if (!sel || !sel.rangeCount) return;
          const range = sel.getRangeAt(0);
          if (range.collapsed) return;
          const wrapper = document.createElement(tagName);
          wrapper.appendChild(range.extractContents());
          range.insertNode(wrapper);
          sel.removeAllRanges();
          const after = document.createRange();
          after.selectNodeContents(wrapper);
          sel.addRange(after);
          postEdit();
        };
        window.humanistWrapLang = function(code) {
          const sel = window.getSelection();
          if (!sel || !sel.rangeCount) return;
          const range = sel.getRangeAt(0);
          if (range.collapsed) return;
          const wrapper = document.createElement('span');
          wrapper.setAttribute('lang', code);
          wrapper.setAttribute('xml:lang', code);
          wrapper.appendChild(range.extractContents());
          range.insertNode(wrapper);
          postEdit();
        };
        window.humanistSmartQuotes = function() {
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          const nodes = [];
          while (walker.nextNode()) nodes.push(walker.currentNode);
          for (const n of nodes) {
            let t = n.nodeValue;
            // Convert straight " and ' to curly equivalents. Order
            // matters: opening goes first to use the (boundary,quote)
            // pattern, then a global pass turns the leftover quotes
            // into closing forms.
            t = t.replace(/(^|[\\s\\(\\[\\{<—])"/g, '$1“');
            t = t.replace(/"/g, '”');
            t = t.replace(/(^|[\\s\\(\\[\\{<—])'/g, '$1‘');
            t = t.replace(/'/g, '’');
            n.nodeValue = t;
          }
          postEdit();
        };
        document.addEventListener('DOMContentLoaded', () => {
          document.body.addEventListener('input', scheduleEdit);
        });
      })();
      </script>
    </head>
    <body contenteditable="true" spellcheck="true">
    \(bodyContents)
    </body>
    </html>
    """
}

// We can't reach SwiftUI Color values from the JS string template,
// so use CSS system colors / named colors that look right in both
// light and dark — the WebView automatically picks up the system
// appearance.
private let systemBackgroundCSS = "Canvas"
private let systemTextCSS = "CanvasText"
