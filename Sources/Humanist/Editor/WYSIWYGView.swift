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
    /// Outbound formatting commands from the toolbar. Each request
    /// carries a UUID nonce so the coordinator can detect re-renders
    /// and skip re-applying a command it has already handled.
    @Binding var commandRequest: WYSIWYGCommandRequest?
    /// Bumped by `EditorViewModel` after a successful save. When this
    /// changes and the body text stored in the coordinator differs from
    /// the current `xhtml`, the WebView reloads so Source-pane edits
    /// are reflected here. No-ops when the WYSIWYG is itself the
    /// source of the latest changes (i.e. `lastObservedBodyHTML` already
    /// matches `xhtml`).
    let reloadAfterSaveToken: Int
    /// User-tweakable look. Bundle of font + size + theme — when
    /// these change, the coordinator reapplies them via a tiny JS
    /// hook without reloading the page (no cursor jump).
    var appearance: WYSIWYGAppearance
    /// Inbound scroll request. When this changes, the coordinator
    /// runs a small JS snippet that scrolls the WebView to the
    /// matching `id`. nil → no pending request. Same shape and
    /// nonce-tracking as the Source and Preview panes use.
    let scrollRequest: EditorViewModel.AnchorScrollRequest?
    /// Fires when the JS IntersectionObserver reports a new
    /// topmost-visible `hu-page-*` anchor. Drives passive tracking
    /// of `EditorViewModel.currentWYSIWYGAnchor` — the explicit
    /// cross-pane drive is still menu-triggered.
    let onAnchorVisible: (String) -> Void
    /// Same shape, but for paragraph anchors (`hu-p-*`).
    let onParagraphVisible: (String) -> Void

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
        } else if context.coordinator.lastAppearance != appearance {
            context.coordinator.lastAppearance = appearance
            context.coordinator.applyAppearance()
        }
        if let req = commandRequest {
            if req.id != coord.lastAppliedCommandID {
                coord.lastAppliedCommandID = req.id
                coord.applyCommand(req.command)
            }
            DispatchQueue.main.async {
                self.commandRequest = nil
            }
        }

        // Post-save sync: if a save just completed and the body text in
        // `xhtml` differs from what the WYSIWYG last loaded, reload so
        // Source-pane edits become visible here. Skip when the WYSIWYG
        // itself was the source of the latest changes (body already
        // matches `lastObservedBodyHTML`).
        if reloadAfterSaveToken != coord.lastSeenSaveToken {
            coord.lastSeenSaveToken = reloadAfterSaveToken
            let currentBody = WYSIWYGHTML.extractBody(from: xhtml)
            if currentBody != coord.lastLoadedBodyHTML {
                coord.loadInitial()
            }
        }

        // Inbound scroll request from "Align Others to …" commands.
        // Match by nonce so an identical anchorId fires again when a
        // new request is posted (same shape Preview / Source use).
        if let req = scrollRequest, req.nonce != coord.lastSeenScrollNonce {
            coord.lastSeenScrollNonce = req.nonce
            coord.scrollToAnchor(req.anchorId)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: WYSIWYGView
        weak var webView: WKWebView?
        var lastResetID: AnyHashable?
        var lastAppearance: WYSIWYGAppearance?
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
        /// UUID of the last command request we applied. Guards against
        /// re-applying the same click when SwiftUI re-renders
        /// `updateNSView` before the async `commandRequest = nil` fires.
        var lastAppliedCommandID: UUID?
        /// Body HTML of the XHTML that was most recently loaded into
        /// the WebView (either via `loadInitial` or produced by the
        /// WYSIWYG itself via `postEdit`). Used to decide whether a
        /// post-save reload is needed.
        var lastLoadedBodyHTML: String = ""
        /// Last `reloadAfterSaveToken` we acted on. Compared in
        /// `updateNSView` to detect a new save completion.
        var lastSeenSaveToken: Int = -1
        /// Last AnchorScrollRequest nonce we applied. Compared in
        /// `updateNSView` so identical anchorIds on consecutive
        /// requests still re-scroll.
        var lastSeenScrollNonce: Int = .min

        init(parent: WYSIWYGView) {
            self.parent = parent
            super.init()
            self.lastResetID = parent.resetID
            self.lastAppearance = parent.appearance
        }

        func loadInitial() {
            isReady = false
            let bodyContents = WYSIWYGHTML.extractBody(from: parent.xhtml)
            lastLoadedBodyHTML = bodyContents
            let html = renderEnvelope(
                bodyContents: bodyContents,
                cssURL: parent.cssURL,
                appearance: parent.appearance
            )
            // Use the EPUB working directory as the read-access
            // base so relative `<img>` / CSS paths resolve.
            let baseURL = parent.cssURL?
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            webView?.loadHTMLString(html, baseURL: baseURL)
        }

        /// Apply font / size / theme tweaks live without reloading
        /// the document — keeps the cursor + selection intact while
        /// the user fiddles with Settings.
        func applyAppearance() {
            let app = parent.appearance
            let css = """
            (function() {
              const r = document.documentElement.style;
              r.setProperty('--humanist-font-family', \"\(escapeJSString(app.fontFamily.cssStack))\");
              r.setProperty('--humanist-font-size', '\(app.fontSize)px');
              document.body.dataset.humanistTheme = '\(app.theme.rawValue)';
            })();
            """
            if isReady {
                webView?.evaluateJavaScript(css, completionHandler: nil)
            } else {
                pendingJS.append(css)
            }
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
                    // Keep lastLoadedBodyHTML in sync with WYSIWYG edits
                    // so a save triggered right after a WYSIWYG edit
                    // doesn't incorrectly treat the content as stale.
                    lastLoadedBodyHTML = body
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
            case "anchor":
                if let id = dict["id"] as? String {
                    parent.onAnchorVisible(id)
                }
            case "paragraph":
                if let id = dict["id"] as? String {
                    parent.onParagraphVisible(id)
                }
            default:
                break
            }
        }

        /// Scroll the WebView so the element with `id == anchorId`
        /// sits near the top of the viewport. Uses the same
        /// rootMargin posture as the Preview pane (rooted at the
        /// top 20% so the user lands above the fold) and a smooth
        /// scroll behavior so the motion isn't jarring.
        func scrollToAnchor(_ anchorId: String) {
            let escaped = anchorId
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function() {
              var el = document.getElementById('\(escaped)');
              if (!el) return;
              el.scrollIntoView({ behavior: 'smooth', block: 'start' });
            })();
            """
            if isReady {
                webView?.evaluateJavaScript(js, completionHandler: nil)
            } else {
                pendingJS.append(js)
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

/// Bundle of user appearance preferences for the WYSIWYG pane —
/// flows in from Settings and propagates to the running WebView
/// either via the initial HTML envelope or, on subsequent
/// changes, via a small JS hook that updates CSS variables in
/// place.
struct WYSIWYGAppearance: Equatable {
    var fontFamily: EditorFontFamily
    var fontSize: Double
    var theme: EditorThemeMode
}

/// A toolbar button press wrapped with a UUID nonce so each click is
/// a unique value. Without the nonce, rapid button presses (or
/// SwiftUI re-renders triggered by the edit round-trip) can re-apply
/// the same command because `commandRequest = nil` is deferred.
struct WYSIWYGCommandRequest: Equatable {
    let command: WYSIWYGCommand
    let id: UUID

    init(_ command: WYSIWYGCommand) {
        self.command = command
        self.id = UUID()
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
    /// Strip inline formatting from the selection. Maps to
    /// `document.execCommand('removeFormat')` + `unlink` so
    /// `<strong>`, `<em>`, links, font styling, etc. all clear
    /// in one click. Block elements (`<p>`, `<h2>`, list items)
    /// keep their wrapper — execCommand can't unwrap those
    /// without a full block-level normalization pass.
    case removeFormatting

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
        case .removeFormatting:
            return "humanistRemoveFormatting()"
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

/// Escape a string for safe interpolation inside a single-quoted
/// JS literal. Just covers the cases we actually emit (backslashes
/// and single quotes); the strings here are short configurable
/// values from Settings and CSS stacks, no untrusted input.
private func escapeJSString(_ s: String) -> String {
    s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "'", with: "\\'")
}

private func renderEnvelope(
    bodyContents: String,
    cssURL: URL?,
    appearance: WYSIWYGAppearance
) -> String {
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
        :root {
          --humanist-font-family: \(appearance.fontFamily.cssStack);
          --humanist-font-size: \(appearance.fontSize)px;
        }
        html, body {
          margin: 0; padding: 0;
          height: 100%;
          background: Canvas;
          color: CanvasText;
        }
        /* `data-humanist-theme="light"` / `"dark"` overrides the
           system appearance for the editing surface only. The
           "system" theme leaves the data attr empty and lets
           Canvas / CanvasText follow the OS. */
        body[data-humanist-theme="light"] { background: #ffffff; color: #1a1a1a; }
        body[data-humanist-theme="dark"]  { background: #1c1c1e; color: #f5f5f7; }
        body {
          padding: 1.25rem 1.5rem 5rem;
          font-family: var(--humanist-font-family);
          font-size: var(--humanist-font-size);
          line-height: 1.5;
          outline: none;
          caret-color: currentColor;
        }
        body[contenteditable="true"]:focus { outline: none; }
        body * { max-width: 38rem; margin-left: auto; margin-right: auto; }
        h1, h2, h3, h4, h5, h6 { font-weight: 600; }
        a { color: -apple-system-blue; }
        :focus-visible { outline: 2px solid -apple-system-blue; outline-offset: 2px; }
      </style>
      <script>
      (function() {
        function sanitize(html) {
          // Self-close void elements (XHTML requires `<br/>`, but
          // the HTML serializer emits `<br>`).
          html = html.replace(
            /<(br|hr|img|input|meta|link|area|base|col|embed|param|source|track|wbr)\\b([^>]*?)>/gi,
            '<$1$2/>'
          );
          // The replacement above adds a trailing `/` even when
          // one was already present — collapse `//>` to `/>`.
          html = html.replace(/\\/+>/g, '/>');
          // Browsers default `B`/`I` for ⌘B/⌘I; the rest of the
          // codebase emits `strong`/`em`. Normalize so the source
          // doesn't drift.
          html = html.replace(/<b\\b/gi, '<strong').replace(/<\\/b>/gi, '</strong>');
          html = html.replace(/<i\\b/gi, '<em').replace(/<\\/i>/gi, '</em>');
          // Empty `<p>` (and `<p><br/></p>`) creep in when the
          // user presses Enter on a blank line.
          html = html.replace(/<p>\\s*(<br\\/>)?\\s*<\\/p>/gi, '');
          return html;
        }
        function postEdit() {
          // Clone first so cleanup doesn't disturb the live DOM
          // (cursor / selection / undo stack).
          const clone = document.body.cloneNode(true);
          // Strip helpers that should never reach the chapter
          // source — see the head comment on this script's
          // location for why.
          for (const node of clone.querySelectorAll('script, style, link')) {
            node.remove();
          }
          // Replace U+00A0 (non-breaking space) with a regular
          // space in every text node. WKWebView's contenteditable
          // injects NBSP for runs of regular spaces and at edge
          // positions; the HTML serializer then emits `&nbsp;`,
          // which is undefined in XHTML and trips the preview's
          // XML parser.
          const walker = document.createTreeWalker(clone, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            walker.currentNode.nodeValue =
              walker.currentNode.nodeValue.replace(/\\u00A0/g, ' ');
          }
          const body = sanitize(clone.innerHTML);
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
        window.humanistRemoveFormatting = function() {
          // `removeFormat` strips inline style (bold, italic,
          // span styling). `unlink` removes anchor wrappers.
          // Combined, they bring the selection back to plain
          // text inside whatever block container it lives in.
          document.execCommand('removeFormat', false, null);
          document.execCommand('unlink', false, null);
          document.body.focus();
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
        function setupAnchorObservers() {
          if (!('IntersectionObserver' in window)) return;
          if (!window.webkit
              || !window.webkit.messageHandlers
              || !window.webkit.messageHandlers.wysiwyg) return;

          // Mirrors the PreviewView observer: report topmost-visible
          // page-level (`hu-page-*`) and paragraph-level (`hu-p-*`)
          // anchors as the user scrolls. Reporting is passive —
          // updates the Swift side's currentWYSIWYG* state but
          // doesn't cause the other panes to scroll. The explicit
          // cross-pane drive is the "Align Others to WYSIWYG"
          // menu command.
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
              window.webkit.messageHandlers.wysiwyg.postMessage({
                type: typeKey, id: id
              });
            } catch (e) {}
          }

          if (pageAnchors.length) {
            var pageIO = new IntersectionObserver(function (entries) {
              var topId = topmostVisible(entries);
              if (topId && topId !== lastPageActive) {
                lastPageActive = topId;
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

        document.addEventListener('DOMContentLoaded', () => {
          // Make Enter produce `<p>` instead of the WebKit
          // default `<div>` — keeps the source consistent with
          // the rest of the codebase's paragraph convention.
          try { document.execCommand('defaultParagraphSeparator', false, 'p'); } catch (e) {}
          document.body.addEventListener('input', scheduleEdit);
          setupAnchorObservers();
        });
      })();
      </script>
    </head>
    <body contenteditable="true" spellcheck="true" data-humanist-theme="\(appearance.theme.rawValue == "system" ? "" : appearance.theme.rawValue)">
    \(bodyContents)
    </body>
    </html>
    """
}

