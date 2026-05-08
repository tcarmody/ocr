import Foundation
import AppKit
import Document

/// Build a `Book` IR directly from a non-PDF text-based source
/// document — no OCR, no rasterization. Covers the easy text input
/// formats: plain text, Markdown, Rich Text. The harder ones
/// (DOCX, HTML) live alongside this in a follow-up; they share the
/// `NSAttributedString`-based ingest helper here.
public struct DocumentIngest {
    public init() {}

    public enum Failure: Error, LocalizedError {
        case unreadable
        case unsupportedFormat(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                return "Could not read the document."
            case .unsupportedFormat(let ext):
                return "Unsupported document format: .\(ext)"
            }
        }
    }

    /// Source extensions covered by this iteration. Drives the
    /// launcher's drop-target check and file-picker filter.
    public static let supportedExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf",
        "html", "htm", "docx", "doc", "odt",
    ]

    /// True when the file extension is one we know how to ingest
    /// without OCR. Mirrors the launcher's drop-handler check —
    /// PDFs go through the OCR pipeline; these go through here.
    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public func ingest(from url: URL, language: BCP47 = .en) throws -> Book {
        let ext = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent
        switch ext {
        case "txt":
            return try ingestPlainText(url: url, title: title, language: language)
        case "md", "markdown":
            return try ingestMarkdown(url: url, title: title, language: language)
        case "rtf":
            return try ingestAttributedDocument(
                url: url, title: title, language: language,
                documentType: .rtf
            )
        case "html", "htm":
            return try ingestAttributedDocument(
                url: url, title: title, language: language,
                documentType: .html
            )
        case "docx":
            return try ingestAttributedDocument(
                url: url, title: title, language: language,
                documentType: .officeOpenXML
            )
        case "doc":
            return try ingestAttributedDocument(
                url: url, title: title, language: language,
                documentType: .docFormat
            )
        case "odt":
            return try ingestAttributedDocument(
                url: url, title: title, language: language,
                documentType: .openDocument
            )
        default:
            throw Failure.unsupportedFormat(ext)
        }
    }

    // MARK: - plain text

    private func ingestPlainText(url: URL, title: String, language: BCP47) throws -> Book {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.unreadable
        }
        let blocks = plainTextParagraphs(text)
        let chapter = Chapter(title: title, blocks: blocks)
        return Book(title: title, language: language, chapters: [chapter])
    }

    /// Split on one-or-more blank lines into paragraphs. Intra-
    /// paragraph soft-wrap is collapsed to spaces — the output XHTML
    /// flows the paragraph in a single `<p>` regardless of how the
    /// source was wrapped.
    private func plainTextParagraphs(_ text: String) -> [Block] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let separator = try? NSRegularExpression(pattern: "\n[ \t]*\n+")
        let nsText = normalized as NSString
        let chunks: [String]
        if let separator {
            var parts: [String] = []
            var cursor = 0
            separator.enumerateMatches(
                in: normalized,
                range: NSRange(location: 0, length: nsText.length)
            ) { match, _, _ in
                guard let match else { return }
                let range = NSRange(location: cursor, length: match.range.location - cursor)
                parts.append(nsText.substring(with: range))
                cursor = match.range.location + match.range.length
            }
            if cursor < nsText.length {
                let range = NSRange(location: cursor, length: nsText.length - cursor)
                parts.append(nsText.substring(with: range))
            }
            chunks = parts
        } else {
            chunks = [normalized]
        }
        return chunks.compactMap { chunk -> Block? in
            let trimmed = chunk
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return .paragraph(runs: [InlineRun(trimmed)])
        }
    }

    // MARK: - markdown

    private func ingestMarkdown(url: URL, title: String, language: BCP47) throws -> Book {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.unreadable
        }
        let blocks = parseMarkdown(text)
        // Promote the first H1's text to the book title when present
        // — feels less surprising than "Untitled" for files that the
        // user clearly intended as a single-piece document.
        let docTitle: String
        if case let .heading(level, runs)? = blocks.first, level == 1 {
            let h1Text = runs.map(\.text).joined()
                .trimmingCharacters(in: .whitespaces)
            docTitle = h1Text.isEmpty ? title : h1Text
        } else {
            docTitle = title
        }
        let chapter = Chapter(title: docTitle, blocks: blocks)
        return Book(title: docTitle, language: language, chapters: [chapter])
    }

    /// Minimal Markdown parser: ATX `# heading` lines, paragraphs
    /// (blank-line separated), `**bold**` / `*italic*` inline. Not a
    /// full CommonMark implementation — covers the commonly-used
    /// subset and keeps dependencies out of the package.
    func parseMarkdown(_ text: String) -> [Block] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ")
            let runs = parseInlineMarkdown(joined)
            if !runs.isEmpty { blocks.append(.paragraph(runs: runs)) }
            paragraph.removeAll(keepingCapacity: true)
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if let heading = parseATXHeading(line) {
                flush()
                let runs = parseInlineMarkdown(heading.text)
                if !runs.isEmpty {
                    blocks.append(.heading(level: heading.level, runs: runs))
                }
                continue
            }
            paragraph.append(raw)
        }
        flush()
        return blocks
    }

    /// Match ATX-style heading: 1–6 `#` chars followed by a space
    /// (or end-of-line). Trailing `#`s are stripped per CommonMark.
    private func parseATXHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0 else { return nil }
        // Either end-of-line (empty heading) or a single space.
        if idx == line.endIndex { return (level, "") }
        guard line[idx] == " " else { return nil }
        var rest = String(line[line.index(after: idx)...])
        // Strip trailing space + optional `#` run.
        while rest.last?.isWhitespace == true { rest.removeLast() }
        while rest.last == "#" { rest.removeLast() }
        while rest.last?.isWhitespace == true { rest.removeLast() }
        return (level, rest)
    }

    /// Parse `***bold-italic***`, `**bold**`, `*italic*` spans (no
    /// nesting beyond the combined-emphasis triple). Anything else
    /// passes through as plain. We deliberately ignore lists, code
    /// fences, blockquotes, and link syntax for this iteration —
    /// those land in the EPUB as plain prose and we can extend
    /// later if needed.
    func parseInlineMarkdown(_ text: String) -> [InlineRun] {
        guard !text.isEmpty else { return [] }
        var spans: [Span] = []

        // Combined bold+italic first so `***x***` doesn't parse as
        // bold("*x") + plain("*").
        addMatches(
            pattern: #"\*\*\*(.+?)\*\*\*"#,
            in: text, bold: true, italic: true, spans: &spans
        )
        addMatches(
            pattern: #"\*\*(.+?)\*\*"#,
            in: text, bold: true, italic: false, spans: &spans
        )
        addMatches(
            pattern: #"(?<![\*])\*([^*\s][^*]*?[^*\s]|[^*\s])\*(?!\*)"#,
            in: text, bold: false, italic: true, spans: &spans
        )

        spans.sort { $0.range.lowerBound < $1.range.lowerBound }
        var runs: [InlineRun] = []
        var cursor = text.startIndex
        for span in spans {
            // Skip spans that overlap an earlier-emitted span — the
            // sort + cursor check naturally handles this since
            // `cursor` advances past already-consumed text.
            if span.range.lowerBound < cursor { continue }
            if cursor < span.range.lowerBound {
                let plain = String(text[cursor..<span.range.lowerBound])
                if !plain.isEmpty { runs.append(InlineRun(plain)) }
            }
            runs.append(InlineRun(span.inner, isItalic: span.italic, isBold: span.bold))
            cursor = span.range.upperBound
        }
        if cursor < text.endIndex {
            let tail = String(text[cursor...])
            if !tail.isEmpty { runs.append(InlineRun(tail)) }
        }
        return runs
    }

    private struct Span {
        let range: Range<String.Index>
        let inner: String
        let bold: Bool
        let italic: Bool
    }

    private func addMatches(
        pattern: String,
        in text: String,
        bold: Bool,
        italic: Bool,
        spans: inout [Span]
    ) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        re.enumerateMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) { match, _, _ in
            guard let match,
                  let r = Range(match.range, in: text),
                  let inner = Range(match.range(at: 1), in: text)
            else { return }
            // Reject overlap with a higher-precedence span we already
            // recorded (e.g. `**...**` shouldn't double-claim a
            // region inside `***...***`).
            if spans.contains(where: { $0.range.overlaps(r) }) { return }
            spans.append(Span(
                range: r,
                inner: String(text[inner]),
                bold: bold,
                italic: italic
            ))
        }
    }

    // MARK: - rich text (RTF / HTML / DOC / DOCX / ODT)

    /// Read any format `NSAttributedString` understands natively and
    /// walk paragraphs into `Book` blocks. Heading detection +
    /// italic / bold inference are shared with the RTF path; HTML
    /// `<h1>`–`<h6>`, RTF style "Heading 1", and DOCX heading styles
    /// all populate `NSParagraphStyle.headerLevel`, so the same
    /// downstream logic catches them.
    private func ingestAttributedDocument(
        url: URL,
        title: String,
        language: BCP47,
        documentType: NSAttributedString.DocumentType
    ) throws -> Book {
        var docAttrs: NSDictionary? = nil
        let attr: NSAttributedString
        do {
            attr = try NSAttributedString(
                url: url,
                options: [.documentType: documentType],
                documentAttributes: &docAttrs
            )
        } catch {
            throw Failure.unreadable
        }
        let blocks = blocksFromAttributedString(attr)
        let docTitle = (docAttrs?[NSAttributedString.DocumentAttributeKey.title] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? title
        let chapter = Chapter(title: docTitle, blocks: blocks)
        return Book(title: docTitle, language: language, chapters: [chapter])
    }

    /// Walk an `NSAttributedString` paragraph by paragraph, mapping
    /// each to a `Block`. Heading detection: paragraph-style
    /// `headerLevel` > 0. Inline emphasis: per-character `.font`
    /// symbolic traits (`.italic`, `.bold`).
    func blocksFromAttributedString(_ attr: NSAttributedString) -> [Block] {
        var blocks: [Block] = []
        let str = attr.string as NSString
        let fullRange = NSRange(location: 0, length: str.length)
        str.enumerateSubstrings(
            in: fullRange,
            options: [.byParagraphs]
        ) { _, paragraphRange, _, _ in
            guard paragraphRange.length > 0 else { return }
            let paragraph = attr.attributedSubstring(from: paragraphRange)
            if paragraph.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            let runs = inlineRuns(from: paragraph)
            if runs.isEmpty { return }
            let pStyle = paragraph.attribute(
                .paragraphStyle, at: 0, effectiveRange: nil
            ) as? NSParagraphStyle
            let level = pStyle?.headerLevel ?? 0
            if level > 0 {
                blocks.append(.heading(
                    level: max(1, min(6, level)),
                    runs: runs
                ))
            } else {
                blocks.append(.paragraph(runs: runs))
            }
        }
        return blocks
    }

    private func inlineRuns(from paragraph: NSAttributedString) -> [InlineRun] {
        var runs: [InlineRun] = []
        let fullRange = NSRange(location: 0, length: paragraph.length)
        paragraph.enumerateAttribute(
            .font, in: fullRange
        ) { value, range, _ in
            let font = value as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let isItalic = traits.contains(.italic)
            let isBold = traits.contains(.bold)
            var text = (paragraph.string as NSString).substring(with: range)
            // Squash hard-wrap inside a paragraph; paragraph splits
            // already happened upstream via .byParagraphs.
            text = text.replacingOccurrences(of: "\n", with: " ")
            if text.isEmpty { return }
            // Merge with previous run when style flags match — keeps
            // the resulting <p> from fragmenting into many <em>/<strong>
            // wrappers when the source had character-level attribute
            // changes that didn't actually change the visible style.
            if let last = runs.last,
               last.isItalic == isItalic, last.isBold == isBold,
               last.language == nil, last.noterefId == nil {
                runs[runs.count - 1].text += text
            } else {
                runs.append(InlineRun(text, isItalic: isItalic, isBold: isBold))
            }
        }
        // Strip leading/trailing whitespace from the boundary runs.
        if !runs.isEmpty {
            runs[0].text = runs[0].text.drop(while: { $0.isWhitespace }).description
            var tail = runs[runs.count - 1].text
            while tail.last?.isWhitespace == true { tail.removeLast() }
            runs[runs.count - 1].text = tail
            runs.removeAll { $0.text.isEmpty }
        }
        return runs
    }
}
