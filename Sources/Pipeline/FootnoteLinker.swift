import Foundation
import CoreGraphics
import Document
import Layout
import OCR

/// Per-page footnote detection + inline noteref linking.
///
/// Surya layout already classifies the *region* of footnotes; this
/// type (a) parses each footnote region into a `(marker, body)` pair
/// and (b) splices `<a epub:type="noteref">` runs into body paragraphs
/// where the same marker appears attached to a word.
///
/// Precision over recall, deliberately:
///   * markers are matched only against the markers parsed from
///     footnotes on the *same page*, so unknown digits (years,
///     section numbers) stay plain text;
///   * the inline match requires the marker to be glued to a
///     letter/punctuation on the left and followed by whitespace or
///     punctuation on the right — "page 11" doesn't match marker 11;
///   * footnote regions whose leading marker can't be parsed are
///     dropped (better silent loss than an invisible aside).
enum FootnoteLinker {

    /// Region kinds we treat as footnote bodies.
    static let footnoteKinds: Set<LayoutRegion.Kind> = [.footnote]

    /// Bbox inflation for matching observations to footnote regions
    /// (matches `RegionAwareReflow.regionInflation`).
    static let regionInflation: CGFloat = 0.005

    /// One parsed footnote awaiting EPUB emission.
    struct Parsed: Sendable, Equatable {
        let marker: String
        let body: String
        let id: String           // "fn-p{page}-{marker}"
    }

    /// Parse all footnote regions on a page.
    static func parseFootnotes(
        pageIndex: Int,
        observations: [TextObservation],
        regions: [LayoutRegion]
    ) -> [Parsed] {
        var out: [Parsed] = []
        var seenMarkers = Set<String>()
        for region in regions where footnoteKinds.contains(region.kind) {
            let inflated = region.box.insetBy(dx: -regionInflation, dy: -regionInflation)
            let inRegion = observations.filter { obs in
                inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
            }
            guard !inRegion.isEmpty else { continue }
            let sorted = inRegion.sorted { a, b in
                if abs(a.box.midY - b.box.midY) > 0.005 { return a.box.midY > b.box.midY }
                return a.box.minX < b.box.minX
            }
            let joined = joinWithDehyphenation(sorted.map(\.text))
            guard let (marker, body) = splitMarkerAndBody(joined) else { continue }
            // Numbered footnotes generally don't repeat per page, but
            // OCR sometimes splits one footnote across two regions and
            // both regions parse the same marker. Skip duplicates;
            // first one wins.
            if seenMarkers.contains(marker) { continue }
            seenMarkers.insert(marker)
            out.append(Parsed(
                marker: marker,
                body: body,
                id: "fn-p\(pageIndex)-\(marker)"
            ))
        }
        return out
    }

    /// Splice noteref runs into a paragraph string. Returns the original
    /// text as a single run if no markers match (the common case for
    /// pages with footnotes — most paragraphs don't reference one).
    static func splice(
        text: String,
        footnotes: [Parsed],
        isItalic: Bool = false,
        isBold: Bool = false
    ) -> [InlineRun] {
        guard !footnotes.isEmpty, !text.isEmpty else {
            return [InlineRun(text, isItalic: isItalic, isBold: isBold)]
        }
        // Match longer markers first so "11" wins over "1" when both
        // exist on a page.
        let sortedMarkers = footnotes
            .sorted { $0.marker.count > $1.marker.count }

        var runs: [InlineRun] = []
        var cursor = text.startIndex

        // Walk left-to-right, finding the next match across all markers.
        while cursor < text.endIndex {
            var nextMatch: (range: Range<String.Index>, fn: Parsed)? = nil
            for fn in sortedMarkers {
                guard let r = nextInlineMatch(of: fn.marker, in: text, from: cursor) else {
                    continue
                }
                if let cur = nextMatch {
                    if r.lowerBound < cur.range.lowerBound {
                        nextMatch = (r, fn)
                    }
                } else {
                    nextMatch = (r, fn)
                }
            }
            guard let m = nextMatch else { break }
            if cursor < m.range.lowerBound {
                runs.append(InlineRun(
                    String(text[cursor..<m.range.lowerBound]),
                    isItalic: isItalic, isBold: isBold
                ))
            }
            // The noteref marker itself doesn't inherit emphasis —
            // the marker is structural, not part of the surrounding
            // body's typographic style.
            runs.append(InlineRun(
                String(text[m.range]),
                noterefId: m.fn.id
            ))
            cursor = m.range.upperBound
        }
        if cursor < text.endIndex {
            runs.append(InlineRun(
                String(text[cursor..<text.endIndex]),
                isItalic: isItalic, isBold: isBold
            ))
        }
        let base = runs.isEmpty
            ? [InlineRun(text, isItalic: isItalic, isBold: isBold)]
            : runs
        // Surya (and any other math-aware OCR engine) embeds inline
        // `<math>…</math>` markup in its recognized text. Expand any
        // such spans into proper rawXHTML runs before the writer
        // ever sees them; otherwise they get XML-escaped and the
        // reader sees literal `&lt;math&gt;` in place of the math.
        return InlineMathSplitter.split(base)
    }

    /// Build chapter-level Footnote values from per-page Parsed lists.
    /// Footnote bodies go through the same math-markup splitter as
    /// body paragraphs — an inline `<math>w_m</math>` in a footnote
    /// body must round-trip as MathML, not as literal escaped text.
    static func footnotesForChapter(_ parsed: [Parsed]) -> [Footnote] {
        parsed.map { p in
            Footnote(
                id: p.id, marker: p.marker,
                runs: InlineMathSplitter.split([InlineRun(p.body)])
            )
        }
    }

