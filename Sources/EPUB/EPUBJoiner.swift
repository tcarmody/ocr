import Foundation
import Document

/// Concatenates multiple EPUBs into one. Each source's chapters land
/// in their own `book-NN/` subdirectory of the merged EPUB so files
/// from different sources don't collide; spines are concatenated in
/// input order; a fresh nav is generated from the combined chapter
/// list. Source #1's metadata (title, author, language) wins unless
/// `title` is supplied.
///
/// Cross-source internal links are not rewritten — a `<a href=
/// "ch02.xhtml">` inside book #1 still resolves correctly because
/// it's same-directory; a hypothetical `<a href="../book-2/...">`
/// would never appear naturally so we don't fix it. Within-source
/// links (across chapters in the same source) are preserved
/// verbatim because they live in the same `book-NN/` directory and
/// the relative paths still resolve.
public struct EPUBJoiner {

    public init() {}

    public enum JoinError: Error, LocalizedError {
        case noInput
        case sourceFailed(URL, underlying: Error)
        case packagingFailed(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .noInput:
                return "Pick at least one EPUB to join."
            case .sourceFailed(let url, let err):
                return "Couldn't open \(url.lastPathComponent): \(err.localizedDescription)"
            case .packagingFailed(let err):
                return "Couldn't write the merged EPUB: \(err.localizedDescription)"
            }
        }
    }

    /// Result of a join. Useful for surfacing in the UI.
    public struct JoinResult {
        public let outputURL: URL
        public let chapterCount: Int
        public let sourceCount: Int
    }

    /// Join `sourceURLs` into a single EPUB at `outputURL`.
    ///
    /// `title` overrides the merged book's title; nil keeps source
    /// #1's title. Source #1's author and language are also used.
    @discardableResult
    public func join(
        sourceURLs: [URL],
        outputURL: URL,
        title: String? = nil
    ) throws -> JoinResult {
        guard !sourceURLs.isEmpty else { throw JoinError.noInput }

        // Open every source. Each book owns its own working directory
        // (cleanup happens via deinit); we drop them at the end of
        // this function automatically.
        var books: [EPUBBook] = []
        for url in sourceURLs {
            do {
                books.append(try EPUBBook.open(epubURL: url))
            } catch {
                throw JoinError.sourceFailed(url, underlying: error)
            }
        }

        // Build the entry list for EPUBPackager. The mimetype must
        // be first + uncompressed (EPUB requirement); after that the
        // order doesn't matter.
        var entries: [EPUBPackager.Entry] = []
        entries.append(.init(
            path: "mimetype",
            data: Data(EPUBStaticFiles.mimetype.utf8),
            compressed: false
        ))
        entries.append(.init(
            path: "META-INF/container.xml",
            data: Data(EPUBStaticFiles.containerXML.utf8)
        ))
        entries.append(.init(
            path: "OEBPS/css/book.css",
            data: Data(EPUBStaticFiles.bookCSS.utf8)
        ))

        // Walk each source, prefix every resource's path with
        // `book-NN/`, accumulate manifest items + spine.
        var chapterItems: [OPFWriter.Item] = []
        var imageItems: [OPFWriter.Item] = []
        var otherTextItems: [OPFWriter.Item] = []
        var navTitlesAndHrefs: [(title: String, href: String)] = []
        var totalChapters = 0

        for (bookIdx, book) in books.enumerated() {
            let prefix = "book-\(String(format: "%02d", bookIdx + 1))"
            for resource in book.orderedResources {
                if resource.isNav { continue }
                let prefixedHref = "\(prefix)/\(resource.hrefRelativeToOPF)"
                let prefixedID = "\(prefix)-\(resource.id)"
                let item = OPFWriter.Item(
                    id: prefixedID,
                    href: prefixedHref,
                    mediaType: resource.mediaType,
                    properties: resource.properties
                )

                let isChapter = book.spine.contains(resource.id)
                if isChapter {
                    chapterItems.append(item)
                    let chapterTitle = chapterTitle(
                        from: resource,
                        fallback: "Chapter \(totalChapters + 1)"
                    )
                    navTitlesAndHrefs.append((title: chapterTitle, href: prefixedHref))
                    totalChapters += 1
                } else if Self.isImageMediaType(resource.mediaType) {
                    imageItems.append(item)
                } else {
                    otherTextItems.append(item)
                }

                let bytes = Self.bytes(of: resource)
                entries.append(.init(
                    path: "OEBPS/\(prefixedHref)",
                    data: bytes
                ))
            }
        }

        // Build a synthetic Document.Book just so OPFWriter has
        // metadata to serialize. Source #1's metadata wins.
        let firstMeta = books.first?.metadata
        let resolvedTitle = title?.nonEmptyTrimmed
            ?? firstMeta?.title?.nonEmptyTrimmed
            ?? "Joined Book"
        let resolvedLanguage = firstMeta?.language
            .flatMap { BCP47(rawValue: $0) } ?? .en
        let metaBook = Book(
            title: resolvedTitle,
            author: firstMeta?.author,
            language: resolvedLanguage,
            chapters: []
        )

        let navItem = OPFWriter.Item(
            id: "nav", href: "nav.xhtml",
            mediaType: "application/xhtml+xml", properties: "nav"
        )
        let cssItem = OPFWriter.Item(
            id: "book-css", href: "css/book.css",
            mediaType: "text/css", properties: nil
        )

        // Render the OPF. We pipe `otherTextItems` through `imageItems`
        // because OPFWriter expects only chapter + image entries; CSS
        // and other ancillary text resources from the sources go
        // there to keep the manifest correct (the slot name is
        // misleading but the emitter is generic).
        let opf = OPFWriter(
            book: metaBook,
            chapterItems: chapterItems,
            navItem: navItem,
            cssItem: cssItem,
            imageItems: imageItems + otherTextItems,
            modificationDate: Date()
        ).render()
        entries.append(.init(
            path: "OEBPS/content.opf",
            data: Data(opf.utf8)
        ))

        // Render the nav.
        let navEntries = navTitlesAndHrefs.map {
            NavWriter.Entry(title: $0.title, href: $0.href)
        }
        let nav = NavWriter(
            language: resolvedLanguage,
            title: resolvedTitle,
            entries: navEntries
        ).render()
        entries.append(.init(
            path: "OEBPS/nav.xhtml",
            data: Data(nav.utf8)
        ))

        // Write.
        do {
            try EPUBPackager().write(entries, to: outputURL)
        } catch {
            throw JoinError.packagingFailed(underlying: error)
        }

        return JoinResult(
            outputURL: outputURL,
            chapterCount: totalChapters,
            sourceCount: books.count
        )
    }

    // MARK: - Helpers

    /// Pull a human chapter title from a resource. Tries the first
    /// `<h1>` / `<h2>` / `<h3>`, falls back to `fallback`.
    private func chapterTitle(from resource: Resource, fallback: String) -> String {
        guard let text = resource.text else { return fallback }
        return PackageEditor.firstHeadingTitle(in: text) ?? fallback
    }

    private static func bytes(of resource: Resource) -> Data {
        switch resource.content {
        case .text(let s):
            return Data(s.utf8)
        case .binary(let url):
            return (try? Data(contentsOf: url)) ?? Data()
        }
    }

    private static func isImageMediaType(_ mediaType: String) -> Bool {
        mediaType.lowercased().hasPrefix("image/")
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
