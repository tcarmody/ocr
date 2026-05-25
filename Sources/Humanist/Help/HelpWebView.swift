import SwiftUI
import WebKit

/// Renders a Markdown help topic as styled HTML inside a
/// WKWebView. The webview approach buys us proper block-level
/// layout (tables, code blocks, headings) and consistent
/// typography without writing each block-element renderer in
/// SwiftUI primitives. CSS is bundled inline in the HTML
/// template — no separate stylesheet file to keep in sync.
///
/// Light/dark adaptation: the template uses `prefers-color-
/// scheme` media queries; the host SwiftUI view propagates the
/// chat-appearance color scheme via .preferredColorScheme so the
/// webview's underlying NSAppearance flips with the rest of
/// Humanist's chat surfaces when the user has forced light /
/// dark from Settings.
struct HelpWebView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(
            frame: .zero, configuration: configuration
        )
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let body = HelpMarkdownRenderer.render(markdown)
        let html = Self.wrap(body: body)
        nsView.loadHTMLString(html, baseURL: nil)
    }

    /// Wrap a rendered HTML fragment in the help-doc template.
    /// CSS adapts to light/dark via prefers-color-scheme; tables
    /// get tight borders + monospace for code blocks; max-width
    /// keeps long-form prose readable at large window sizes.
    private static func wrap(body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        :root {
            color-scheme: light dark;
            --fg: #1d1d1f;
            --fg-muted: #4a4a4f;
            --bg: transparent;
            --rule: #d2d2d7;
            --code-bg: rgba(120, 120, 128, 0.10);
            --table-row-alt: rgba(120, 120, 128, 0.06);
            --link: #0066cc;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --fg: #f5f5f7;
                --fg-muted: #a1a1a6;
                --rule: #3a3a3d;
                --code-bg: rgba(120, 120, 128, 0.22);
                --table-row-alt: rgba(120, 120, 128, 0.10);
                --link: #4ea1ff;
            }
        }
        body {
            font: 14px/1.55 -apple-system, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
            color: var(--fg);
            background: var(--bg);
            max-width: 720px;
            margin: 0 auto;
            padding: 32px 36px 80px;
            -webkit-text-size-adjust: none;
        }
        h1, h2, h3 {
            color: var(--fg);
            font-weight: 600;
            margin-top: 1.6em;
            margin-bottom: 0.5em;
            line-height: 1.25;
        }
        h1 {
            font-size: 26px;
            margin-top: 0;
            border-bottom: 1px solid var(--rule);
            padding-bottom: 0.3em;
        }
        h2 {
            font-size: 19px;
            margin-top: 1.8em;
        }
        h3 {
            font-size: 15px;
            color: var(--fg-muted);
            text-transform: none;
        }
        p { margin: 0.8em 0; }
        a {
            color: var(--link);
            text-decoration: none;
        }
        a:hover { text-decoration: underline; }
        ul, ol {
            padding-left: 1.4em;
            margin: 0.6em 0 0.9em;
        }
        li { margin: 0.25em 0; }
        code {
            background: var(--code-bg);
            border-radius: 4px;
            padding: 0.1em 0.35em;
            font: 12.5px/1.4 "SF Mono", Menlo, Monaco, monospace;
        }
        pre {
            background: var(--code-bg);
            border-radius: 6px;
            padding: 12px 14px;
            overflow-x: auto;
            margin: 0.8em 0;
        }
        pre code {
            background: transparent;
            padding: 0;
            font-size: 12.5px;
        }
        table {
            border-collapse: collapse;
            margin: 1em 0;
            width: 100%;
            font-size: 13.5px;
        }
        th, td {
            border: 1px solid var(--rule);
            padding: 6px 10px;
            text-align: left;
            vertical-align: top;
        }
        thead th {
            background: var(--code-bg);
            font-weight: 600;
        }
        tbody tr:nth-child(even) {
            background: var(--table-row-alt);
        }
        strong { font-weight: 600; }
        em { font-style: italic; }
        ::selection {
            background: rgba(0, 102, 204, 0.30);
        }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
