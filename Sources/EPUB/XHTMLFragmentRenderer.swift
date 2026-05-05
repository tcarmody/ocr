import Foundation
import Document

/// Render `Block`s as an XHTML body fragment — just the content, no
/// `<html>` / `<head>` / `<body>` wrapping. Used by the editor's
/// "Replace Page in Source" action so the splice into a chapter file
/// drops in well-formed XHTML rather than re-wrapping plain OCR text
/// in `<p>` tags (which ignored layout, footnote refs, and language
/// spans).
///
/// Mirrors the per-block / per-run logic of `XHTMLWriter`; if
/// `XHTMLWriter` ever evolves new output (different attributes,
/// extra wrappers), update both — there's no shared helper today
/// because making `XHTMLWriter`'s internals public for one caller
/// felt like more leak than the small duplication is worth.
public enum XHTMLFragmentRenderer {
    public static func render(blocks: [Block], language: BCP47) -> String {
        var out = ""
        for block in blocks {
            switch block {
            case .heading(let level, let runs):
                let n = max(1, min(level, 6))
                out += "<h\(n)>\(renderRuns(runs, parentLanguage: language))</h\(n)>\n"
            case .paragraph(let runs):
                out += "<p>\(renderRuns(runs, parentLanguage: language))</p>\n"
            case .anchor(let id, let label):
                let idAttr = XMLEscape.attribute(id)
                let labelAttr = XMLEscape.attribute(label)
                out += "<span id=\"\(idAttr)\" epub:type=\"pagebreak\" "
                out += "role=\"doc-pagebreak\" aria-label=\"\(labelAttr)\"></span>\n"
            case .figure(let assetId, let alt, let caption):
                // Fragment renderer doesn't have asset access, so it
                // emits a placeholder `<img>` keyed off the assetId.
                // The fragment is only used by the editor's "Replace
                // Page in Source" splice — figures in re-OCR'd pages
                // pre-existed in the chapter file with their src
                // already wired up, so this href never round-trips
                // through asset lookup.
                let href = "../images/\(assetId).png"
                let hrefAttr = XMLEscape.attribute(href)
                let altAttr = XMLEscape.attribute(alt)
                out += "<figure><img src=\"\(hrefAttr)\" alt=\"\(altAttr)\"/>"
                if !caption.isEmpty {
                    out += "<figcaption>"
                    out += renderRuns(caption, parentLanguage: language)
                    out += "</figcaption>"
                }
                out += "</figure>\n"
            }
        }
        return out
    }

    /// Render a sequence of inline runs as the inline content of a
    /// container element. Matches `XHTMLWriter.renderRuns`.
    static func renderRuns(_ runs: [InlineRun], parentLanguage: BCP47) -> String {
        runs.map { run in
            let escaped = XMLEscape.text(run.text)
            if let id = run.noterefId {
                let href = XMLEscape.attribute("#" + id)
                let inner: String
                if let lang = run.language, lang != parentLanguage {
                    let l = XMLEscape.attribute(lang.rawValue)
                    inner = "<span xml:lang=\"\(l)\" lang=\"\(l)\">\(escaped)</span>"
                } else {
                    inner = escaped
                }
                return "<a epub:type=\"noteref\" role=\"doc-noteref\" href=\"\(href)\">\(inner)</a>"
            }
            if let lang = run.language, lang != parentLanguage {
                let l = XMLEscape.attribute(lang.rawValue)
                return "<span xml:lang=\"\(l)\" lang=\"\(l)\">\(escaped)</span>"
            }
            return escaped
        }.joined()
    }
}
