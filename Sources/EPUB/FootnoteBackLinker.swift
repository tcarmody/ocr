import Foundation

/// Auto-link footnote references in body text to the matching
/// `<aside id="fn-N">` definitions, and back-link from the aside to
/// the ref. Operates on a single XHTML chapter buffer.
///
/// ## Heuristic
///
/// **Anchored on definitions.** Definitions in this codebase use
/// `<aside ... id="fn-N">`. We find every such id first, then only
/// look for refs whose number matches an existing id. That bounds
/// false positives to numbers that happen to equal an existing
/// footnote id — a chapter with three footnotes only risks
/// mis-linking 1/2/3.
///
/// **Patterns considered a ref (priority high → low):**
/// 1. `<sup>N</sup>` — semantic markup, the cleanest signal.
/// 2. `[N]` — square-bracket form.
/// 3. **Word-immediately-adjacent digit**: `…end.3`, `…word3`.
///    No whitespace between the preceding letter / sentence-terminal
///    punctuation and the digit. This is the common case in OCR'd
///    books where superscript styling was lost.
/// 4. Unicode superscript digits (`⁰¹²³…`) — same family as #1.
///
/// **Skip patterns (anti-context):**
/// - N preceded or followed by another digit → part of a larger
///   number (year, page count, ISBN).
/// - N immediately preceded (within ~16 chars) by a structure word:
///   `page`, `p.`, `pp.`, `Chapter`, `Ch.`, `Section`, `Sec.`, `§`,
///   `vol.`, `no.`, `Figure`, `Fig.`, `Table`, `verse`, `line`.
///   Strong signal that N refers to a non-footnote target.
///
/// **One ref per definition.** Some books reference the same
/// footnote multiple times, but linking only the first body
/// occurrence is the conservative choice; revisit if real-world
/// books push back.
///
/// ## Output shape
///
/// Ref gets wrapped in `<a href="#fn-N" id="fn-ref-N">…</a>`.
/// The aside gets a back-link appended:
/// `<a href="#fn-ref-N" class="footnote-backref">↩</a>`. Both the
/// `id` on the ref and the back-link id convention match standard
/// EPUB footnote idioms readers expect.
///
/// ## Limits
///
/// - Refs already inside an `<a href="…">…</a>` are skipped (don't
///   re-link).
/// - Refs that fall inside a footnote aside region itself are
///   skipped (so footnote 3's text containing the digit 3 doesn't
///   self-link).
/// - Operates byte-by-byte on the raw XHTML string. No XML parse
///   step; the cost is being slightly fragile on extremely
///   pathological markup, the benefit is that half-typed buffers
///   still get a meaningful pass.
public enum FootnoteBackLinker {

    /// A single ref-to-definition link the engine produced.
    public struct Link: Equatable {
        public let footnoteId: String       // "fn-3"
        public let pattern: Pattern
        public let snippet: String          // ~50 chars around for review

        public init(footnoteId: String, pattern: Pattern, snippet: String) {
            self.footnoteId = footnoteId
            self.pattern = pattern
            self.snippet = snippet
        }
    }

    /// Which heuristic matched a given ref.
    public enum Pattern: String, Equatable {
        case supTag         // <sup>3</sup>
        case bracket        // [3]
        case wordAdjacent   // …end.3
        case unicodeSup     // …end³
    }

    public struct Result: Equatable {
        public let rewritten: String
        public let links: [Link]
    }

