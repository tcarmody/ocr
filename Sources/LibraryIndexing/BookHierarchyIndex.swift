import Foundation
import EPUB

/// Per-book hierarchical structure index built from `nav.xhtml`.
///
/// Provides the chapter / section tree so the chat retriever can:
///  * detect structural queries ("chapter 3," "the section on
///    heterotopia") and expand them into "every paragraph in that
///    sub-tree";
///  * render paragraph-level hits with their containing
///    chapter / section title so the model has a structural anchor
///    even when the hits are scattered;
///  * surface a table-of-contents preamble in the system prompt so
///    the model knows what's available without consuming retrieval
///    budget.
///
/// The hierarchy is already implicit in the EPUB's nav doc — this
/// type just exposes it as a retrieval-time data structure. No
/// additional analysis or NER required.
public struct BookHierarchyIndex: Sendable, Codable, Equatable {

    /// One node in the chapter / section tree. `chapterIdx` indexes
    /// `book.spine`; `fragment` is the optional `#anchor` after the
    /// nav href and identifies a section start within the chapter
    /// XHTML. `children` are nested sections (typically depth ≤ 2).
    public struct Node: Sendable, Codable, Equatable {
        public let id: String
        public let kind: Kind
        public let title: String
        public let chapterIdx: Int
        public let fragment: String?
        public let children: [Node]

        public enum Kind: String, Codable, Sendable {
            case chapter
            case section
        }

        public init(
            id: String,
            kind: Kind,
            title: String,
            chapterIdx: Int,
            fragment: String?,
            children: [Node]
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.chapterIdx = chapterIdx
            self.fragment = fragment
            self.children = children
        }
    }

    /// Top-level nodes (depth 1). Each is typically a chapter; its
    /// children are sections.
    public let nodes: [Node]

    /// Pre-built lookup: spine index → top-level chapter node. Used
    /// by the retriever to attach a chapter title to a paragraph
    /// hit without re-walking the tree.
    public let chapterByIdx: [Int: Node]

    /// Pre-built flat list of every node, for structural-query
    /// matching against the user's question. Walking a flat list
    /// against a normalized query string is faster + simpler than
    /// recursive matching against the tree.
    public let flatNodes: [Node]

    public init(nodes: [Node]) {
        self.nodes = nodes
        var byIdx: [Int: Node] = [:]
        var flat: [Node] = []
        Self.collect(nodes, into: &flat, chapters: &byIdx)
        self.chapterByIdx = byIdx
        self.flatNodes = flat
    }

    private static func collect(
        _ nodes: [Node],
        into flat: inout [Node],
        chapters: inout [Int: Node]
    ) {
        for node in nodes {
            flat.append(node)
            if node.kind == .chapter, node.chapterIdx >= 0 {
                chapters[node.chapterIdx] = node
            }
            collect(node.children, into: &flat, chapters: &chapters)
        }
    }

    // MARK: - Building

    /// Build a hierarchy index from the book's nav resource. Returns
    /// an empty index when nav is missing or unparseable — the chat
    /// path falls back to chapter-only context in that case.
    public static func build(from book: EPUBBook) -> BookHierarchyIndex {
        guard let nav = book.navResource, let xhtml = nav.text else {
            return BookHierarchyIndex(nodes: [])
        }
        return build(navXHTML: xhtml, book: book)
    }

    /// Visible for tests — build from a raw nav XHTML string.
    public static func build(navXHTML xhtml: String, book: EPUBBook) -> BookHierarchyIndex {
        let parsedTree = NavParser.parse(xhtml)
        let resolved = parsedTree.enumerated().map { (idx, raw) in
            convert(raw: raw, book: book, idPrefix: "ch-\(idx)", depth: 0)
        }
        return BookHierarchyIndex(nodes: resolved)
    }

    /// Convert a raw parsed `(title, href, children)` into a Node
    /// with chapterIdx resolved against the spine.
    private static func convert(
        raw: NavParser.RawNode,
        book: EPUBBook,
        idPrefix: String,
        depth: Int
    ) -> Node {
        let (resourceHref, fragment) = splitHref(raw.href)
        let chapterIdx = resolveChapterIdx(
            href: resourceHref, book: book
        )
        let kind: Node.Kind = depth == 0 ? .chapter : .section
        let children = raw.children.enumerated().map { (childIdx, childRaw) in
            convert(
                raw: childRaw,
                book: book,
                idPrefix: "\(idPrefix)-\(childIdx)",
                depth: depth + 1
            )
        }
        return Node(
            id: idPrefix,
            kind: kind,
            title: raw.title,
            chapterIdx: chapterIdx,
            fragment: fragment,
            children: children
        )
    }