    // MARK: - parsing

    /// Strip the leading marker from a footnote string.
    /// Returns nil when no parseable marker is present.
    static func splitMarkerAndBody(_ text: String) -> (marker: String, body: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Numeric: "1.", "12)", "3 ", "5\u{00A0}" (NBSP)
        if let m = leadingNumericMatch(in: trimmed) {
            return m
        }
        // Symbolic single-char marker: * † ‡ § ¶ •
        if let first = trimmed.unicodeScalars.first,
           symbolicMarkers.contains(Character(first)) {
            let marker = String(Character(first))
            let after = trimmed.dropFirst()
            let body = String(after).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return (marker, body)
        }
        return nil
    }

    private static let symbolicMarkers: Set<Character> = ["*", "†", "‡", "§", "¶", "•"]

    /// Match a leading run of digits followed by a marker terminator.
    /// Accept "1.", "1)", "1 ", "1\u{00A0}", or bare digits if the next
    /// char is a capital letter (common in OCR: "1Foucault writes..." —
    /// the period after the marker got eaten).
    private static func leadingNumericMatch(in text: String) -> (marker: String, body: String)? {
        var idx = text.startIndex
        var digits = ""
        while idx < text.endIndex, text[idx].isNumber {
            digits.append(text[idx])
            idx = text.index(after: idx)
        }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        guard idx < text.endIndex else { return nil }

        let after = text[idx]
        let bodyStart: String.Index
        switch after {
        case ".", ")", ":":
            bodyStart = text.index(after: idx)
        case " ", "\u{00A0}", "\t":
            bodyStart = text.index(after: idx)
        default:
            // Unpunctuated marker is acceptable only when the body looks
            // like prose: next char is a capital letter or quotation mark.
            // (Mid-sentence digits like "1968" are excluded by the
            // 3-digit cap above and by the bodyStart sanity check below.)
            if after.isUppercase || after == "\u{201C}" || after == "\"" || after == "'" {
                bodyStart = idx
            } else {
                return nil
            }
        }
        let body = text[bodyStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return (digits, body)
    }

    // MARK: - inline matching

    /// Find the next inline occurrence of `marker` in `text` starting
    /// from `lower`. Precision-first rules:
    ///
    ///   * The character immediately *before* the marker must be a
    ///     letter or punctuation — not a digit (so "1968" doesn't
    ///     match marker "8") and not whitespace (so " 1 " in "page 1"
    ///     doesn't match marker "1").
    ///   * The character immediately *after* the marker must be
    ///     whitespace, punctuation, or end-of-string — not a digit
    ///     (so "12" doesn't match marker "1").
    ///   * Symbolic markers (*, †, …) skip the "preceded by letter"
    ///     requirement when at the start of a word, since they often
    ///     appear with a space before — but still require the right-
    ///     side terminator.
    static func nextInlineMatch(
        of marker: String,
        in text: String,
        from lower: String.Index
    ) -> Range<String.Index>? {
        guard !marker.isEmpty, lower < text.endIndex else { return nil }
        var search = lower
        while search < text.endIndex {
            guard let r = text.range(of: marker, options: .literal, range: search..<text.endIndex)
            else { return nil }
            let leftOK: Bool
            if r.lowerBound == text.startIndex {
                // Marker at start of a string we were handed — almost
                // always a footnote body, not an inline reference.
                leftOK = false
            } else {
                let prev = text[text.index(before: r.lowerBound)]
                if marker.first?.isNumber == true {
                    leftOK = prev.isLetter
                        || prev == "."
                        || prev == ","
                        || prev == ";"
                        || prev == ":"
                        || prev == "!"
                        || prev == "?"
                        || prev == ")"
                        || prev == "]"
                        || prev == "\""
                        || prev == "'"
                        || prev == "\u{201D}"  // right double quote
                        || prev == "\u{2019}"  // right single quote
                } else {
                    // Symbolic marker — may appear after a word with no
                    // intervening space, OR immediately after a space
                    // following a word.
                    leftOK = prev.isLetter || prev == "." || prev == "," || prev == ";"
                        || prev == ":" || prev == "!" || prev == "?"
                        || prev == ")" || prev == "]" || prev == "\""
                        || prev == "'" || prev == "\u{201D}" || prev == "\u{2019}"
                }
            }
            let rightOK: Bool
            if r.upperBound == text.endIndex {
                rightOK = true
            } else {
                let next = text[r.upperBound]
                rightOK = next.isWhitespace
                    || next == "."
                    || next == ","
                    || next == ";"
                    || next == ":"
                    || next == "!"
                    || next == "?"
                    || next == ")"
                    || next == "]"
                    || next == "\""
                    || next == "'"
                    || next == "\u{201D}"
                    || next == "\u{2019}"
                    // accept follow-on text glued to the marker iff the
                    // next char is uppercase (Vision sometimes drops
                    // the trailing space): "case.3In other words" → 3.
                    || next.isUppercase
            }
            if leftOK && rightOK {
                return r
            }
            search = text.index(after: r.lowerBound)
        }
        return nil
    }

    // MARK: - shared helpers

    private static func joinWithDehyphenation(_ lines: [String]) -> String {
        guard let first = lines.first else { return "" }
        var acc = first.trimmingCharacters(in: .whitespaces)
        for next in lines.dropFirst() {
            acc = Dehyphenation.join(acc, next)
        }
        return acc
    }
}