    /// Link refs to footnote definitions in `xhtml`. Returns the
    /// rewritten buffer + a description of each link added. The
    /// rewritten buffer is byte-equal to the input when no links
    /// were added.
    public static func linkFootnotes(in xhtml: String) -> Result {
        let nsXHTML = xhtml as NSString

        // 1. Footnote definitions and their N values.
        let definitions = findFootnoteDefinitions(in: nsXHTML)
        guard !definitions.isEmpty else {
            return Result(rewritten: xhtml, links: [])
        }
        let idsByNumber = Dictionary(uniqueKeysWithValues: definitions.map { ($0.number, $0) })

        // 2. Regions to exclude from candidate detection: the aside
        //    bodies themselves (so footnote N's text doesn't
        //    self-link), and any existing `<a>` link spans (so we
        //    don't double-wrap an already-linked ref).
        let asideRanges = definitions.map { $0.range }
        let anchorRanges = findExistingAnchorRanges(in: nsXHTML)
        let excludedRanges = (asideRanges + anchorRanges)
            .sorted { $0.location < $1.location }

        // 3. Build a tag-position mask so text-only patterns
        //    (`[N]`, word-adjacent, unicode-sup) don't match inside
        //    tag attributes or names. `<sup>N</sup>` doesn't need
        //    this — its pattern intrinsically includes the tag.
        let tagMask = buildTagMask(nsXHTML)

        // 4. Candidate ref matches per pattern.
        var candidates: [Candidate] = []
        candidates += findSupCandidates(
            in: nsXHTML, ids: idsByNumber, excludedRanges: excludedRanges
        )
        candidates += findBracketCandidates(
            in: nsXHTML, ids: idsByNumber,
            excludedRanges: excludedRanges, tagMask: tagMask
        )
        candidates += findWordAdjacentCandidates(
            in: nsXHTML, ids: idsByNumber,
            excludedRanges: excludedRanges, tagMask: tagMask
        )
        candidates += findUnicodeSupCandidates(
            in: nsXHTML, ids: idsByNumber,
            excludedRanges: excludedRanges, tagMask: tagMask
        )

        // 5. One ref per definition — earliest match in document
        //    order wins. supTag / bracket / unicodeSup beat
        //    wordAdjacent at the same position only if they happen
        //    to match first (rare).
        var earliestByNumber: [Int: Candidate] = [:]
        for c in candidates.sorted(by: { $0.matchRange.location < $1.matchRange.location }) {
            if earliestByNumber[c.number] == nil {
                earliestByNumber[c.number] = c
            }
        }
        guard !earliestByNumber.isEmpty else {
            return Result(rewritten: xhtml, links: [])
        }

        // 6. Apply ref-wrap edits back-to-front so earlier offsets
        //    stay valid as we splice.
        var rewritten = xhtml
        var links: [Link] = []
        let chosen = earliestByNumber.values
            .sorted { $0.matchRange.location > $1.matchRange.location }
        for c in chosen {
            let def = idsByNumber[c.number]!
            let refReplacement = wrapAsRef(
                originalMatch: (rewritten as NSString).substring(with: c.matchRange),
                pattern: c.pattern,
                footnoteId: def.id
            )
            rewritten = (rewritten as NSString).replacingCharacters(
                in: c.matchRange, with: refReplacement
            )
            let snippet = snippetAround(
                fullString: xhtml as NSString,
                range: c.matchRange, span: 30
            )
            links.append(Link(
                footnoteId: def.id, pattern: c.pattern, snippet: snippet
            ))
        }

        // 7. Insert back-link `<a href="#fn-ref-N">↩</a>` just before
        //    each `</aside>` for definitions that got a ref linked.
        //    Has to walk the rewritten buffer fresh since aside
        //    ranges in the old buffer no longer apply after step 6.
        let linkedNumbers = Set(earliestByNumber.keys)
        rewritten = insertBackLinks(
            into: rewritten,
            forDefinitionNumbers: linkedNumbers
        )

        // Sort links by footnote number for stable review-order output.
        links.sort { lhs, rhs in
            (footnoteNumber(from: lhs.footnoteId) ?? .max)
                < (footnoteNumber(from: rhs.footnoteId) ?? .max)
        }
        return Result(rewritten: rewritten, links: links)
    }

    // MARK: - definitions

    struct Definition: Equatable {
        let id: String      // "fn-3"
        let number: Int     // 3
        let range: NSRange  // full `<aside …>…</aside>` span
    }

    private static let asideDefinitionRegex: NSRegularExpression = {
        // Match `<aside …>…</aside>` whose attributes include
        // `id="fn-N"`. Non-greedy body, dot-matches-newline so
        // pretty-printed asides span multiple lines.
        let pat = #"<aside\b[^>]*\bid=["']fn-(\d+)["'][^>]*>[\s\S]*?</aside>"#
        return try! NSRegularExpression(pattern: pat, options: [])
    }()

