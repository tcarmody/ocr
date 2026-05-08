import Foundation
import AppKit
import Document
import EPUB
import Pipeline

/// Re-emit sibling text outputs (`.txt`, `.md`, `.html`) for an
/// EPUB the user has just edited and saved, so corrections made
/// in the editor flow back through to the linked exports.
///
/// Only writes to paths that already exist on disk — that respects
/// the user's earlier choices (sibling toggle off at conversion
/// time, or sibling files manually deleted later). Never creates
/// new sibling files post-hoc.
enum SiblingRegenerator {

    /// Regenerate any siblings that exist for `epubURL`, derived
    /// from the current in-memory `EPUBBook`. Best-effort — this
    /// runs after a successful save, so surface failures to the
    /// log but don't fail the save.
    static func regenerateExisting(for epubBook: EPUBBook, epubURL: URL) async {
        let book = await Task.detached(priority: .userInitiated) {
            extractBook(from: epubBook, fallbackTitle: epubURL
                .deletingPathExtension().lastPathComponent)
        }.value
        let txt = PlainTextWriter.render(book)
        let md = MarkdownWriter.render(book)
        let html = HTMLWriter.render(book)
        let payload: [SiblingFormat: String] = [
            .txt: txt, .md: md, .html: html,
        ]
        for candidate in candidateSiblingURLs(for: epubURL) {
            guard FileManager.default.fileExists(atPath: candidate.url.path) else {
                continue
            }
            guard let body = payload[candidate.format] else { continue }
            try? body.write(to: candidate.url, atomically: true, encoding: .utf8)
        }
    }

    enum SiblingFormat { case txt, md, html }

    private struct Candidate {
        let format: SiblingFormat
        let url: URL
    }

    /// All URLs we'll consider regenerating: next to the EPUB and,
    /// when a configured output folder is set, in its per-format
    /// subfolders. Both locations get checked because the user may
    /// have moved the EPUB out of the configured tree, or run
    /// without a configured tree at all.
    private static func candidateSiblingURLs(for epubURL: URL) -> [Candidate] {
        var out: [Candidate] = []
        let basename = epubURL.deletingPathExtension().lastPathComponent
        let parent = epubURL.deletingLastPathComponent()
        out.append(Candidate(format: .txt, url: parent.appendingPathComponent("\(basename).txt")))
        out.append(Candidate(format: .md, url: parent.appendingPathComponent("\(basename).md")))
        out.append(Candidate(format: .html, url: parent.appendingPathComponent("\(basename).html")))
        if let root = ConversionOutputResolver.currentRoot() {
            out.append(Candidate(
                format: .txt,
                url: root
                    .appendingPathComponent(ConversionOutputSubfolder.textFiles, isDirectory: true)
                    .appendingPathComponent("\(basename).txt")
            ))
            out.append(Candidate(
                format: .md,
                url: root
                    .appendingPathComponent(ConversionOutputSubfolder.markdown, isDirectory: true)
                    .appendingPathComponent("\(basename).md")
            ))
            out.append(Candidate(
                format: .html,
                url: root
                    .appendingPathComponent(ConversionOutputSubfolder.html, isDirectory: true)
                    .appendingPathComponent("\(basename).html")
            ))
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
