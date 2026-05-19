import Foundation

/// P-Verse-Layout. One visual line of a verse region. Preserves the
/// line's leading indent as a quantized bucket (0–8) so the XHTML
/// renderer can emit `<p class="line indent-N">` and the
/// stylesheet's `indent-N` CSS class can map it to a per-bucket
/// `padding-left`. The runs carry inline language / emphasis spans
/// the same way `Block.paragraph.runs` does — verse lines mix
/// English narrative with Italian / Greek / Latin fragments
/// routinely (Pound, Eliot, late Stevens) and the InlineRun
/// language tag drives screen-reader and font-shaping correctness.
public struct VerseLine: Sendable, Equatable, Codable {
    /// Inline content of this line, in document order. A typical
    /// English line is a single run; a mixed-script line splits at
    /// script boundaries (Greek codepoints get their own run with
    /// `language = BCP47("grc")`).
    public var runs: [InlineRun]

    /// Quantized leading-indent bucket. 0 = flush left; 8 = far
    /// right (≥ 80% of the region width). Maps to a CSS class
    /// `.indent-N` in `EPUBStaticFiles.bookCSS`. Quantizing avoids
    /// the brittleness of preserving exact em-values across font
    /// changes in the reader.
    public var indent: Int

    public init(runs: [InlineRun], indent: Int = 0) {
        self.runs = runs
        // Clamp defensively so a buggy classifier can't produce
        // an out-of-range bucket. The CSS only defines 0…8.
        self.indent = max(0, min(8, indent))
    }
}