    private static func findFootnoteDefinitions(in s: NSString) -> [Definition] {
        let full = NSRange(location: 0, length: s.length)
        var out: [Definition] = []
        asideDefinitionRegex.enumerateMatches(in: s as String, options: [], range: full) {
            match, _, _ in
            guard let match,
                  let numberRange = Range(match.range(at: 1), in: s as String),
                  let number = Int((s as String)[numberRange])
            else { return }
            out.append(Definition(
                id: "fn-\(number)",
                number: number,
                range: match.range
            ))
        }
        return out
    }

    // MARK: - existing anchors

    private static let anchorRegex: NSRegularExpression = {
        // `<a …>…</a>` — non-greedy body, dot-matches-newline.
        try! NSRegularExpression(pattern: #"<a\b[^>]*>[\s\S]*?</a>"#, options: [])
    }()

    private static func findExistingAnchorRanges(in s: NSString) -> [NSRange] {
        let full = NSRange(location: 0, length: s.length)
        var out: [NSRange] = []
        anchorRegex.enumerateMatches(in: s as String, options: [], range: full) {
            match, _, _ in
            if let match { out.append(match.range) }
        }
        return out
    }

    // MARK: - candidate detection

    struct Candidate: Equatable {
        let pattern: Pattern
        let number: Int
        let matchRange: NSRange       // full match (e.g. `<sup>3</sup>` or `3`)
    }

    private static let supRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"<sup\b[^>]*>(\d{1,3})</sup>"#, options: [])
    }()

    private static func findSupCandidates(
        in s: NSString,
        ids: [Int: Definition],
        excludedRanges: [NSRange]
    ) -> [Candidate] {
        let full = NSRange(location: 0, length: s.length)
        var out: [Candidate] = []
        supRegex.enumerateMatches(in: s as String, options: [], range: full) {
            match, _, _ in
            guard let match,
                  let n = numberFromCaptureGroup1(match: match, in: s as String),
                  ids[n] != nil,
                  !isRangeExcluded(match.range, excluded: excludedRanges)
            else { return }
            out.append(Candidate(pattern: .supTag, number: n, matchRange: match.range))
        }
        return out
    }

