import Foundation
import EPUB

/// R-Reader. Parsed table of contents for the reader's sidebar.
///
/// Source of truth, in preference order:
///
/// 1. **`nav.xhtml`** — the EPUB 3 navigation document. Walk
///    `<nav epub:type="toc">` and pull `<a href="…">title</a>`
///    entries. Universal across EPUBs we produce and most
///    third-party ones.
/// 2. **Spine fallback** — when nav.xhtml is missing or parses
///    empty, derive a flat TOC from the spine: one entry per
///    spine item, title taken from the chapter file's
///    `<title>` element when present, else its first `<hN>`
///    heading, else its filename.
///
/// The reader sidebar only needs `(title, spineIndex)` pairs —
/// the model collapses any hierarchy nav.xhtml might encode
/// because v1 of the reader presents a flat list. Sub-section
/// navigation lands in a v2.
struct ReaderTOC: Sendable, Equatable {
    var entries: [Entry]

    struct Entry: Sendable, Equatable, Identifiable {
        let id: Int   // = spineIndex
        let title: String
        var spineIndex: Int { id }
    }

    /// Build a TOC for `book`. Always returns a non-empty list
    /// when the spine has at least one item — the spine fallback
    /// path ensures the sidebar is never blank for a readable
    /// book.
    static func build(from book: EPUBBook) -> ReaderTOC {
        if let parsed = parseNav(book: book), !parsed.entries.isEmpty {
            return parsed
        }
        return spineFallback(book: book)
    }

    // MARK: - nav.xhtml path

    /// Parse the book's nav.xhtml (when present) and produce a
    /// TOC mapped to spine indices. Returns nil when:
    ///   * no nav resource is declared in the manifest
    ///   * the nav has no text content
    ///   * XML parse fails outright
    /// Returns a TOC with empty entries when the parse succeeds
    /// but no `<a>` elements were found inside the toc nav —
    /// caller falls back to the spine path.
    private static func parseNav(book: EPUBBook) -> ReaderTOC? {
        guard let nav = book.navResource else { return nil }
        guard let raw = nav.text, !raw.isEmpty else { return nil }
        // Resolve hrefs in nav.xhtml relative to the nav file's
        // directory, then canonicalize to compare against spine
        // resource hrefs (which are relative to the OPF).
        let navDir = (nav.hrefRelativeToOPF as NSString)
            .deletingLastPathComponent
        // Build a spineIndex lookup keyed by OPF-relative href so
        // the parsed entries can resolve to spine positions
        // without per-entry string-walking.
        var spineLookup: [String: Int] = [:]
        for (idx, resourceID) in book.spine.enumerated() {
            guard let resource = book.resourcesByID[resourceID] else { continue }
            let normalized = normalize(href: resource.hrefRelativeToOPF)
            spineLookup[normalized] = idx
        }
        guard let data = wrap(raw).data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        let delegate = NavDelegate(
            navDirectoryRelativeToOPF: navDir,
            spineLookup: spineLookup
        )
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return ReaderTOC(entries: delegate.entries)
    }

    /// Resolve a nav-relative href against the nav file's
    /// directory + the OPF root. Strips fragments (#xxx) and
    /// percent-decodes the path so it lines up with the
    /// manifest's `hrefRelativeToOPF` values (which are
    /// percent-encoded URI references).
    static func resolveHref(
        _ href: String, againstNavDirectory navDir: String
    ) -> String? {
        // Drop fragment identifier (`#section-2` etc.).
        var path = href
        if let hashIdx = path.firstIndex(of: "#") {
            path = String(path[..<hashIdx])
        }
        guard !path.isEmpty else { return nil }
        // Combine with nav directory, resolving `..` segments.
        let combined: String
        if navDir.isEmpty {
            combined = path
        } else if path.hasPrefix("/") {
            combined = String(path.dropFirst())
        } else {
            combined = "\(navDir)/\(path)"
        }
        return normalize(href: combined)
    }

