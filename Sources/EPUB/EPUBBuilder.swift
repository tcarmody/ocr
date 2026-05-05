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
        // Prefer the parsed TOC over heuristic chapters when it
        // has a confident inferred offset and at least one entry
        // resolves to a known page anchor — that gives readers a
        // structure that matches the printed book. Fall back to
        // one-entry-per-chapter when:
        //   * TOC parsing didn't run / produced nothing
        //   * the offset learner couldn't disambiguate
        //   * none of the TOC entries map into the pagemap
        // This is what closed the bug where a book with 1
        // heuristic chapter + a 20-entry printed TOC produced an
        // EPUB nav with only 1 entry.
        let navEntries = Self.makeNavEntries(
            chapters: book.chapters,
            chapterItems: chapterItems,
            pageMapEntries: pageMapEntries,
            parsedTOC: parsedTOC
        )
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

    /// Build the nav.xhtml entry list. Two paths:
    ///
    ///   * **Parsed-TOC path.** When `parsedTOC` has an inferred
    ///     offset and at least one entry resolves to a page anchor
    ///     in `pageMapEntries`, emit one nav entry per TOC entry
    ///     pointing to the matching `<chapter>.xhtml#hu-page-N`.
    ///     This is what users see when they enable Cloud Phase 6e
    ///     ("Parse printed TOC"): a navigation tree that mirrors
    ///     the book's printed contents.
    ///
    ///   * **Heuristic-chapter path.** When the parsed TOC is
    ///     missing or unresolvable, fall back to one entry per
    ///     chapter, pointing at the chapter file itself. Same as
    ///     the original implementation.
    static func makeNavEntries(
        chapters: [Chapter],
        chapterItems: [OPFWriter.Item],
        pageMapEntries: [PageMap.Entry],
        parsedTOC: ParsedTOC?
    ) -> [NavWriter.Entry] {
        if let nav = navEntriesFromParsedTOC(
            parsedTOC: parsedTOC,
            pageMapEntries: pageMapEntries
        ), !nav.isEmpty {
            return nav
        }
        return chapterItems.enumerated().map { (i, item) in
            NavWriter.Entry(
                title: chapters[i].title ?? "Chapter \(i + 1)",
                href: item.href
            )
        }
    }

    /// Compute nav entries directly from a parsed TOC. Returns nil
    /// when the inputs aren't usable (no TOC, no offset learned, no
    /// arabic-numeral entries). Entries whose display page doesn't
    /// resolve to a known anchor are dropped — keeping the entry
    /// without a working link would just produce a broken table-of-
    /// contents row in the reader.
    static func navEntriesFromParsedTOC(
        parsedTOC: ParsedTOC?,
        pageMapEntries: [PageMap.Entry]
    ) -> [NavWriter.Entry]? {
        guard let toc = parsedTOC,
              let offset = toc.inferredOffset,
              !toc.entries.isEmpty,
              !pageMapEntries.isEmpty
        else { return nil }
        // Resolve "anchor at this PDF page" via the pagemap. Some
        // anchors exist as exact entries; others may be off by one
        // page (a chapter that starts on a recto landed on the
        // verso anchor). Try exact first; ±1 fallback second.
        let byPDFPage = Dictionary(
            grouping: pageMapEntries, by: \.pdfPage
        )
        var nav: [NavWriter.Entry] = []
        for entry in toc.entries {
            guard let displayInt = entry.displayPageInt else { continue }
            let inferredPDF = displayInt + offset - 1
            // OPF chapter href is `text/chapter-001.xhtml`; pagemap
            // stores `OEBPS/text/chapter-001.xhtml`. Strip the
            // `OEBPS/` prefix so the nav href is relative to the
            // nav.xhtml file (which lives at OEBPS/nav.xhtml).
            let relativize = { (path: String) -> String in
                path.hasPrefix("OEBPS/")
                    ? String(path.dropFirst("OEBPS/".count))
                    : path
            }
            let resolved = byPDFPage[inferredPDF]?.first
                ?? byPDFPage[inferredPDF + 1]?.first
                ?? byPDFPage[inferredPDF - 1]?.first
            guard let mapEntry = resolved else { continue }
            let href = "\(relativize(mapEntry.xhtmlFile))#\(mapEntry.anchorId)"
            nav.append(NavWriter.Entry(title: entry.title, href: href))
        }
        return nav.isEmpty ? nil : nav
    }
}
