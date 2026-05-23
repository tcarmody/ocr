import Foundation
import Document

/// Expand inline `<math>…</math>` markup that arrives **inside an
/// `InlineRun.text` field** into proper rawXHTML runs. Surya (and
/// other OCR engines that are math-aware) sometimes wrap inline
/// math variables in `<math>` tags as part of their recognized
/// text — the body comes through as `"two time inputs <math>t_m
/// </math> and <math>t_f</math>"`. Without expansion that text
/// gets XML-escaped by `XHTMLWriter` and the reader sees literal
/// `&lt;math&gt;t_m&lt;/math&gt;` in place of the math.
///
/// This helper detects each `<math…>…</math>` span in a run's
/// text and splits the run into:
///   * a text run for the prefix (carries the source run's
///     emphasis / language / noteref),
///   * a rawXHTML run containing the canonical MathML markup
///     (`xmlns` re-added defensively, plain-text fallback
///     populated from the tags' inner content for downstream
///     Markdown / `.txt` writers),
///   * a text run for the suffix (recursively split — multiple
///     `<math>` spans on one paragraph are common in dense
///     academic prose).
///
/// Runs whose text contains no `<math` are returned unchanged.
/// Runs that already have a `rawXHTML` value set pass through
/// untouched (already-captured math from
/// `PageXHTMLParser` doesn't get re-processed).
enum InlineMathSplitter {

    /// Apply the splitter to every run in `runs`, returning a
    /// possibly-longer array with text→rawXHTML splits expanded.
    static func split(_ runs: [InlineRun]) -> [InlineRun] {
        var out: [InlineRun] = []
        out.reserveCapacity(runs.count)
        for run in runs {
            out.append(contentsOf: split(run))
        }
        return out
    }

    /// Split a single run. Returns `[run]` unchanged when the
    /// text carries no `<math>` markup or the run already has
    /// `rawXHTML` populated (PageXHTMLParser already captured
    /// the markup; don't double-process).
    static func split(_ run: InlineRun) -> [InlineRun] {
        guard run.rawXHTML == nil else { return [run] }
        let text = run.text
        guard text.contains("<math") else { return [run] }

        var out: [InlineRun] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let openStart = text.range(
                of: "<math", range: cursor..<text.endIndex
              ) {
            // Find the end of the opening tag (`>`); if missing,
            // the `<math` is a stray prefix — bail and treat the
            // remainder as plain text.
            guard let openEnd = text.range(
                of: ">", range: openStart.upperBound..<text.endIndex
            ) else { break }
            // Find the matching `</math>` close. Conservative:
            // if absent, treat the whole tail as plain text.
            guard let closeRange = text.range(
                of: "</math>", range: openEnd.upperBound..<text.endIndex
            ) else { break }

            // Prefix run (if any) carries the source run's emphasis,
            // language, and noteref.
            if cursor < openStart.lowerBound {
                let prefix = String(text[cursor..<openStart.lowerBound])
                if !prefix.isEmpty {
                    out.append(InlineRun(
                        prefix,
                        language: run.language,
                        noterefId: run.noterefId,
                        isItalic: run.isItalic,
                        isBold: run.isBold
                    ))
                }
            }

            // Raw MathML run. Re-add the canonical MathML namespace
            // when the open tag doesn't already carry one (Surya's
            // output uses bare `<math>` without xmlns; PageXHTMLParser's
            // capture path applies the same defensive re-add).
            let openTagSrc = String(text[openStart.lowerBound..<openEnd.upperBound])
            let innerSrc = String(text[openEnd.upperBound..<closeRange.lowerBound])
            let canonicalOpen = ensureMathNamespace(in: openTagSrc)
            let mathML = canonicalOpen + innerSrc + "</math>"
            // Plain-text fallback for sibling .txt / .md writers
            // that don't render MathML — strip remaining markup so
            // the fallback isn't itself full of angle brackets.
            let fallback = innerSrc
                .replacingOccurrences(
                    of: "<[^>]+>", with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)
            out.append(InlineRun(
                fallback.isEmpty ? "[math]" : fallback,
                rawXHTML: mathML
            ))

            cursor = closeRange.upperBound
        }

        // Tail (anything after the last close, OR the whole text
        // when no valid `<math>…</math>` pair was found above).
        if cursor < text.endIndex {
            let tail = String(text[cursor..<text.endIndex])
            if !tail.isEmpty {
                out.append(InlineRun(
                    tail,
                    language: run.language,
                    noterefId: run.noterefId,
                    isItalic: run.isItalic,
                    isBold: run.isBold
                ))
            }
        }

        // Defensive: if the scan found a `<math` prefix but never
        // a clean open+close pair, fall back to the original run
        // so the reader at least sees the raw text rather than
        // nothing.
        return out.isEmpty ? [run] : out
    }

    /// Re-add `xmlns="http://www.w3.org/1998/Math/MathML"` to the
    /// open tag when it's missing. The XHTML writer / EPUB reader
    /// needs the canonical namespace to render correctly; engines
    /// that emit shortcut `<math>…</math>` without xmlns get fixed
    /// up here so the rendered output is consistent regardless of
    /// source.
    static func ensureMathNamespace(in openTag: String) -> String {
        if openTag.contains("xmlns") { return openTag }
        // Insert `xmlns=…` immediately before the closing `>`.
        guard let closeIdx = openTag.lastIndex(of: ">") else {
            return openTag
        }
        let prefix = openTag[openTag.startIndex..<closeIdx]
        let suffix = openTag[closeIdx...]
        let ns = #" xmlns="http://www.w3.org/1998/Math/MathML""#
        return String(prefix) + ns + String(suffix)
    }
}