    /// Canonicalize an OPF-relative href: percent-decode, resolve
    /// `..` / `.` segments, drop empty path parts. Two hrefs that
    /// point at the same file but spell their path differently
    /// (`text/chapter-1.xhtml` vs `text/../text/chapter-1.xhtml`)
    /// normalize to the same string so lookups don't miss.
    static func normalize(href: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        var stack: [String] = []
        for segment in decoded.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(String(segment))
            }
        }
        return stack.joined(separator: "/")
    }

    /// Prepare nav.xhtml content for `XMLParser`. nav.xhtml ships
    /// with an `<?xml ?>` declaration + `<!DOCTYPE>` that
    /// `XMLParser` can't tolerate when re-wrapped inside another
    /// root element, so strip them out and pass the `<html>…</html>`
    /// body through directly. Also substitute the most common
    /// XHTML named entities for their Unicode characters since
    /// `XMLParser` rejects anything outside the five built-in
    /// XML entities.
    private static func wrap(_ s: String) -> String {
        var trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip `<?xml … ?>` (any whitespace, any version).
        if trimmed.hasPrefix("<?xml") {
            if let end = trimmed.range(of: "?>") {
                trimmed = String(trimmed[end.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Strip `<!DOCTYPE …>` (one line).
        if trimmed.hasPrefix("<!DOCTYPE") || trimmed.hasPrefix("<!doctype") {
            if let end = trimmed.range(of: ">") {
                trimmed = String(trimmed[end.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Named-entity substitutions XMLParser doesn't know.
        // `&apos;` is in the XML built-in set so XMLParser handles
        // it; the others aren't.
        return trimmed
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&hellip;", with: "…")
    }

    // MARK: - Spine fallback

    /// Build a flat TOC from the spine — one entry per spine
    /// item. Title source order: chapter's `<title>` element →
    /// first `<h1>`–`<h6>` heading → filename. Always returns at
    /// least one entry per spine item, so the sidebar is never
    /// blank.
    private static func spineFallback(book: EPUBBook) -> ReaderTOC {
        var entries: [Entry] = []
        for (idx, resourceID) in book.spine.enumerated() {
            guard let resource = book.resourcesByID[resourceID] else {
                entries.append(Entry(id: idx, title: "Chapter \(idx + 1)"))
                continue
            }
            let title = chapterTitle(from: resource)
                ?? filenameTitle(from: resource.hrefRelativeToOPF)
                ?? "Chapter \(idx + 1)"
            entries.append(Entry(id: idx, title: title))
        }
        return ReaderTOC(entries: entries)
    }

    /// Extract a display title from a chapter resource. Returns
    /// the first non-empty value in: `<title>` → first heading.
    /// Returns nil when neither is present or both are empty.
    private static func chapterTitle(from resource: Resource) -> String? {
        guard let text = resource.text else { return nil }
        if let titleTag = firstTagContent(in: text, tag: "title"),
           !titleTag.isEmpty {
            return titleTag
        }
        for level in 1...6 {
            if let h = firstTagContent(in: text, tag: "h\(level)"),
               !h.isEmpty {
                return h
            }
        }
        return nil
    }

    /// Strip the path + extension off an OPF-relative href to
    /// derive a fallback title (`text/chapter-001.xhtml` →
    /// `chapter-001`). Returns nil for empty / extension-less
    /// hrefs.
    private static func filenameTitle(from href: String) -> String? {
        let base = (href as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        return stem.isEmpty ? nil : stem
    }

    /// Pull the textual content of the first matching tag.
    /// Naive parser — sufficient for `<title>` and `<hN>` where
    /// the content is typically plain text. Strips inner tags
    /// (e.g. `<title>Foo <em>bar</em></title>` → `"Foo bar"`).
    private static func firstTagContent(
        in xml: String, tag: String
    ) -> String? {
        let lower = xml.lowercased()
        guard let openStart = lower.range(of: "<\(tag)") else { return nil }
        // Find the end of the opening tag (handles attributes).
        guard let openEnd = xml.range(
            of: ">", range: openStart.upperBound..<xml.endIndex
        ) else { return nil }
        // Find the closing tag.
        guard let closeStart = lower.range(
            of: "</\(tag)>", range: openEnd.upperBound..<lower.endIndex
        ) else { return nil }
        let inner = String(xml[openEnd.upperBound..<closeStart.lowerBound])
        return decodeEntities(stripTags(inner))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode the XML entities that come up in chapter titles +
    /// nav text. Five built-in entities + a few common named ones
    /// (em-dash, en-dash, ellipsis, nbsp) so the spine-fallback
    /// path matches the nav-parsed path's output for the same
    /// title text.
    private static func decodeEntities(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&hellip;", with: "…")
    }

    /// Remove every `<…>` tag from a fragment. Tag-strip only —
    /// doesn't decode HTML entities. The caller's whitespace trim
    /// handles the common ` ` runs left by stripped tags.
    private static func stripTags(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inTag = false
        for ch in s {
            switch ch {
            case "<": inTag = true
            case ">":
                if inTag { inTag = false; continue }
                out.append(ch)
            default:
                if !inTag { out.append(ch) }
            }
        }
        return out
    }
}

// MARK: - XMLParser delegate for nav.xhtml

/// Walks a wrapped nav.xhtml fragment and collects `<a href="…">`
/// entries whose hrefs resolve to spine items. Skips:
///   * `<nav>` elements that aren't `epub:type="toc"` (the EPUB 3
///     nav doc can declare `landmarks`, `page-list`, etc. that
///     we don't want in the sidebar).
///   * `<a>` elements whose href doesn't map to a spine entry
///     (decorative landing-page links, external URLs).
private final class NavDelegate: NSObject, XMLParserDelegate {
    private let navDirectoryRelativeToOPF: String
    private let spineLookup: [String: Int]

    var entries: [ReaderTOC.Entry] = []

    /// Are we currently inside the `<nav epub:type="toc">` element?
    /// Other navs (landmarks, page-list) get skipped.
    private var insideTOCNav: Bool = false
    /// Depth of `<nav>` elements since the toc-nav opened. Used so
    /// nested navs (rare but possible) don't prematurely flip
    /// `insideTOCNav` off.
    private var navDepth: Int = 0

    /// While inside an `<a>` whose href resolved to a spine
    /// index: the spine index + an accumulator for the link text.
    /// Nil when not inside a captureable `<a>`.
    private var currentLinkSpineIndex: Int?
    private var currentLinkBuffer: String = ""
    private var seenSpineIndices = Set<Int>()

    init(
        navDirectoryRelativeToOPF: String,
        spineLookup: [String: Int]
    ) {
        self.navDirectoryRelativeToOPF = navDirectoryRelativeToOPF
        self.spineLookup = spineLookup
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let tag = elementName.lowercased()
        switch tag {
        case "nav":
            // Accept `epub:type="toc"` — also accept a missing
            // type when no toc-typed nav has been seen yet
            // (older EPUBs may omit the type attribute on the
            // top-level nav). Skip explicit `landmarks` /
            // `page-list` typed navs.
            let typeRaw = attributeDict["epub:type"]
                ?? attributeDict["type"]
                ?? ""
            let isLandmarks = typeRaw.contains("landmarks")
            let isPageList = typeRaw.contains("page-list")
            if insideTOCNav {
                navDepth += 1
            } else if !isLandmarks && !isPageList {
                insideTOCNav = true
                navDepth = 1
            }
        case "a":
            guard insideTOCNav, currentLinkSpineIndex == nil else { return }
            let href = attributeDict["href"] ?? ""
            guard !href.isEmpty else { return }
            guard let resolved = ReaderTOC.resolveHref(
                href, againstNavDirectory: navDirectoryRelativeToOPF
            ) else { return }
            guard let spineIdx = spineLookup[resolved] else { return }
            // First link to a given spine entry wins. nav.xhtml
            // sometimes lists the same chapter under multiple
            // sub-sections — collapsing to one entry per spine
            // matches v1's flat-sidebar model.
            guard !seenSpineIndices.contains(spineIdx) else { return }
            currentLinkSpineIndex = spineIdx
            currentLinkBuffer = ""
        default:
            return
        }
    }

    func parser(
        _ parser: XMLParser, foundCharacters string: String
    ) {
        guard currentLinkSpineIndex != nil else { return }
        currentLinkBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let tag = elementName.lowercased()
        switch tag {
        case "nav":
            guard insideTOCNav else { return }
            navDepth -= 1
            if navDepth <= 0 {
                insideTOCNav = false
                navDepth = 0
            }
        case "a":
            guard let idx = currentLinkSpineIndex else { return }
            let title = currentLinkBuffer
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(
                    of: "\\s+",
                    with: " ",
                    options: .regularExpression
                )
            if !title.isEmpty {
                entries.append(ReaderTOC.Entry(id: idx, title: title))
                seenSpineIndices.insert(idx)
            }
            currentLinkSpineIndex = nil
            currentLinkBuffer = ""
        default:
            return
        }
    }
}
