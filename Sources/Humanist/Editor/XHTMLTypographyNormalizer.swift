import Foundation
import Pipeline

/// Apply `Pipeline.TypographyNormalizer.normalize(_:)` to the text
/// segments of an XHTML buffer, leaving characters inside tags
/// untouched. Same posture as `EPUB.SmartQuoter` — walk the source
/// tracking `inTag`, transform only the prose between tags so
/// attribute values, XML comments (which can contain `--`), CDATA
/// sections, processing instructions, and DOCTYPE declarations
/// stay byte-stable.
///
/// `Pipeline.TypographyNormalizer` already encapsulates the
/// per-text rewrites (ligature decomposition, soft-hyphen strip,
/// `--` → `—`, digit-range `-` → `–`) for the OCR pipeline's
/// `[Block]` output. We can't lift that into `EPUB` for direct
/// reuse — `EPUB` depends on `Document` only, and `Pipeline`
/// depends on `EPUB`. Bridging in the Humanist module is the
/// path of least friction: only the editor's user-triggered
/// "Normalize Typography" command needs tag-skipping today.
enum XHTMLTypographyNormalizer {

    /// Walk `source`, applying `Pipeline.TypographyNormalizer` to
    /// each text chunk and passing tag bytes through verbatim.
    static func normalize(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var textBuf = ""
        var inTag = false
        for ch in source {
            if inTag {
                out.append(ch)
                if ch == ">" { inTag = false }
                continue
            }
            if ch == "<" {
                if !textBuf.isEmpty {
                    out.append(Pipeline.TypographyNormalizer.normalize(textBuf))
                    textBuf.removeAll(keepingCapacity: true)
                }
                inTag = true
                out.append(ch)
                continue
            }
            textBuf.append(ch)
        }
        if !textBuf.isEmpty {
            out.append(Pipeline.TypographyNormalizer.normalize(textBuf))
        }
        return out
    }
}
