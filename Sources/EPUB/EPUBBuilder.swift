import Foundation
import Document

/// Top-level builder: takes a canonical `Book` and produces a valid EPUB 3
/// file at the given URL. Wires together XHTMLWriter / OPFWriter /
/// NavWriter / EPUBPackager. This is the only EPUB type callers should
/// need to touch.
public struct EPUBBuilder {
    public var packager: EPUBPackager
    public var modificationDate: Date

    public init(packager: EPUBPackager = .init(), modificationDate: Date = Date()) {
        self.packager = packager
        self.modificationDate = modificationDate
    }

    public func write(
        book: Book,
        correctionTrail: CorrectionTrail? = nil,
        parsedTOC: ParsedTOC? = nil,
        to outputURL: URL
    ) throws {
        // Layout inside the ZIP:
        //   mimetype                      (uncompressed, first)
        //   META-INF/container.xml
        //   META-INF/com.humanist.correction-trail.json (if any entries)
        //   OEBPS/content.opf
        //   OEBPS/nav.xhtml
        //   OEBPS/css/book.css
        //   OEBPS/text/chapter-001.xhtml ...
        //   OEBPS/images/fig-NNNNN.png    (Phase 6 figures)

        var entries: [EPUBPackager.Entry] = []

        // 1. mimetype — must be first, uncompressed, exact bytes.
        entries.append(EPUBPackager.Entry(
            path: "mimetype",
            data: Data(EPUBStaticFiles.mimetype.utf8),
            compressed: false
        ))

        // 2. container.xml
        entries.append(EPUBPackager.Entry(
            path: "META-INF/container.xml",
            data: Data(EPUBStaticFiles.containerXML.utf8)
        ))

        // 3. CSS
        entries.append(EPUBPackager.Entry(
            path: "OEBPS/css/book.css",
            data: Data(EPUBStaticFiles.bookCSS.utf8)
        ))

        // 4. Chapters — XHTML files
        let xhtmlWriter = XHTMLWriter(cssPath: "../css/book.css")
        var chapterItems: [OPFWriter.Item] = []
        var pageMapEntries: [PageMap.Entry] = []
        // Asset id → manifest item, deduped across chapters. A figure
        // can in principle be referenced from multiple chapters
        // (today: it cannot, because each chapter owns its own asset
        // copy from ChapterSplitter — but the dedup still protects
        // against id collisions and duplicate manifest entries).
        var imageItemsById: [String: OPFWriter.Item] = [:]
        for (index, chapter) in book.chapters.enumerated() {
            let id = String(format: "chapter-%03d", index + 1)
            let href = "text/\(id).xhtml"
            let xhtml = xhtmlWriter.render(
                chapter,
                defaultLanguage: book.language,
                fallbackTitle: chapter.title ?? "Chapter \(index + 1)"
            )
            entries.append(EPUBPackager.Entry(
                path: "OEBPS/\(href)",
                data: Data(xhtml.utf8)
            ))
            chapterItems.append(OPFWriter.Item(
                id: id, href: href, mediaType: "application/xhtml+xml", properties: nil
            ))
            for anchor in chapter.pageAnchors {
                pageMapEntries.append(PageMap.Entry(
                    pdfPage: anchor.pdfPage,
                    xhtmlFile: "OEBPS/\(href)",
                    anchorId: anchor.anchorId
                ))
            }
            for asset in chapter.figureAssets {
                let imageHref = "images/\(asset.id).\(asset.fileExtension)"
                // Only emit bytes + manifest entry once per asset id.
                guard imageItemsById[asset.id] == nil else { continue }
                entries.append(EPUBPackager.Entry(
                    path: "OEBPS/\(imageHref)",
                    data: asset.data
                ))
                imageItemsById[asset.id] = OPFWriter.Item(
                    id: asset.id,
                    href: imageHref,
                    mediaType: asset.mediaType,
                    properties: asset.isCover ? "cover-image" : nil
                )
            }
        }
        // Sort by id for deterministic OPF output (eases EPUB diff /
        // snapshot tests).
        let imageItems = imageItemsById
            .sorted { $0.key < $1.key }
            .map { $0.value }

        // 4b. Editor-only pagemap sidecar — only emitted when at least
        // one chapter contributed anchors (i.e. the book came through
        // the OCR pipeline). Standard EPUB readers ignore unknown
        // META-INF files, so this round-trips through other tools.
        if !pageMapEntries.isEmpty {
            let pageMap = PageMap(entries: pageMapEntries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(pageMap) {
                entries.append(EPUBPackager.Entry(
                    path: PageMap.pathInsideEPUB,
                    data: data
                ))
            }
        }

        // 4c. Editor-only correction trail sidecar — Haiku post-OCR
        // cleanup decisions per region. Same META-INF treatment as
        // the pagemap. Skipped when the conversion didn't run cleanup
        // or no regions tripped the trigger.
        if let trail = correctionTrail, !trail.entries.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(trail) {
                entries.append(EPUBPackager.Entry(
                    path: CorrectionTrail.pathInsideEPUB,
                    data: data
                ))
            }
        }

        // 4d. Parsed-TOC sidecar — Haiku-driven TOC parse. Same
        // META-INF treatment. Persisted regardless of whether title
        // override succeeded so the editor can show the original
        // parsed list independently of how it landed in nav.xhtml.
        if let toc = parsedTOC, !toc.entries.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(toc) {
                entries.append(EPUBPackager.Entry(
                    path: ParsedTOC.pathInsideEPUB,
                    data: data
                ))
            }
        }

        // 5. nav.xhtml
        let navItem = OPFWriter.Item(
            id: "nav", href: "nav.xhtml", mediaType: "application/xhtml+xml", properties: "nav"
        )
        let navEntries = chapterItems.enumerated().map { (i, item) in
            NavWriter.Entry(
                title: book.chapters[i].title ?? "Chapter \(i + 1)",
                href: item.href
            )
        }
        let navXML = NavWriter(language: book.language, title: book.title, entries: navEntries).render()
        entries.append(EPUBPackager.Entry(
            path: "OEBPS/nav.xhtml",
            data: Data(navXML.utf8)
        ))

        // 6. content.opf
        let cssItem = OPFWriter.Item(id: "css", href: "css/book.css", mediaType: "text/css", properties: nil)
        let opf = OPFWriter(
            book: book,
            chapterItems: chapterItems,
            navItem: navItem,
            cssItem: cssItem,
            imageItems: imageItems,
            modificationDate: modificationDate
        ).render()
        entries.append(EPUBPackager.Entry(
            path: "OEBPS/content.opf",
            data: Data(opf.utf8)
        ))

        try packager.write(entries, to: outputURL)
    }
}
