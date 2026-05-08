import SwiftUI
import AppKit
import WebKit
import Document
import Pipeline

/// Standalone "Show Original" window. Dispatches by file extension
/// to the right rendering surface so the user can preview the source
/// document the EPUB was converted from, regardless of format.
///
/// PDF gets the existing PDFViewer (with thumbnails + page nav);
/// rich-text formats (RTF / DOC / DOCX / ODT) render as an
/// `NSAttributedString` in a read-only `NSTextView`; HTML loads
/// directly in a `WKWebView`; Markdown is parsed via `DocumentIngest`
/// and rendered as an attributed string; plain text shows in a
/// monospaced text view.
struct SourceViewerView: View {
    let sourceURL: URL

    var body: some View {
        Group {
            switch kind {
            case .pdf:
                PDFViewerView(pdfURL: sourceURL)
            case .html:
                WebFileView(url: sourceURL)
                    .navigationTitle(sourceURL.lastPathComponent)
            case .richText(let docType):
                AttributedDocumentView(
                    url: sourceURL,
                    documentType: docType,
                    monospaced: false
                )
                .navigationTitle(sourceURL.lastPathComponent)
            case .markdown:
                MarkdownDocumentView(url: sourceURL)
                    .navigationTitle(sourceURL.lastPathComponent)
            case .plainText:
                AttributedDocumentView(
                    url: sourceURL,
                    documentType: nil,
                    monospaced: true
                )
                .navigationTitle(sourceURL.lastPathComponent)
            case .unsupported:
                unsupportedFallback
            }
        }
        .frame(minWidth: 540, minHeight: 480)
    }

    private enum Kind {
        case pdf
        case html
        case markdown
        case plainText
        case richText(NSAttributedString.DocumentType)
        case unsupported
    }

    private var kind: Kind {
        switch sourceURL.pathExtension.lowercased() {
        case "pdf":                 return .pdf
        case "html", "htm":         return .html
        case "md", "markdown":      return .markdown
        case "txt":                 return .plainText
        case "rtf":                 return .richText(.rtf)
        case "rtfd":                return .richText(.rtfd)
        case "docx":                return .richText(.officeOpenXML)
        case "doc":                 return .richText(.docFormat)
        case "odt":                 return .richText(.openDocument)
        default:                    return .unsupported
        }
    }

    @ViewBuilder
    private var unsupportedFallback: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Can't preview \(sourceURL.lastPathComponent)").font(.headline)
            Text("Reveal in Finder to open with the system default app.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - HTML

private struct WebFileView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Only reload when the file URL actually changes — avoids
        // bouncing the page back to top on every SwiftUI redraw.
        if view.url != url {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}

// MARK: - rich text / plain text

private struct AttributedDocumentView: NSViewRepresentable {
    let url: URL
    /// Nil documentType = plain text; we read the file as a UTF-8
    /// string and wrap it in an attributed string with a monospaced
    /// font.
    let documentType: NSAttributedString.DocumentType?
    let monospaced: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        configure(textView: textView)
        load(into: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        load(into: textView)
    }

    private func configure(textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFontPanel = false
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.backgroundColor = .textBackgroundColor
    }

    private func load(into textView: NSTextView) {
        let attr: NSAttributedString
        if let documentType {
            do {
                attr = try NSAttributedString(
                    url: url,
                    options: [.documentType: documentType],
                    documentAttributes: nil
                )
            } catch {
                attr = NSAttributedString(string: "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        } else {
            let plain = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let font: NSFont = monospaced
                ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                : NSFont.systemFont(ofSize: 13)
            attr = NSAttributedString(
                string: plain,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        }
        textView.textStorage?.setAttributedString(attr)
    }
}

// MARK: - markdown

private struct MarkdownDocumentView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFontPanel = false
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.backgroundColor = .textBackgroundColor
        load(into: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        load(into: textView)
    }

    /// Reuse `DocumentIngest.parseMarkdown` so the preview matches
    /// what the conversion actually produced. Render to an
    /// `NSAttributedString` with simple heading-vs-paragraph
    /// styling and italic/bold via the parsed run flags.
    private func load(into textView: NSTextView) {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let blocks = DocumentIngest().parseMarkdown(raw)
        let out = NSMutableAttributedString()
        for block in blocks {
            switch block {
            case .heading(let level, let runs):
                let baseSize: CGFloat = max(14, 26 - CGFloat(level) * 2)
                let para = NSMutableParagraphStyle()
                para.paragraphSpacingBefore = 14
                para.paragraphSpacing = 6
                appendRuns(
                    runs,
                    baseFont: NSFont.boldSystemFont(ofSize: baseSize),
                    paragraphStyle: para,
                    into: out
                )
                out.append(NSAttributedString(string: "\n"))
            case .paragraph(let runs):
                let para = NSMutableParagraphStyle()
                para.paragraphSpacing = 8
                appendRuns(
                    runs,
                    baseFont: NSFont.systemFont(ofSize: 13),
                    paragraphStyle: para,
                    into: out
                )
                out.append(NSAttributedString(string: "\n"))
            default:
                break
            }
        }
        out.addAttribute(
            .foregroundColor,
            value: NSColor.labelColor,
            range: NSRange(location: 0, length: out.length)
        )
        textView.textStorage?.setAttributedString(out)
    }

    private func appendRuns(
        _ runs: [InlineRun],
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into out: NSMutableAttributedString
    ) {
        for run in runs {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if run.isItalic { traits.insert(.italic) }
            if run.isBold { traits.insert(.bold) }
            let font = traits.isEmpty
                ? baseFont
                : (NSFont(
                    descriptor: baseFont.fontDescriptor.withSymbolicTraits(traits),
                    size: baseFont.pointSize
                ) ?? baseFont)
            out.append(NSAttributedString(
                string: run.text,
                attributes: [
                    .font: font,
                    .paragraphStyle: paragraphStyle,
                ]
            ))
        }
    }
}
