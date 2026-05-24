import Foundation
import Document

/// Renders one `Chapter` to an XHTML string suitable for inclusion in an
/// EPUB 3 spine. Every inline run that has its own language tag emits
/// `<span xml:lang="..." lang="...">` so reader fonts and TTS can switch
/// scripts mid-paragraph.
struct XHTMLWriter {
    let cssPath: String  // relative path from chapter file to css, e.g. "../css/book.css"

    /// `subsectionAnchors[blockIndex]` carries the stable id to emit
    /// on `<hN>` so nav.xhtml can deep-link to that heading. Empty
    /// (the default) renders headings without ids — same behavior
    /// as before R-Hierarchy.
    ///
    /// `chapterIndex` is the 0-based spine position. Used to mint
    /// stable per-paragraph ids of the form `hu-p-{chapter}-{para}`
    /// so the editor can snap source ↔ preview at paragraph
    /// granularity (in addition to the page-level snap that the
    /// `hu-page-*` anchors already drive). `paraIdx` counts only
    /// paragraph blocks within the chapter (zero-based, in document
    /// order); other block kinds don't increment it.
    /// `facingPageMap` carries `anchorId → partner anchorId` for
    /// facing-page bilingual books. When a `Block.anchor`'s id has
    /// an entry, the emitted `<span epub:type="pagebreak">` gains
    /// a `data-facing-page="<partnerId>"` attribute. Empty (the
    /// default) means no bilingual layout was detected and no such
    /// attribute is emitted.
    func render(
        _ chapter: Chapter,
        defaultLanguage: BCP47,
        fallbackTitle: String,
        subsectionAnchors: [Int: String] = [:],
        chapterIndex: Int = 0,
        facingPageMap: [String: String] = [:]
    ) -> String {
        let title = (chapter.title ?? fallbackTitle)
        let langAttr = defaultLanguage.rawValue

        let assetIndex = Dictionary(
            uniqueKeysWithValues: chapter.figureAssets.map { ($0.id, $0) }
        )

        var body = ""
        var paraIdx = 0
        for (blockIndex, block) in chapter.blocks.enumerated() {
            switch block {
            case .heading(let level, let runs):
                let n = max(1, min(level, 6))
                let idAttr: String
                if let anchorId = subsectionAnchors[blockIndex], !anchorId.isEmpty {
                    idAttr = " id=\"\(XMLEscape.attribute(anchorId))\""
                } else {
                    idAttr = ""
                }
                body += "<h\(n)\(idAttr)>\(renderRuns(runs, parentLanguage: defaultLanguage))</h\(n)>\n"
            case .paragraph(let runs):
                let pid = "hu-p-\(chapterIndex)-\(paraIdx)"
                paraIdx += 1
                body += "<p id=\"\(XMLEscape.attribute(pid))\">\(renderRuns(runs, parentLanguage: defaultLanguage))</p>\n"
            case .anchor(let id, let label):
                // Empty span — invisible in normal rendering. The
                // editor's IntersectionObserver targets `[id^="hu-page-"]`
                // for back-sync; readers honor epub:type="pagebreak"
                // for "skip to page N" navigation.
                let idAttr = XMLEscape.attribute(id)
                let labelAttr = XMLEscape.attribute(label)
                var extra = ""
                if let partner = facingPageMap[id] {
                    extra = " data-facing-page=\"\(XMLEscape.attribute(partner))\""
                }
                body += "<span id=\"\(idAttr)\" epub:type=\"pagebreak\" role=\"doc-pagebreak\" aria-label=\"\(labelAttr)\"\(extra)></span>\n"
            case .figure(let assetId, let alt, let caption):
                // Skip silently when the asset is missing — chapter
                // splitting filters assets to only those referenced,
                // but a stale block can outlive its asset (e.g. tests
                // that build chapters by hand). Better an empty body
                // than a broken `<img>` tag with a dead src.
                guard let asset = assetIndex[assetId] else { continue }
                let href = "../images/\(asset.id).\(asset.fileExtension)"
                let hrefAttr = XMLEscape.attribute(href)
                let altAttr = XMLEscape.attribute(alt)
                var imgAttrs = "src=\"\(hrefAttr)\" alt=\"\(altAttr)\""
                if let size = asset.intrinsicSize {
                    imgAttrs += " width=\"\(Int(size.width))\""
                    imgAttrs += " height=\"\(Int(size.height))\""
                }
                body += "<figure>"
                body += "<img \(imgAttrs)/>"
                if !caption.isEmpty {
                    body += "<figcaption>"
                    body += renderRuns(caption, parentLanguage: defaultLanguage)
                    body += "</figcaption>"
                }
                // P-Diagram-Description Tier 2/3. When the Cloud
                // diagram extractor produced a description and/or
                // labels for this figure, emit them inside a
                // `<aside hidden epub:type="aside">` so the
                // chat / search indexer (which chunks paragraph-
                // shaped XHTML) picks them up automatically, but
                // EPUB readers don't render them. The `hidden`
                // attribute + book.css `aside.hu-figure-metadata
                // { display: none }` rule both contribute (defense
                // in depth — old readers respect one but not the
                // other).
                if let metadata = chapter.figureMetadata[assetId],
                   metadata.hasIndexableContent {
                    body += renderFigureMetadataAside(metadata)
                }
                body += "</figure>\n"
            case .table(let rows, let caption):
                body += renderTable(
                    rows: rows, caption: caption,
                    defaultLanguage: defaultLanguage
                )
            case .verse(let lines):
                // P-Verse-Layout. Emit <div class="verse"> with one
                // <p class="line indent-N"> per visual line. CSS in
                // book.css maps each indent bucket to a padding-left
                // that scales with the reader's font size.
                body += "<div class=\"verse\">\n"
                for line in lines {
                    let cls = line.indent > 0
                        ? "line indent-\(line.indent)"
                        : "line"
                    let runs = renderRuns(
                        line.runs, parentLanguage: defaultLanguage
                    )
                    body += "<p class=\"\(cls)\">\(runs)</p>\n"
                }
                body += "</div>\n"
            }
        }

        // Footnote popups. Asides are display:none in book.css; readers
        // (Apple Books, Thorium) hoist them into a popover when the
        // matching <a epub:type="noteref"> is tapped.
        if !chapter.footnotes.isEmpty {
            body += "<section epub:type=\"footnotes\" role=\"doc-endnotes\">\n"
            for fn in chapter.footnotes {
                let id = XMLEscape.attribute(fn.id)
                let marker = XMLEscape.text(fn.marker)
                let runs = renderRuns(fn.runs, parentLanguage: defaultLanguage)
                body += "<aside epub:type=\"footnote\" role=\"doc-footnote\" id=\"\(id)\">"
                body += "<p><span class=\"fn-marker\">\(marker)</span> \(runs)</p>"
                body += "</aside>\n"
            }
            body += "</section>\n"
        }

        // Cloud Phase 6d: when the chapter has been classified by
        // ClaudeChapterClassifier, emit the EPUB Structural
        // Semantics token on `<body>`. Readers use this to surface
        // semantic navigation (skip front matter, jump to
        // bibliography). Unlabeled chapters get a plain `<body>`.
        let bodyOpen: String
        if let epubType = chapter.epubType, !epubType.isEmpty {
            bodyOpen = "<body epub:type=\"\(XMLEscape.attribute(epubType))\">"
        } else {
            bodyOpen = "<body>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(langAttr)" lang="\(langAttr)">
        <head>
        <meta charset="utf-8"/>
        <title>\(XMLEscape.text(title))</title>
        <link rel="stylesheet" type="text/css" href="\(XMLEscape.attribute(cssPath))"/>
        </head>
        \(bodyOpen)
        \(body)</body>
        </html>
        """
    }

    /// P-Diagram-Description Tier 2/3. Emit Sonnet-generated
    /// figure description + label list inside an `<aside
    /// hidden>` so the chat / search indexer picks them up from
    /// the chapter XHTML (it chunks paragraph-shaped content).
    /// The `hidden` attribute keeps the aside out of the
    /// rendered chapter; `book.css` adds a `display: none` rule
    /// on the class for older readers that don't honor `hidden`.
    private func renderFigureMetadataAside(_ metadata: FigureMetadata) -> String {
        var out = "<aside class=\"hu-figure-metadata\" hidden>"
        if let description = metadata.description, !description.isEmpty {
            out += "<p>\(XMLEscape.text(description))</p>"
        }
        // Tier 3 labels populate this helper too — currently empty
        // for Tier 2, but the markup site is here so the next
        // commit only extends `metadata.labels` handling.
        if !metadata.labels.isEmpty {
            out += "<p>Labels: "
                + XMLEscape.text(metadata.labels.joined(separator: ", "))
                + "</p>"
        }
        out += "</aside>"
        return out
    }

    /// Render a `Block.table` — `<table role="table">` with optional
    /// `<caption>`, plus `<thead>` for the leading run of all-header
    /// rows and `<tbody>` for the rest. Empty tables (zero rows) emit
    /// nothing rather than a degenerate empty `<table>`.
    private func renderTable(
        rows: [[TableCell]], caption: [InlineRun],
        defaultLanguage: BCP47
    ) -> String {
        guard !rows.isEmpty else { return "" }
        var out = "<table role=\"table\">\n"
        if !caption.isEmpty {
            out += "<caption>"
            out += renderRuns(caption, parentLanguage: defaultLanguage)
            out += "</caption>\n"
        }
        // Leading rows whose every cell is a header live in <thead>;
        // remaining rows go in <tbody>. Heuristic-built tables emit
        // all-data (no thead); a future Surya table-model integration
        // sets header flags correctly.
        let headerRowCount = rows.prefix { row in
            !row.isEmpty && row.allSatisfy { $0.isHeader }
        }.count
        if headerRowCount > 0 {
            out += "<thead>\n"
            for row in rows.prefix(headerRowCount) {
                out += renderRow(row, defaultLanguage: defaultLanguage)
            }
            out += "</thead>\n"
        }
        let bodyRows = Array(rows.dropFirst(headerRowCount))
        if !bodyRows.isEmpty {
            out += "<tbody>\n"
            for row in bodyRows {
                out += renderRow(row, defaultLanguage: defaultLanguage)
            }
            out += "</tbody>\n"
        }
        out += "</table>\n"
        return out
    }

    private func renderRow(_ row: [TableCell], defaultLanguage: BCP47) -> String {
        var out = "<tr>"
        for cell in row {
            let tag = cell.isHeader ? "th" : "td"
            var attrs = ""
            if cell.rowspan > 1 { attrs += " rowspan=\"\(cell.rowspan)\"" }
            if cell.colspan > 1 { attrs += " colspan=\"\(cell.colspan)\"" }
            let inner = renderRuns(cell.runs, parentLanguage: defaultLanguage)
            out += "<\(tag)\(attrs)>\(inner)</\(tag)>"
        }
        out += "</tr>\n"
        return out
    }

    private func renderRuns(_ runs: [InlineRun], parentLanguage: BCP47) -> String {
        runs.map { run in
            // Opaque pass-through (currently used for MathML the
            // page-OCR parser captured verbatim). Skip escaping,
            // emphasis wrapping, and language attribute — the
            // markup is whatever the model emitted and the
            // structure is its own concern. Falls back to
            // text-based rendering when rawXHTML is nil (the
            // normal case).
            if let raw = run.rawXHTML, !raw.isEmpty {
                return raw
            }
            let escaped = XMLEscape.text(run.text)
            // Noteref runs render as a superscript link to the matching
            // <aside> at the end of the chapter. Language attrs still
            // apply (rare, but a Greek footnote marker should still be
            // language-tagged consistently). Emphasis on a noteref is
            // unusual but possible — wrap the noteref's inner content.
            if let id = run.noterefId {
                let href = XMLEscape.attribute("#" + id)
                var inner: String
                if let lang = run.language, lang != parentLanguage {
                    let l = XMLEscape.attribute(lang.rawValue)
                    inner = "<span xml:lang=\"\(l)\" lang=\"\(l)\">\(escaped)</span>"
                } else {
                    inner = escaped
                }
                inner = wrapEmphasis(inner, run: run)
                return "<a epub:type=\"noteref\" role=\"doc-noteref\" href=\"\(href)\">\(inner)</a>"
            }
            var rendered: String = escaped
            if let lang = run.language, lang != parentLanguage {
                let l = XMLEscape.attribute(lang.rawValue)
                rendered = "<span xml:lang=\"\(l)\" lang=\"\(l)\">\(rendered)</span>"
            }
            rendered = wrapEmphasis(rendered, run: run)
            return rendered
        }.joined()
    }

    /// Wrap `inner` in `<strong>` and/or `<em>` based on the run's
    /// emphasis flags. `<strong>` is the outer wrapper when both are
    /// set so the visual order is "bold containing italic" — readers
    /// render bold-italic identically either way, but the canonical
    /// nesting matches what most authoring tools emit.
    private func wrapEmphasis(_ inner: String, run: InlineRun) -> String {
        var s = inner
        if run.isItalic { s = "<em>\(s)</em>" }
        if run.isBold { s = "<strong>\(s)</strong>" }
        return s
    }
}
