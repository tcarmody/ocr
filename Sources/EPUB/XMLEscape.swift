import Foundation

/// XHTML / XML attribute and text-node escaping. Foundation has no built-in
/// escaper; reaching for HTMLString-style libraries is overkill.
///
/// We escape `&` first so we don't double-escape entities we just produced.
enum XMLEscape {
    static func text(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        return out
    }

    static func attribute(_ s: String) -> String {
        var out = text(s)
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }
}