    private static let bracketRegex: NSRegularExpression = {
        // [N] not embedded in a longer digit run (handled by the
        // brackets themselves) and not inside a tag.
        try! NSRegularExpression(pattern: #"\[(\d{1,3})\]"#, options: [])
    }()

    private static func findBracketCandidates(
        in s: NSString,
        ids: [Int: Definition],
        excludedRanges: [NSRange],
        tagMask: [Bool]
    ) -> [Candidate] {
        let full = NSRange(location: 0, length: s.length)
        var out: [Candidate] = []
        bracketRegex.enumerateMatches(in: s as String, options: [], range: full) {
            match, _, _ in
            guard let match,
                  let n = numberFromCaptureGroup1(match: match, in: s as String),
                  ids[n] != nil,
                  !isRangeExcluded(match.range, excluded: excludedRanges),
                  !isRangeInsideTag(match.range, mask: tagMask),
                  !isPrecededByStructureWord(s, at: match.range.location)
            else { return }
            // The match is `[N]`; we want to wrap only the digit so
            // the brackets stay outside the link. Narrow the range.
            let digitLocation = match.range.location + 1
            let digitLength = match.range.length - 2
            out.append(Candidate(
                pattern: .bracket, number: n,
                matchRange: NSRange(location: digitLocation, length: digitLength)
            ))
        }
        return out
    }

    private static let wordAdjacentRegex: NSRegularExpression = {
        // Digit run preceded by a letter or sentence-terminal
        // punctuation (no whitespace between). Negative lookahead
        // for trailing digit (so we don't grab the leading slice of
        // a larger number). Negative lookbehind for digit (same on
        // the leading side). Smart quotes included on the lead-in.
        //
        // Built as a regular (non-raw) string so the `\u{…}` escapes
        // interpolate to actual codepoints — raw-string syntax
        // would pass the text "\u{2019}" through verbatim and
        // NSRegularExpression would reject the pattern.
        let lead = "a-zA-Z\\)\\\".,;:!?'\u{2019}\u{201D}"
        let pat = "(?<![\\d])(?<=[\(lead)])(\\d{1,3})(?!\\d)"
        return try! NSRegularExpression(pattern: pat, options: [])
    }()

    private static func findWordAdjacentCandidates(
        in s: NSString,
        ids: [Int: Definition],
        excludedRanges: [NSRange],
        tagMask: [Bool]
    ) -> [Candidate] {
        let full = NSRange(location: 0, length: s.length)
        var out: [Candidate] = []
        wordAdjacentRegex.enumerateMatches(in: s as String, options: [], range: full) {
            match, _, _ in
            guard let match,
                  let n = numberFromCaptureGroup1(match: match, in: s as String),
                  ids[n] != nil,
                  !isRangeExcluded(match.range, excluded: excludedRanges),
                  !isRangeInsideTag(match.range, mask: tagMask),
                  !isPrecededByStructureWord(s, at: match.range.location)
            else { return }
            out.append(Candidate(
                pattern: .wordAdjacent, number: n, matchRange: match.range
            ))
        }
        return out
    }

    /// Unicode superscript digits — U+2070 / U+00B9 / U+00B2 /
    /// U+00B3 / U+2074…U+2079. A run is treated as a single ref.
    private static let unicodeSupRegex: NSRegularExpression = {
        let chars = "\u{2070}\u{00B9}\u{00B2}\u{00B3}\u{2074}\u{2075}\u{2076}\u{2077}\u{2078}\u{2079}"
        return try! NSRegularExpression(pattern: "([\(chars)]+)", options: [])
    }()

    private static let unicodeSupMap: [Character: Character] = [
        "\u{2070}": "0", "\u{00B9}": "1", "\u{00B2}": "2", "\u{00B3}": "3",
        "\u{2074}": "4", "\u{2075}": "5", "\u{2076}": "6", "\u{2077}": "7",
        "\u{2078}": "8", "\u{2079}": "9",
    ]

    private static func findUnicodeSupCandidates(
        in s: NSString,
        ids: [Int: Definition],
        excludedRanges: [NSRange],
        tagMask: [Bool]
    ) -> [Candidate] {
        let str = s as String
        let full = NSRange(location: 0, length: s.length)
        var out: [Candidate] = []
        unicodeSupRegex.enumerateMatches(in: str, options: [], range: full) {
            match, _, _ in
            guard let match,
                  let runRange = Range(match.range(at: 1), in: str)
            else { return }
            let asciiDigits = String(str[runRange].compactMap { unicodeSupMap[$0] })
            guard let n = Int(asciiDigits), ids[n] != nil,
                  !isRangeExcluded(match.range, excluded: excludedRanges),
                  !isRangeInsideTag(match.range, mask: tagMask)
            else { return }
            out.append(Candidate(
                pattern: .unicodeSup, number: n, matchRange: match.range
            ))
        }
        return out
    }

    // MARK: - anti-context check

    private static let structureWords: [String] = [
        "page", "p.", "pp.", "chapter", "ch.", "section", "sec.",
        "§", "vol.", "no.", "figure", "fig.", "table", "verse", "line",
    ]

    /// True when the character immediately preceding `location` (after
    /// skipping a single whitespace) is the tail of one of the
    /// `structureWords`. Window: ~16 chars back, lowercased compare.
    private static func isPrecededByStructureWord(_ s: NSString, at location: Int) -> Bool {
        let windowStart = max(0, location - 16)
        let windowLen = location - windowStart
        guard windowLen > 0 else { return false }
        let window = s.substring(with: NSRange(location: windowStart, length: windowLen))
            .lowercased()
        // Trim trailing whitespace / common punctuation that might
        // sit between the structure word and the digit.
        let trimmed = window.replacingOccurrences(
            of: "[\\s\\u{00A0}]+$", with: "", options: .regularExpression
        )
        for word in structureWords {
            if trimmed.hasSuffix(word) { return true }
        }
        return false
    }

    // MARK: - tag mask

    /// One Bool per UTF-16 code unit: `true` when the unit is inside
    /// a tag (between `<` and `>`, inclusive). Used to filter out
    /// pattern hits inside attribute values.
    static func buildTagMask(_ s: NSString) -> [Bool] {
        let length = s.length
        var mask = [Bool](repeating: false, count: length)
        var inTag = false
        for i in 0..<length {
            let unit = s.character(at: i)
            if inTag {
                mask[i] = true
                if unit == 0x3E /* > */ { inTag = false }
            } else if unit == 0x3C /* < */ {
                mask[i] = true
                inTag = true
            }
        }
        return mask
    }

    private static func isRangeInsideTag(_ range: NSRange, mask: [Bool]) -> Bool {
        let upper = min(range.location + range.length, mask.count)
        guard range.location < upper else { return false }
        for i in range.location..<upper {
            if mask[i] { return true }
        }
        return false
    }

    private static func isRangeExcluded(_ range: NSRange, excluded: [NSRange]) -> Bool {
        for r in excluded {
            if NSIntersectionRange(range, r).length > 0 { return true }
        }
        return false
    }

    // MARK: - apply

    private static func wrapAsRef(
        originalMatch: String,
        pattern: Pattern,
        footnoteId: String
    ) -> String {
        let refId = "fn-ref-\(footnoteId.dropFirst("fn-".count))"
        return "<a href=\"#\(footnoteId)\" id=\"\(refId)\" class=\"footnote-ref\">\(originalMatch)</a>"
    }

    /// Walks `s` for `<aside id="fn-N">…</aside>` and, when N is in
    /// `forDefinitionNumbers`, inserts a back-link just before
    /// `</aside>`. Skips asides that already contain a
    /// `class="footnote-backref"` link (re-running is safe).
    private static func insertBackLinks(
        into s: String,
        forDefinitionNumbers: Set<Int>
    ) -> String {
        var result = s
        let ns = result as NSString
        let full = NSRange(location: 0, length: ns.length)
        var matches: [(NSRange, Int)] = []
        asideDefinitionRegex.enumerateMatches(in: result, options: [], range: full) {
            match, _, _ in
            guard let match,
                  let numberRange = Range(match.range(at: 1), in: result),
                  let n = Int(result[numberRange]),
                  forDefinitionNumbers.contains(n)
            else { return }
            matches.append((match.range, n))
        }
        // Back-to-front so earlier offsets stay valid.
        for (range, n) in matches.reversed() {
            let asideText = (result as NSString).substring(with: range)
            if asideText.contains("class=\"footnote-backref\"") { continue }
            guard let closeRange = asideText.range(of: "</aside>", options: .backwards) else {
                continue
            }
            let backlink = "<a href=\"#fn-ref-\(n)\" class=\"footnote-backref\">↩</a>"
            let insertedAside = asideText.replacingCharacters(
                in: closeRange, with: "\(backlink)</aside>"
            )
            result = (result as NSString).replacingCharacters(
                in: range, with: insertedAside
            )
        }
        return result
    }

    // MARK: - helpers

    private static func numberFromCaptureGroup1(
        match: NSTextCheckingResult, in s: String
    ) -> Int? {
        guard let r = Range(match.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    private static func snippetAround(
        fullString: NSString, range: NSRange, span: Int
    ) -> String {
        let start = max(0, range.location - span)
        let end = min(fullString.length, range.location + range.length + span)
        var snippet = fullString.substring(with: NSRange(location: start, length: end - start))
        // Collapse whitespace for readability in the review list.
        snippet = snippet.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        if start > 0 { snippet = "…" + snippet }
        if end < fullString.length { snippet += "…" }
        return snippet
    }

    private static func footnoteNumber(from id: String) -> Int? {
        guard id.hasPrefix("fn-") else { return nil }
        return Int(id.dropFirst("fn-".count))
    }
}