    /// Split `chapter-005.xhtml#sec-12` into
    /// (`chapter-005.xhtml`, `sec-12`).
    private static func splitHref(_ href: String) -> (String, String?) {
        if let hash = href.firstIndex(of: "#") {
            let base = String(href[..<hash])
            let frag = String(href[href.index(after: hash)...])
            return (base, frag.isEmpty ? nil : frag)
        }
        return (href, nil)
    }

    /// Match a nav href to a spine index by comparing against each
    /// resource's `hrefRelativeToOPF`. Returns -1 when no spine
    /// resource matches (e.g. the nav points at a non-linear
    /// resource).
    private static func resolveChapterIdx(
        href: String, book: EPUBBook
    ) -> Int {
        // Empty href: probably a nav placeholder. Skip.
        guard !href.isEmpty else { return -1 }
        for (idx, resourceID) in book.spine.enumerated() {
            guard let resource = book.resourcesByID[resourceID] else { continue }
            // Two paths can match: equal href, or basename-equal
            // (when nav uses "chapter.xhtml" but the manifest stores
            // it as "OEBPS/chapter.xhtml" or vice versa).
            if resource.hrefRelativeToOPF == href {
                return idx
            }
            let manifestBase = (resource.hrefRelativeToOPF as NSString).lastPathComponent
            let navBase = (href as NSString).lastPathComponent
            if manifestBase == navBase {
                return idx
            }
        }
        return -1
    }

    // MARK: - Structural-query matching

    /// Find hierarchy nodes that the query mentions by name.
    /// Conservative — returns matches only when the query contains
    /// the node's title (or "chapter N" / "section N" structural
    /// patterns). Order: most-specific (deepest) first, so a
    /// section title beats its containing chapter when both match.
    public func nodesMatching(query: String) -> [Node] {
        let normalizedQuery = query.lowercased()
        var matches: [(Node, depth: Int)] = []
        // Walk the flat list once. For each node, test (a) literal
        // title containment ("the chapter on heterotopia") and
        // (b) the structural pattern "chapter N" / "section N".
        for node in flatNodes {
            if matchesTitle(node, normalizedQuery: normalizedQuery) {
                matches.append((node, depthOf(node)))
                continue
            }
            if matchesStructuralPattern(node, query: normalizedQuery) {
                matches.append((node, depthOf(node)))
            }
        }
        // Deepest matches first — a section beats its chapter.
        return matches
            .sorted { $0.depth > $1.depth }
            .map { $0.0 }
    }

    private func matchesTitle(_ node: Node, normalizedQuery: String) -> Bool {
        let title = node.title.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 4 else { return false }
        // Token-overlap match. Titles like "On Heterotopias" need to
        // match queries like "what about heterotopias" where the
        // user references the title by a content keyword rather than
        // verbatim. Look for any title token of length ≥ 5 that
        // appears in the query — long-enough tokens are usually
        // distinctive (e.g. "heterotopias", "discipline", "method")
        // while short ones ("the", "and", "of") would over-match.
        for token in tokenize(title) where token.count >= 5 {
            if normalizedQuery.contains(token) {
                return true
            }
        }
        return false
    }

