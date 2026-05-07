import Foundation

/// Rewrites `href` and `src` attributes in a text resource so links
/// stay valid after a sibling resource is renamed (or moved).
///
/// Used by `EPUBBook.renameResource` to update every text resource
/// in the book whenever any one of them changes its href. Mirrors
/// the role of Sigil's `AnchorUpdates::UpdateExternalAnchors` — an
/// EPUB with a single dangling `<a href="ch06.xhtml">` after a
/// rename is failing the user; the rename feature is incomplete
/// without this pass.
///
/// Pure functions, no Foundation URL machinery — URL parsing of
/// EPUB-relative hrefs is finicky (a leading `..` is fine here, not
/// fine to URLs). The matcher is regex-based on `href="..."` /
/// `src="..."` attributes; it skips fragment-only links (`#section`)
/// and external schemes (`http://`, `mailto:`, etc.).
public enum LinkRewriter {

    /// Walk `text` and rewrite each `href` / `src` attribute whose
    /// resolved target (relative to the OPF root) equals
    /// `oldTargetHref`. Resolved targets that don't match are left
    /// untouched, as are external or fragment-only links.
    ///
    /// `baseHref` is the OPF-relative path of the resource being
    /// scanned. Used to resolve same-directory references like
    /// `<a href="ch06.xhtml">` in `text/ch05.xhtml`.
    ///
    /// Returns the rewritten text plus the count of changes (useful
    /// for tests and "no links to rewrite" short-circuits).
    public static func rewrite(
        text: String,
        baseHref: String,
        oldTargetHref: String,
        newTargetHref: String
    ) -> (text: String, changes: Int) {
        let normalizedOld = normalizePath(oldTargetHref)
        guard let regex = Self.attrRegex else { return (text, 0) }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return (text, 0) }

        var rewritten = ""
        var cursor = text.startIndex
        var changes = 0

        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                  let attrRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text)
            else { continue }

            // Append untouched text before this match.
            rewritten += String(text[cursor..<matchRange.lowerBound])

            let attr = String(text[attrRange])           // "href" or "src"
            let quoted = String(text[valueRange])        // "\"...\"" or "'...'"
            let quote = quoted.first ?? "\""
            let inner = String(quoted.dropFirst().dropLast())

            if let rewrittenInner = Self.rewriteHref(
                inner,
                baseHref: baseHref,
                oldNormalized: normalizedOld,
                newTargetHref: newTargetHref
            ) {
                rewritten += "\(attr)=\(quote)\(rewrittenInner)\(quote)"
                changes += 1
            } else {
                rewritten += String(text[matchRange])
            }
            cursor = matchRange.upperBound
        }
        rewritten += String(text[cursor...])
        return (rewritten, changes)
    }

    /// If `href` resolves (relative to `baseHref`) to the same
    /// resource as `oldNormalized`, return the rewritten href that
    /// targets `newTargetHref` instead. Otherwise nil.
    static func rewriteHref(
        _ href: String,
        baseHref: String,
        oldNormalized: String,
        newTargetHref: String
    ) -> String? {
        let (target, fragment) = splitFragment(href)
        if target.isEmpty { return nil }            // same-doc fragment
        if isExternal(target) { return nil }        // http://, mailto:, etc.

        let resolved = resolveRelative(target: target, base: baseHref)
        guard normalizePath(resolved) == oldNormalized else { return nil }

        let newRelative = relativize(target: newTargetHref, base: baseHref)
        return fragment.isEmpty
            ? newRelative
            : "\(newRelative)#\(fragment)"
    }

    // MARK: - Path helpers

    /// Collapse `..` and `.` components in a path. Empty components
    /// (consecutive slashes) are dropped. Returns the cleaned path
    /// without leading slash.
    static func normalizePath(_ path: String) -> String {
        var components: [String] = []
        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(piece))
            }
        }
        return components.joined(separator: "/")
    }

    /// Resolve `target` relative to `base`. `base` is a file path
    /// (the resource being scanned); we use its parent directory as
    /// the resolution origin. Same-directory references stay flat;
    /// `..` walks up.
    static func resolveRelative(target: String, base: String) -> String {
        let baseDir: String
        if let lastSlash = base.lastIndex(of: "/") {
            baseDir = String(base[..<lastSlash])
        } else {
            baseDir = ""
        }
        let combined = baseDir.isEmpty ? target : "\(baseDir)/\(target)"
        return normalizePath(combined)
    }

    /// Express `target` (an OPF-root-relative path) as a path
    /// relative to the directory of `base`. Mirrors the inverse of
    /// `resolveRelative`. Walks up with `..` segments when the
    /// target is in a sibling or ancestor directory.
    static func relativize(target: String, base: String) -> String {
        let baseDir: String
        if let lastSlash = base.lastIndex(of: "/") {
            baseDir = String(base[..<lastSlash])
        } else {
            baseDir = ""
        }
        if baseDir.isEmpty { return target }

        let baseParts = baseDir.split(separator: "/").map(String.init)
        let targetParts = target.split(separator: "/").map(String.init)

        var common = 0
        while common < baseParts.count, common < targetParts.count,
              baseParts[common] == targetParts[common] {
            common += 1
        }
        let upHops = baseParts.count - common
        let down = Array(targetParts[common...])
        let prefix = String(repeating: "../", count: upHops)
        return prefix + down.joined(separator: "/")
    }

    // MARK: - String helpers

    static func splitFragment(_ href: String) -> (target: String, fragment: String) {
        if let hashIdx = href.firstIndex(of: "#") {
            return (
                String(href[..<hashIdx]),
                String(href[href.index(after: hashIdx)...])
            )
        }
        return (href, "")
    }

    /// True for hrefs with a URL scheme like `http:`, `mailto:`,
    /// `data:` — anything before a colon that isn't preceded by a
    /// slash. Conservative: a colon early in the string is taken
    /// as a scheme separator regardless of what follows.
    static func isExternal(_ href: String) -> Bool {
        guard let colonIdx = href.firstIndex(of: ":") else { return false }
        if let slashIdx = href.firstIndex(of: "/"), slashIdx < colonIdx {
            return false
        }
        return true
    }

    private static let attrRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(href|src)\s*=\s*("[^"]*"|'[^']*')"#,
        options: [.caseInsensitive]
    )
}
