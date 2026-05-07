import Foundation
import Document

/// Splits a single EPUB into multiple EPUBs by chapter range. Each
/// part inherits the source's metadata; titles get a "Part N of M"
/// suffix so the user can tell them apart in their library.
///
/// Image resources referenced by any chapter in a part are duplicated
/// into that part's manifest so each part is self-contained. Chapters
/// that fall outside any range are dropped from the split output —
/// the user picks what to keep.
///
/// Cross-chapter internal links inside the source whose target lands
/// in a different output part will dangle (we don't rewrite them);
/// the simpler same-part references continue to work because the
/// chapter file's relative path stays the same within its part.
public struct EPUBSplitter {

    public init() {}

    public enum SplitError: Error, LocalizedError {
        case sourceFailed(URL, underlying: Error)
        case emptyParts
        case invalidChapterIndex(Int, total: Int)
        case packagingFailed(part: Int, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .sourceFailed(let url, let err):
                return "Couldn't open \(url.lastPathComponent): \(err.localizedDescription)"
            case .emptyParts:
                return "Pick at least one chapter range to extract."
            case .invalidChapterIndex(let i, let total):
                return "Chapter index \(i) is outside this EPUB (which has \(total) chapters)."
            case .packagingFailed(let part, let err):
                return "Couldn't write part \(part + 1): \(err.localizedDescription)"
            }
        }
    }

    public struct Part {
        /// 0-based indexes into the source spine that this part
        /// includes. Order is preserved from the source.
        public let chapterIndexes: [Int]
        /// Title used for this part's metadata + nav. Defaults to
        /// `<source title> (Part N of M)`.
        public let title: String?

        public init(chapterIndexes: [Int], title: String? = nil) {
            self.chapterIndexes = chapterIndexes
            self.title = title
        }
    }

    public struct SplitResult {
        public let outputURLs: [URL]
        public let totalChapters: Int
    }

    /// Split `sourceURL` into `parts`, writing each to a sibling of
    /// `outputDirectory` named `<sourceStem> Part N.epub`.
    @discardableResult
    public func split(
        sourceURL: URL,
        outputDirectory: URL,
        parts: [Part]
    ) throws -> SplitResult {
        guard !parts.isEmpty else { throw SplitError.emptyParts }
        let book: EPUBBook
        do {
            book = try EPUBBook.open(epubURL: sourceURL)
        } catch {
            throw SplitError.sourceFailed(sourceURL, underlying: error)
        }
        // Validate indexes up-front.
        let totalChapters = book.spine.count
        for part in parts {
            for idx in part.chapterIndexes {
                if idx < 0 || idx >= totalChapters {
                    throw SplitError.invalidChapterIndex(idx, total: totalChapters)
                }
            }
        }

        let sourceStem = sourceURL.deletingPathExtension().lastPathComponent
        var outputURLs: [URL] = []
        var totalEmitted = 0

        for (partIdx, part) in parts.enumerated() {
            let partTitle = part.title?.nonEmptyTrimmed
                ?? "\(book.metadata.title?.nonEmptyTrimmed ?? sourceStem) (Part \(partIdx + 1) of \(parts.count))"
            let outName = "\(sourceStem) Part \(partIdx + 1).epub"
            let outURL = outputDirectory.appendingPathComponent(outName)
            do {
                try writePart(
                    book: book,
                    chapterIndexes: part.chapterIndexes,
                    title: partTitle,
                    outputURL: outURL
                )
            } catch {
                throw SplitError.packagingFailed(part: partIdx, underlying: error)
            }
            outputURLs.append(outURL)
            totalEmitted += part.chapterIndexes.count
        }

        return SplitResult(outputURLs: outputURLs, totalChapters: totalEmitted)
    }

    // MARK: - Single-part write

    private func writePart(
        book: EPUBBook,
        chapterIndexes: [Int],
        title: String,
        outputURL: URL
    ) throws {
        // Look up the spine resource for each requested index. Order
        // is whatever the caller passed (typically ascending, but
        // we don't enforce — it's the user's prerogative to reorder
        // within a part).
        var partChapterResources: [Resource] = []
        for idx in chapterIndexes {
            let resourceID = book.spine[idx]
            if let resource = book.resourcesByID[resourceID] {
                partChapterResources.append(resource)
            }
        }

        // Determine which images each chapter references so the part
        // includes only the ones it needs. We grep `src=` and `href=`
        // attributes against the source manifest's image hrefs.
        let allImageResources = book.orderedResources.filter {
            Self.isImageMediaType($0.mediaType)
        }
        var referencedImages: Set<String> = []  // resource IDs
        for chapter in partChapterResources {
            guard let chapterText = chapter.text else { continue }
            for image in allImageResources {
                let imgName = image.hrefRelativeToOPF
                    .components(separatedBy: "/").last ?? image.hrefRelativeToOPF
                if chapterText.contains(imgName) {
                    referencedImages.insert(image.id)
                }
            }
        }

        // Build entries.
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

        var chapterItems: [OPFWriter.Item] = []
        var imageItems: [OPFWriter.Item] = []
        var navTitlesAndHrefs: [(title: String, href: String)] = []

        for (i, chapter) in partChapterResources.enumerated() {
            let item = OPFWriter.Item(
                id: chapter.id,
                href: chapter.hrefRelativeToOPF,
                mediaType: chapter.mediaType,
                properties: chapter.properties
            )
            chapterItems.append(item)
            let chapterTitle = PackageEditor.firstHeadingTitle(in: chapter.text ?? "")
                ?? "Chapter \(i + 1)"
            navTitlesAndHrefs.append((title: chapterTitle, href: chapter.hrefRelativeToOPF))
            entries.append(.init(
                path: "OEBPS/\(chapter.hrefRelativeToOPF)",
                data: Self.bytes(of: chapter)
            ))
        }

        for image in allImageResources where referencedImages.contains(image.id) {
            imageItems.append(.init(
                id: image.id,
                href: image.hrefRelativeToOPF,
                mediaType: image.mediaType,
                properties: image.properties
            ))
            entries.append(.init(
                path: "OEBPS/\(image.hrefRelativeToOPF)",
                data: Self.bytes(of: image)
            ))
        }

        let language = book.metadata.language
            .flatMap { BCP47(rawValue: $0) } ?? .en
        let metaBook = Book(
            title: title,
            author: book.metadata.author,
            language: language,
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
        let opf = OPFWriter(
            book: metaBook,
            chapterItems: chapterItems,
            navItem: navItem,
            cssItem: cssItem,
            imageItems: imageItems,
            modificationDate: Date()
        ).render()
        entries.append(.init(
            path: "OEBPS/content.opf",
            data: Data(opf.utf8)
        ))

        let navEntries = navTitlesAndHrefs.map {
            NavWriter.Entry(title: $0.title, href: $0.href)
        }
        let nav = NavWriter(
            language: language, title: title, entries: navEntries
        ).render()
        entries.append(.init(
            path: "OEBPS/nav.xhtml",
            data: Data(nav.utf8)
        ))

        try EPUBPackager().write(entries, to: outputURL)
    }

    // MARK: - Helpers

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
