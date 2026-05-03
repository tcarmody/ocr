import Foundation

/// Heuristics for joining text fragments split across line breaks.
///
/// PDFs frequently break words at line boundaries with a soft hyphen:
///   "Men-"
///   "delssohn"
/// We want to recover "Mendelssohn", not "Men- delssohn" or "Men-delssohn".
///
/// We do NOT have a dictionary, so we rely on a casing heuristic:
///   * `lhs` ends with `-` immediately preceded by a letter, AND
///   * `rhs` begins with a lowercase letter
/// → strip the hyphen, join with no space.
///
/// This misclassifies legitimate compound hyphens like "well-known" as soft
/// hyphens when split across lines, joining them as "wellknown". That's
/// rare in practice (typesetters usually keep compounds intact) and the
/// false-positive cost is much smaller than the false-negative cost of
/// leaving every soft-hyphenated word broken.
enum Dehyphenation {
    /// Join two text fragments from adjacent lines, dehyphenating if
    /// appropriate. Trims surrounding whitespace from inputs.
    static func join(_ lhs: String, _ rhs: String) -> String {
        let l = lhs.trimmingCharacters(in: .whitespaces)
        let r = rhs.trimmingCharacters(in: .whitespaces)
        if l.isEmpty { return r }
        if r.isEmpty { return l }

        if shouldDehyphenate(lhs: l, rhs: r) {
            return String(l.dropLast()) + r
        }
        return l + " " + r
    }

    /// Whether to drop a trailing hyphen from `lhs` when joining with `rhs`.
    static func shouldDehyphenate(lhs: String, rhs: String) -> Bool {
        guard lhs.hasSuffix("-") else { return false }
        // Need a letter immediately before the hyphen (not e.g. "1-").
        let beforeHyphen = lhs.dropLast()
        guard let last = beforeHyphen.last, last.isLetter else { return false }
        // Next fragment must start with a lowercase letter.
        guard let first = rhs.first, first.isLetter, first.isLowercase else { return false }
        return true
    }
}
