import Foundation

/// Re-indent an XHTML buffer the way an IDE's "format document"
/// gesture does — pretty-print the element tree by depth — but keep
/// phrasing-level (inline) elements glued to their surrounding text.
///
/// Foundation's `XMLDocument.xmlString(.nodePrettyPrint)` treats every
/// element as block-level: it breaks `<em>`, `<strong>`, `<sup>`, … onto
/// their own indented lines, which shoves whitespace between a closing
/// inline tag and the punctuation that should hug it
/// (`</em>\n        , then` instead of `</em>, then`). That round-trips
/// the prose into something the WYSIWYG renders with stray spaces before
/// commas and periods.
///
/// We fix it by doing the indentation ourselves: an element whose only
/// element children are inline (or which has no element children) is
/// emitted compactly on a single line — so its inner runs of text and
/// phrasing tags survive byte-for-byte — while elements that contain
/// block children get the open tag, indented children, and close tag on
/// their own lines. The XML declaration and DOCTYPE are taken verbatim
/// from Foundation's pretty output so the document header is unchanged.
enum XHTMLSourceTidier {

    /// HTML phrasing-content elements that should never force a line
    /// break in the source. Anything not in this set is treated as a
    /// block container whose children get indented. `<pre>` is absent
    /// on purpose: it has no block children, so it lands on the inline
    /// (compact) path and its whitespace-significant body is preserved
    /// verbatim.
    static let inlineElementNames: Set<String> = [
        "a", "abbr", "b", "bdi", "bdo", "br", "cite", "code", "data",
        "del", "dfn", "em", "i", "img", "ins", "kbd", "mark", "q", "rp",
        "rt", "ruby", "s", "samp", "small", "span", "strike", "strong",
        "sub", "sup", "time", "tt", "u", "var", "wbr", "big", "font",
    ]

    private static let indentUnit = "    "

    /// Result of a tidy pass. `text` is the reformatted source on
    /// success; `error` carries a parse failure message instead (the
    /// caller surfaces it without mangling the buffer).
    struct Outcome {
        var text: String?
        var error: String?
    }

    /// Round-trip `source` through `XMLDocument`, re-indenting the tree
    /// while keeping inline elements in-line. Returns `text == nil` with
    /// an `error` on parse failure; returns `text == source` (caller
    /// treats as no-op) when nothing changes.
    static func tidy(_ source: String) -> Outcome {
        guard !source.isEmpty else { return Outcome(text: source) }
        guard let data = source.data(using: .utf8) else {
            return Outcome(error: "Source is not valid UTF-8.")
        }
        let doc: XMLDocument
        do {
            doc = try XMLDocument(
                data: data,
                options: [.nodePreserveCDATA, .nodeLoadExternalEntitiesNever]
            )
        } catch {
            return Outcome(error: error.localizedDescription)
        }
        guard let root = doc.rootElement(), let rootName = root.name else {
            // No root element to format — leave the buffer untouched.
            return Outcome(text: source)
        }

        // Reuse Foundation's pretty output purely for the document
        // header (declaration + DOCTYPE + the blank line it inserts),
        // then graft our inline-aware root serialization onto it. The
        // root element opens at column 0, so it is the first `\n<name`
        // in the pretty output — comment/DOCTYPE text never matches.
        let pretty = doc.xmlString(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
        let prefix: Substring
        if let r = pretty.range(of: "\n<\(rootName)") {
            prefix = pretty[..<pretty.index(after: r.lowerBound)]
        } else {
            prefix = ""
        }

        let tidied = String(prefix) + serialize(root, depth: 0)
        return Outcome(text: tidied)
    }

    /// Serialize one node, indenting block structure but emitting any
    /// inline-only subtree compactly on a single line.
    private static func serialize(_ node: XMLNode, depth: Int) -> String {
        let indent = String(repeating: indentUnit, count: depth)
        guard node.kind == .element, let el = node as? XMLElement else {
            return indent + (node.xmlString)
        }

        let childElements = (el.children ?? []).compactMap { $0 as? XMLElement }
        let hasBlockChild = childElements.contains {
            !inlineElementNames.contains(($0.name ?? "").lowercased())
        }

        // Inline container, text-only, or empty: one compact line. Inner
        // text and phrasing tags are preserved exactly by the non-pretty
        // serializer.
        if !hasBlockChild {
            return indent + el.xmlString(options: [.nodeCompactEmptyElement])
        }

        // Block container: open tag, indented children, close tag.
        let (open, close) = openCloseTags(el)
        var lines = [indent + open]
        for child in el.children ?? [] {
            // Drop the whitespace-only text nodes between block children;
            // Foundation's pretty printer does the same.
            if child.kind == .text,
               (child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            lines.append(serialize(child, depth: depth + 1))
        }
        lines.append(indent + close)
        return lines.joined(separator: "\n")
    }

    /// Extract an element's start and end tags (attributes, namespaces,
    /// and escaping intact) by serializing a childless copy and slicing
    /// off the trailing `</name>`. Only called for block containers,
    /// which always have children and so never self-close.
    private static func openCloseTags(_ el: XMLElement) -> (open: String, close: String) {
        let copy = el.copy() as! XMLElement
        for child in copy.children ?? [] { child.detach() }
        let empty = copy.xmlString()
        let close = "</\(el.name ?? "")>"
        let open = empty.hasSuffix(close) ? String(empty.dropLast(close.count)) : empty
        return (open, close)
    }
}
