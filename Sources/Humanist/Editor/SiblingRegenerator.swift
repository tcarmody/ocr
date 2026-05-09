import Foundation
import AppKit
import Document
import EPUB
import Pipeline

/// Re-emit sibling outputs for an EPUB the user has just edited and
/// saved, so corrections made in the editor flow back to linked
/// exports. Only writes to paths that already exist on disk —
/// respects the user's earlier "emit" choices without re-enabling
/// something they turned off.
enum SiblingRegenerator {

    static func regenerateExisting(for epubBook: EPUBBook, epubURL: URL) async {
        let book = await Task.detached(priority: .userInitiated) {
            extractBook(from: epubBook, fallbackTitle: epubURL
                .deletingPathExtension().lastPathComponent)
        }.value

        // Build all payloads upfront; only write the ones whose
        // files already exist on disk.
        let txt  = PlainTextWriter.render(book)
        let md   = MarkdownWriter.render(book)
        let html = HTMLWriter.render(book)

        let textPayload: [SiblingFormat: String] = [.txt: txt, .md: md, .html: html]

        for candidate in candidateSiblingURLs(for: epubURL) {
            guard FileManager.default.fileExists(atPath: candidate.url.path) else { continue }
            if candidate.format == .docx {
                try? DOCXWriter.write(book, to: candidate.url)
            } else if let body = textPayload[candidate.format] {
                try? body.write(to: candidate.url, atomically: true, encoding: .utf8)
            }
        }
    }

    enum SiblingFormat { case txt, md, html, docx }

    private struct Candidate {
        let format: SiblingFormat
        let url: URL
    }

    private static func candidateSiblingURLs(for epubURL: URL) -> [Candidate] {
        var out: [Candidate] = []
        let base   = epubURL.deletingPathExtension().lastPathComponent
        let parent = epubURL.deletingLastPathComponent()
        out.append(Candidate(format: .txt,  url: parent.appendingPathComponent("\(base).txt")))
        out.append(Candidate(format: .md,   url: parent.appendingPathComponent("\(base).md")))
        out.append(Candidate(format: .html, url: parent.appendingPathComponent("\(base).html")))
        out.append(Candidate(format: .docx, url: parent.appendingPathComponent("\(base).docx")))
        if let root = ConversionOutputResolver.currentRoot() {
            out.append(Candidate(format: .txt, url: root
                .appendingPathComponent(ConversionOutputSubfolder.textFiles, isDirectory: true)
                .appendingPathComponent("\(base).txt")))
            out.append(Candidate(format: .md, url: root
                .appendingPathComponent(ConversionOutputSubfolder.markdown, isDirectory: true)
                .appendingPathComponent("\(base).md")))
            out.append(Candidate(format: .html, url: root
                .appendingPathComponent(ConversionOutputSubfolder.html, isDirectory: true)
                .appendingPathComponent("\(base).html")))
            out.append(Candidate(format: .docx, url: root
                .appendingPathComponent(ConversionOutputSubfolder.docx, isDirectory: true)
                .appendingPathComponent("\(base).docx")))
        }
        return out
    }

    /// Convert the editable in-memory `EPUBBook` into the canonical
    /// `Book` IR the sibling writers expect. Each spine resource's
    /// XHTML gets parsed via `NSAttributedString` and walked by
    /// `DocumentIngest.blocksFromAttributedString` — same parser the
    /// rich-text input ingest uses, so emphasis / heading levels
    /// round-trip the same way.
    private static func extractBook(
        from epubBook: EPUBBook,
        fallbackTitle: String
    ) -> Book {
        var chapters: [Chapter] = []
        let ingest = DocumentIngest()
        for resourceID in epubBook.spine {
            guard let resource = epubBook.resourcesByID[resourceID] else { continue }
            guard let xhtml = resource.text else { continue }
            chapters.append(parseChapter(xhtml: xhtml, ingest: ingest))
        }
        let language = BCP47(epubBook.metadata.language ?? "en")
        let title = epubBook.metadata.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? fallbackTitle
        return Book(
            title: title,
            author: epubBook.metadata.author,
            language: language,
            chapters: chapters
        )
    }

    private static func parseChapter(xhtml: String, ingest: DocumentIngest) -> Chapter {
        guard let data = xhtml.data(using: .utf8),
              let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
              ) else {
            return Chapter(blocks: [.paragraph(runs: [InlineRun(xhtml)])])
        }
        let blocks = ingest.blocksFromAttributedString(attr)
        // Promote the first H1 to chapter title — matches what
        // ChapterHierarchy / TOC use as the navigable label.
        var title: String? = nil
        for block in blocks {
            if case let .heading(level, runs) = block, level == 1 {
                let candidate = runs.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    title = candidate
                    break
                }
            }
        }
        return Chapter(title: title, blocks: blocks)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
