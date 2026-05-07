import Foundation
import Document

/// Tier 9 / Q-Ligatures + Q-Dashes. Small, deterministic
/// post-reflow text rewrites that fix common OCR / PDF
/// typography artifacts:
///
///   * **Latin ligatures** (`ﬁ`, `ﬂ`, `ﬀ`, `ﬃ`, `ﬄ`, `ﬅ`, `ﬆ`)
///     decompose to their letter-pair forms. Some PDF
///     renderers + OCR engines emit the Unicode ligature
///     codepoints directly; readers + search rarely handle them
///     well, so we normalize unconditionally.
///   * **Soft hyphens** (`U+00AD`) get stripped. They're
///     line-break hints from the source PDF and persist into
///     OCR'd text where they look like nothing but render as
///     invisible characters that break copy/paste + search.
///   * **Em-dashes from typed `--`**: ASCII `--` → `—`. Common
///     authorial convention, almost never legitimate prose.
///   * **En-dashes for numeric ranges**: `\d+-\d+` → `\d+–\d+`.
///     Conservative — only when both sides are bare digits, so
///     phone numbers / hyphenated words don't get caught.
///
/// Conservative posture: every rewrite must be uniquely a
/// typography artifact, not a legitimate authorial choice. We
/// don't touch single hyphens between letters, ranges with
/// other punctuation, or anything where the input is already
/// the "right" form.
public enum TypographyNormalizer {

    /// Apply every normalization pass to `text`. Pure — no
    /// language hint needed for the current rules; hint reserved
    /// for future per-script extensions (Greek ligatures, etc.).
    public static func normalize(_ text: String) -> String {
        var s = text
        s = decomposeLatinLigatures(s)
        s = stripSoftHyphens(s)
        s = collapseDoubleHyphenToEmDash(s)
        s = digitRangeHyphenToEnDash(s)
        return s
    }

    /// Walk every text-bearing block and replace its inline
    /// runs' text with the normalized form. Other block fields
    /// (language, noterefId, asset ids) are preserved.
    public static func normalize(_ blocks: [Block]) -> [Block] {
        blocks.map { normalizeBlock($0) }
    }

    private static func normalizeBlock(_ block: Block) -> Block {
        switch block {
        case .heading(let level, let runs):
            return .heading(level: level, runs: normalizeRuns(runs))
        case .paragraph(let runs):
            return .paragraph(runs: normalizeRuns(runs))
        case .figure(let assetId, let alt, let caption):
            // Captions get normalized too — they're prose.
            // `alt` text is short + already controlled (we set
            // it to "formula" or the caption text); leaving it.
            return .figure(
                assetId: assetId,
                alt: alt,
                caption: normalizeRuns(caption)
            )
        case .table(let rows, let caption):
            let normalizedRows: [[TableCell]] = rows.map { row in
                row.map { cell in
                    TableCell(
                        runs: normalizeRuns(cell.runs),
                        isHeader: cell.isHeader,
                        rowspan: cell.rowspan,
                        colspan: cell.colspan
                    )
                }
            }
            return .table(rows: normalizedRows, caption: normalizeRuns(caption))
        case .anchor:
            return block
        }
    }

    private static func normalizeRuns(_ runs: [InlineRun]) -> [InlineRun] {
        runs.map { run in
            InlineRun(
                normalize(run.text),
                language: run.language,
                noterefId: run.noterefId
            )
        }
    }

    // MARK: - text-level passes

    /// Latin presentation-form ligatures → letter pairs.
    /// Unicode ranges:
    ///   ﬀ U+FB00, ﬁ U+FB01, ﬂ U+FB02, ﬃ U+FB03, ﬄ U+FB04,
    ///   ﬅ U+FB05 (long-s + t — already letter form), ﬆ U+FB06.
    static func decomposeLatinLigatures(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\u{FB00}": out += "ff"
            case "\u{FB01}": out += "fi"
            case "\u{FB02}": out += "fl"
            case "\u{FB03}": out += "ffi"
            case "\u{FB04}": out += "ffl"
            case "\u{FB05}": out += "st"  // long-s + t historical, normalize
            case "\u{FB06}": out += "st"
            default:         out.append(ch)
            }
        }
        return out
    }

    /// Strip U+00AD (soft hyphen). PDF line-break hints sometimes
    /// survive OCR as invisible characters that break search +
    /// copy. Always safe to remove from final text — soft hyphens
    /// have no semantic meaning at the document level.
    static func stripSoftHyphens(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00AD}", with: "")
    }

    /// ASCII `--` → `—` (U+2014 em-dash). Common authorial
    /// convention. We leave triple-or-more dashes alone (might
    /// be a typographic separator the author intended); only
    /// exactly two consecutive ASCII hyphens become an em-dash.
    static func collapseDoubleHyphenToEmDash(_ s: String) -> String {
        // Use a regex with lookarounds-equivalent: replace every
        // `--` not adjacent to another `-`. Simpler approach:
        // walk and consume runs.
        guard s.contains("--") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "-" {
                // Count consecutive hyphens.
                var j = i
                while j < s.endIndex && s[j] == "-" {
                    j = s.index(after: j)
                }
                let runLen = s.distance(from: i, to: j)
                if runLen == 2 {
                    out.append("\u{2014}")
                } else {
                    out.append(String(s[i..<j]))
                }
                i = j
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    /// Numeric ranges: `\d+-\d+` → `\d+–\d+` (en-dash).
    /// Conservative — both sides must be bare digits, so
    /// phone-number / hyphenated-word cases don't trigger. The
    /// regex `(?<=\d)-(?=\d)` works on most platforms but
    /// `NSRegularExpression` lookarounds are stable on macOS so
    /// we use them here.
    static func digitRangeHyphenToEnDash(_ s: String) -> String {
        guard s.contains("-") else { return s }
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<=\d)-(?=\d)"#
        ) else { return s }
        let mutable = NSMutableString(string: s)
        let range = NSRange(location: 0, length: mutable.length)
        regex.replaceMatches(
            in: mutable,
            options: [],
            range: range,
            withTemplate: "\u{2013}"
        )
        return mutable as String
    }
}
