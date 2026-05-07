import Foundation

/// Tier 9 / V-Trust-PerPage. Parse a user-typed page-range
/// string into a list of 0-indexed `ClosedRange<Int>` ranges.
///
/// Input format (1-based for the user; converted to 0-based):
///   * `"1-20"` → `[0...19]`
///   * `"5"` → `[4...4]`
///   * `"1-3, 10, 50-100"` → `[0...2, 9...9, 49...99]`
///
/// Whitespace around tokens / dashes is forgiven. Empty string
/// → empty array. Malformed tokens (non-numeric, reversed
/// ranges, zero or negative values) are skipped silently —
/// resilience > strictness, since the user is typing live and
/// we'd rather convert a partial-but-valid expression than
/// throw away the whole input on a typo. Invalid tokens end
/// up logged at parse time but don't fail conversion.
public enum PageRangeParser {

    /// Parse `input` into 0-indexed inclusive ranges. Adjacent /
    /// overlapping ranges are NOT merged — duplicates compose
    /// additively in the contains check, which is fine for
    /// `[ClosedRange].contains` to short-circuit on first match.
    public static func parse(_ input: String) -> [ClosedRange<Int>] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [ClosedRange<Int>] = []
        for raw in trimmed.split(separator: ",") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            if let dashIdx = token.firstIndex(of: "-") {
                let lhsStr = token[..<dashIdx]
                    .trimmingCharacters(in: .whitespaces)
                let rhsStr = token[token.index(after: dashIdx)...]
                    .trimmingCharacters(in: .whitespaces)
                guard let lhs = Int(lhsStr), let rhs = Int(rhsStr) else {
                    continue
                }
                guard lhs >= 1, rhs >= lhs else { continue }
                out.append((lhs - 1)...(rhs - 1))
            } else {
                guard let n = Int(token), n >= 1 else { continue }
                out.append((n - 1)...(n - 1))
            }
        }
        return out
    }

    /// Round-trip the structured form back to a canonical string.
    /// Useful for tests + for surfacing the parsed-back form so
    /// the user can see what we made of their input.
    public static func format(_ ranges: [ClosedRange<Int>]) -> String {
        ranges.map { r -> String in
            if r.lowerBound == r.upperBound {
                return "\(r.lowerBound + 1)"
            }
            return "\(r.lowerBound + 1)-\(r.upperBound + 1)"
        }.joined(separator: ", ")
    }
}
