import Foundation
import AppKit
import Document

/// Renders a `Book` as a Microsoft Word DOCX file via
/// `NSAttributedString` with `DocumentType.officeOpenXML`.
/// Mirrors the PlainTextWriter / MarkdownWriter / HTMLWriter
/// sibling-output pattern but produces a binary document the user
/// can open directly in Word, Pages, or Google Docs.
public enum DOCXWriter {

    public enum WriteError: Error, LocalizedError {
        case encodingFailed
        public var errorDescription: String? {
            "Could not encode DOCX data from the book."
        }
    }

    /// Build and write a `.docx` file to `url`.
    public static func write(_ book: Book, to url: URL) throws {
        let attr = attributedString(from: book)
        let docAttrs: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML,
        ]
        let data: Data
        do {
            data = try attr.data(
                from: NSRange(location: 0, length: attr.length),
                documentAttributes: docAttrs
            )
        } catch {
            throw WriteError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Build attributed string

    private static func attributedString(from book: Book) -> NSAttributedString {
        let out = NSMutableAttributedString()

        // Title
        paragraph(out, book.title,
                  font: styledFont(size: 22, bold: true),
                  alignment: .center, spacingAfter: 4)

        // Author / year / publisher byline
        var bylineParts: [String] = []
        if let a = book.author, !a.isEmpty    { bylineParts.append(a) }
        if let y = book.year,   !y.isEmpty    { bylineParts.append(y) }
        if let p = book.publisher, !p.isEmpty { bylineParts.append(p) }
        if !bylineParts.isEmpty {
            paragraph(out, bylineParts.joined(separator: " · "),
                      font: styledFont(size: 12, italic: true),
                      alignment: .center, spacingAfter: 16)
        }

        // Chapters
        for chapter in book.chapters {
            if let title = chapter.title, !title.isEmpty {
                paragraph(out, title,
                          font: styledFont(size: 16, bold: true),
                          spacingBefore: 20, spacingAfter: 8)
            }
            for block in chapter.blocks {
                appendBlock(out, block)
            }
            // Footnotes at end of chapter, small text after a rule
            if !chapter.footnotes.isEmpty {
                paragraph(out, "──────────",
                          font: styledFont(size: 9), alignment: .center)
                for fn in chapter.footnotes {
                    let marker = fn.marker.isEmpty ? "*" : fn.marker
                    let text = fn.runs.map(\.text).joined()
                    paragraph(out, "\(marker). \(text)",
                              font: styledFont(size: 9), spacingAfter: 2)
                }
            }
            // Blank space between chapters
            paragraph(out, "", font: bodyFont, spacingAfter: 16)
        }

        return out
    }

    private static func appendBlock(
        _ out: NSMutableAttributedString, _ block: Block
    ) {
        switch block {
        case .heading(let level, let runs):
            let size: CGFloat = level == 1 ? 15 : level == 2 ? 13.5 : 12.5
            let str = NSMutableAttributedString(
                attributedString: inlineAttr(runs, base: styledFont(size: size, bold: true))
            )
            applyParagraphStyle(str, spacingBefore: 10, spacingAfter: 4)
            str.append(newline)
            out.append(str)

        case .paragraph(let runs):
            let str = NSMutableAttributedString(
                attributedString: inlineAttr(runs, base: bodyFont)
            )
            applyParagraphStyle(str, spacingAfter: 5)
            str.append(newline)
            out.append(str)

        case .figure(_, let alt, let captionRuns):
            let caption = captionRuns.map(\.text).joined()
            let label = caption.isEmpty ? "[\(alt)]" : "[\(alt) — \(caption)]"
            paragraph(out, label,
                      font: styledFont(size: 10, italic: true), spacingAfter: 4)

        case .table(let rows, let captionRuns):
            let cap = captionRuns.map(\.text).joined()
            if !cap.isEmpty {
                paragraph(out, cap,
                          font: styledFont(size: 10, bold: true, italic: true),
                          spacingAfter: 2)
            }
            for row in rows {
                let line = row.map { $0.runs.map(\.text).joined() }.joined(separator: "  │  ")
                paragraph(out, line, font: styledFont(size: 10))
            }
            paragraph(out, "", font: bodyFont, spacingAfter: 4)

        case .anchor:
            break // page-break anchors have no visible content in DOCX
        }
    }

    // MARK: - Inline attributes

    private static func inlineAttr(
        _ runs: [InlineRun], base: NSFont
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in runs {
            let f = styledFont(
                size: base.pointSize,
                bold: run.isBold,
                italic: run.isItalic,
                familyName: base.familyName
            )
            out.append(NSAttributedString(string: run.text, attributes: [.font: f]))
        }
        return out
    }

    // MARK: - Font helpers

    /// Computed (not stored) so the property doesn't trip Swift 6's
    /// non-Sendable-static check — NSFont isn't Sendable, and a
    /// `static let` of a non-Sendable type counts as shared mutable
    /// state. Lookup cost is a few nanoseconds; doesn't matter for a
    /// writer that runs once per book.
    private static var bodyFont: NSFont {
        NSFont.userFont(ofSize: 12) ?? NSFont.systemFont(ofSize: 12)
    }

    private static func styledFont(
        size: CGFloat,
        bold: Bool = false,
        italic: Bool = false,
        familyName: String? = nil
    ) -> NSFont {
        let base = (familyName.flatMap { NSFont(name: $0, size: size) })
            ?? NSFont.userFont(ofSize: size)
            ?? NSFont.systemFont(ofSize: size)
        guard bold || italic else { return base }
        var traits: NSFontTraitMask = []
        if bold   { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(
            withFamily: base.familyName ?? base.fontName,
            traits: traits,
            weight: bold ? 9 : 5,
            size: size
        ) ?? base
    }

    // MARK: - Paragraph helpers

    /// Same Sendable-static reasoning as `bodyFont` — NSAttributedString
    /// isn't Sendable, so we can't keep a stored static of one. Cost
    /// of recreating it is a single allocation; trivial.
    private static var newline: NSAttributedString {
        NSAttributedString(string: "\n")
    }

    private static func paragraph(
        _ out: NSMutableAttributedString,
        _ text: String,
        font: NSFont,
        alignment: NSTextAlignment = .natural,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0
    ) {
        let str = NSMutableAttributedString(
            string: text + "\n",
            attributes: [.font: font]
        )
        applyParagraphStyle(str,
            alignment: alignment,
            spacingBefore: spacingBefore,
            spacingAfter: spacingAfter)
        out.append(str)
    }

    private static func applyParagraphStyle(
        _ str: NSMutableAttributedString,
        alignment: NSTextAlignment = .natural,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0
    ) {
        let ps = NSMutableParagraphStyle()
        ps.alignment = alignment
        ps.paragraphSpacingBefore = spacingBefore
        ps.paragraphSpacing = spacingAfter
        str.addAttribute(.paragraphStyle, value: ps,
                         range: NSRange(location: 0, length: str.length))
    }
}