    /// Lowercase, alphabetic-only token splitter. Mirrors the
    /// posture of `BookKeywordIndex.tokenize` but is intentionally
    /// stopword-free — we already gate on token length.
    private func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var buffer = ""
        for char in s {
            if char.isLetter {
                buffer.append(char)
            } else {
                if !buffer.isEmpty { out.append(buffer) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { out.append(buffer) }
        return out
    }

    /// "chapter 3", "section 2.1", "ch 5" structural patterns.
    /// 1-based numbering as the user thinks of it; our chapterIdx
    /// is 0-based.
    private func matchesStructuralPattern(
        _ node: Node, query: String
    ) -> Bool {
        let kindWord: String = (node.kind == .chapter) ? "chapter" : "section"
        let abbreviation: String? = (node.kind == .chapter) ? "ch" : nil
        // chapterIdx is 0-based; users say "chapter 1" for index 0.
        let userNumber = node.chapterIdx + 1
        guard userNumber >= 1 else { return false }
        let patterns: [String] = {
            var out = [
                "\(kindWord) \(userNumber)",
                "\(kindWord) #\(userNumber)",
            ]
            if let abbreviation {
                out.append("\(abbreviation) \(userNumber)")
                out.append("\(abbreviation). \(userNumber)")
            }
            return out
        }()
        for pattern in patterns where query.contains(pattern) {
            return true
        }
        return false
    }

    /// Depth of a node within the tree. Used to break ties when
    /// multiple nodes match a query (deeper wins).
    private func depthOf(_ node: Node) -> Int {
        var depth = 0
        var queue: [Node] = nodes
        while let head = queue.first {
            queue.removeFirst()
            if head.id == node.id { return depth }
            queue.append(contentsOf: head.children)
            // Approximate depth via id-prefix segment count — ids
            // grow by `-N` per nesting level, so the count of `-`s
            // tracks depth without re-walking the tree.
        }
        // Fallback: count `-` segments in the id.
        return node.id.filter { $0 == "-" }.count - 1
    }
}

// MARK: - Nav parser

/// Minimal nav.xhtml parser. Walks the first `<nav epub:type="toc">`
/// element's `<ol>` tree, returning a flat-into-nested raw tree of
/// `(title, href, children)` triples. Doesn't attempt to be a full
/// XHTML parser — it's tuned for the shape Humanist's `NavWriter`
/// produces and the conventions third-party EPUB toolchains follow.
///
/// Tradeoff: regex-driven nested structure is fragile, but the nav
/// XHTML spec is narrow enough that a Foundation `XMLParser` setup
/// is more code than it's worth. If a real-world nav file fails to
/// parse, the chat path falls back to chapter-only retrieval — no
/// crash, just weaker structural awareness.
public enum NavParser {

    public struct RawNode {
        public let title: String
        public let href: String
        public let children: [RawNode]
    }

    /// Parse a nav.xhtml string into the top-level chapter list.
    /// Returns an empty array if no `<nav epub:type="toc">` is
    /// found or its first `<ol>` is empty.
    public static func parse(_ xhtml: String) -> [RawNode] {
        guard let navBody = extractNavBody(xhtml) else { return [] }
        guard let firstOL = extractInner(of: "ol", in: navBody) else { return [] }
        return parseList(firstOL)
    }

    /// Extract the inner content of the first
    /// `<nav epub:type="toc">...</nav>`. Tolerates attribute-order
    /// variations and case differences.
    private static func extractNavBody(_ xhtml: String) -> String? {
        // Look for `<nav ... epub:type="toc"` (attributes can come
        // before or after the type marker). The id="toc" form
        // produced by NavWriter is also a valid match.
        let pattern =
            "<nav\\b[^>]*?(?:epub:type=\"toc\"|id=\"toc\")[^>]*>([\\s\\S]*?)</nav>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return nil }
        let nsText = xhtml as NSString
        guard let match = regex.firstMatch(
            in: xhtml,
            range: NSRange(location: 0, length: nsText.length)
        ), match.numberOfRanges >= 2 else { return nil }
        return nsText.substring(with: match.range(at: 1))
    }

    /// Extract the inner content of the first `<tag>...</tag>`
    /// occurrence at the top level of `body`. Needs balanced-tag
    /// awareness because `<ol>` can nest inside `<li>` inside
    /// `<ol>`. Implemented as a manual scan rather than a regex —
    /// regular expressions can't reliably match balanced nesting.
    private static func extractInner(of tag: String, in body: String) -> String? {
        let lowered = body.lowercased()
        let openTag = "<\(tag)"
        let closeTag = "</\(tag)>"
        guard let openStart = lowered.range(of: openTag) else { return nil }
        // Find the `>` that ends the opening tag.
        guard let openEnd = body.range(
            of: ">",
            range: openStart.upperBound..<body.endIndex
        ) else { return nil }
        // Walk forward, counting nested opens vs closes.
        var depth = 1
        var cursor = openEnd.upperBound
        while cursor < body.endIndex, depth > 0 {
            let remaining = lowered[cursor..<body.endIndex]
            let nextOpen = remaining.range(of: openTag)
            let nextClose = remaining.range(of: closeTag)
            if nextClose == nil { return nil }
            if let openRange = nextOpen,
               openRange.lowerBound < (nextClose?.lowerBound ?? remaining.endIndex) {
                depth += 1
                cursor = openRange.upperBound
            } else if let closeRange = nextClose {
                depth -= 1
                if depth == 0 {
                    return String(body[openEnd.upperBound..<closeRange.lowerBound])
                }
                cursor = closeRange.upperBound
            } else {
                break
            }
        }
        return nil
    }

    /// Parse the inner content of an `<ol>` into a list of raw nodes.
    /// Iterates `<li>` items at this depth; for each, reads the
    /// first `<a href="...">title</a>` and recurses into the first
    /// nested `<ol>`.
    private static func parseList(_ olInner: String) -> [RawNode] {
        var out: [RawNode] = []
        var remaining = olInner
        while let liInner = extractFirstAndAdvance(
            tag: "li", in: &remaining
        ) {
            guard let (title, href) = extractAnchor(liInner) else { continue }
            let children: [RawNode]
            if let nestedOL = extractInner(of: "ol", in: liInner) {
                children = parseList(nestedOL)
            } else {
                children = []
            }
            out.append(RawNode(title: title, href: href, children: children))
        }
        return out
    }

    /// Pull the first `<tag>...</tag>`-balanced block out of
    /// `body` (advancing `body` to the position after the close
    /// tag). Returns the inner content; returns nil when no
    /// further match exists.
    private static func extractFirstAndAdvance(
        tag: String, in body: inout String
    ) -> String? {
        let lowered = body.lowercased()
        let openTag = "<\(tag)"
        let closeTag = "</\(tag)>"
        guard let openStart = lowered.range(of: openTag) else { return nil }
        guard let openEnd = body.range(
            of: ">",
            range: openStart.upperBound..<body.endIndex
        ) else { return nil }
        var depth = 1
        var cursor = openEnd.upperBound
        while cursor < body.endIndex, depth > 0 {
            let remaining = lowered[cursor..<body.endIndex]
            let nextOpen = remaining.range(of: openTag)
            let nextClose = remaining.range(of: closeTag)
            if nextClose == nil { return nil }
            if let openRange = nextOpen,
               openRange.lowerBound < (nextClose?.lowerBound ?? remaining.endIndex) {
                depth += 1
                cursor = openRange.upperBound
            } else if let closeRange = nextClose {
                depth -= 1
                if depth == 0 {
                    let inner = String(
                        body[openEnd.upperBound..<closeRange.lowerBound]
                    )
                    body = String(body[closeRange.upperBound...])
                    return inner
                }
                cursor = closeRange.upperBound
            } else {
                break
            }
        }
        return nil
    }

    /// Pull `(title, href)` out of the first `<a href="...">title</a>`
    /// in `liInner`. Decodes a small set of named entities so the
    /// title displays cleanly. Numeric refs pass through.
    private static func extractAnchor(_ liInner: String) -> (String, String)? {
        let pattern =
            "<a\\b[^>]*?\\bhref=\"([^\"]*)\"[^>]*>([\\s\\S]*?)</a>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return nil }
        let nsText = liInner as NSString
        guard let match = regex.firstMatch(
            in: liInner,
            range: NSRange(location: 0, length: nsText.length)
        ), match.numberOfRanges >= 3 else { return nil }
        let href = nsText.substring(with: match.range(at: 1))
        let rawTitle = nsText.substring(with: match.range(at: 2))
        let strippedTitle = stripTags(rawTitle)
        return (strippedTitle, href)
    }

    /// Strip every nested tag (rare; `<a>` titles are usually
    /// plain text) and decode named entities. Same posture as
    /// `BookEmbeddingIndex.ParagraphExtractor.stripInnerTags`.
    private static func stripTags(_ s: String) -> String {
        var out = s.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&nbsp;": " ",
        ]
        for (k, v) in entities {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
            .replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
