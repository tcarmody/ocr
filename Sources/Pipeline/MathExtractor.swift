import Foundation
import CoreGraphics
import OCR

/// One math extraction's worth of output: MathML for the EPUB,
/// LaTeX for sibling Markdown / plain-text / HTML outputs.
///
/// `mathML` MUST be a single `<math>` element carrying its own
/// `xmlns="http://www.w3.org/1998/Math/MathML"` — the reflow stage
/// drops it verbatim into an `InlineRun.rawXHTML` and the EPUB
/// writer emits it without escaping.
///
/// `latex` is the LaTeX source for the same equation, in
/// `\frac{}{}`-style notation (no `$…$` delimiters; writers add
/// those). When non-nil, sibling Markdown / `.txt` writers emit
/// the LaTeX inside `$…$` or `$$…$$` delimiters instead of the
/// tag-stripped MathML fallback — academic toolchains (Pandoc,
/// Obsidian, LaTeX papers) read this notation natively. `nil`
/// when the backend can't produce LaTeX; sibling writers fall
/// back to plain-text in that case.
public struct MathExtractionResult: Sendable, Equatable {
    public let mathML: String
    public let latex: String?

    public init(mathML: String, latex: String? = nil) {
        self.mathML = mathML
        self.latex = latex
    }
}

/// Common shape for any backend that turns a `.formula` region into
/// MathML (and optionally LaTeX). Returning `nil` means "skip / fall
/// back to the raster figure" — the cascade emits a `Block.figure`
/// with the region's PNG as the user-visible fallback.
///
/// Today only `ClaudeMathExtractor` (Sonnet 4.6) conforms; future
/// Gemini Flash and Mathpix implementations will conform without
/// touching the cascade-loop call site (mirrors `TableExtractor`).
public protocol MathExtractor: Sendable {
    func extract(
        pageImage: CGImage,
        regionBox: CGRect,
        stagingDir: URL,
        pageIndex: Int,
        regionIndex: Int
    ) async -> MathExtractionResult?
}
