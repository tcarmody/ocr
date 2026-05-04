import Foundation
import AppKit
import CoreGraphics
import PDFKit

/// Splits a "two-up" PDF (two book pages per landscape PDF page)
/// into a new PDF with one book page per portrait page. Two modes:
///
///   * `forceSplitAllPages: false` — per-page detection. Pages
///     flagged by `TwoUpDetector.isTwoUpPage` get halved; everything
///     else is passed through unchanged. Used by the auto-split path.
///   * `forceSplitAllPages: true` — every landscape page is halved
///     unconditionally. Used by the manual `Split Two-Up PDF…` menu
///     command, where the user is asserting "yes, split this."
///
/// Output is rasterized at the chosen DPI in display orientation
/// (rotation honored). Vector content from the source is lost, but
/// for scanned books the source is already raster-only, and the OCR
/// pipeline re-renders pages anyway.
public enum TwoUpSplitter {
    public enum SplitError: Error, LocalizedError {
        case sourceLoadFailed
        case writeFailed
        case noPagesProduced

        public var errorDescription: String? {
            switch self {
            case .sourceLoadFailed:  return "Could not load source PDF"
            case .writeFailed:       return "Could not write split PDF"
            case .noPagesProduced:   return "No pages in the split PDF — source may be empty"
            }
        }
    }

    /// Build a split PDF at `outputURL`. `dpi` controls the
    /// rasterization resolution of split pages; the default 300
    /// matches typical print-book scans and stays sharp at editor
    /// zoom levels.
    ///
    /// `forceSplitAllPages` bypasses the per-page two-up detector
    /// and halves every landscape page. Portrait pages are still
    /// passed through unchanged regardless of mode (halving a
    /// portrait page is meaningless).
    ///
    /// Returns the count of (output pages, source pages that were
    /// split). A source page that didn't split is counted as one
    /// output page; one that did contributes two.
    @discardableResult
    public static func split(
        pdfURL: URL,
        outputURL: URL,
        dpi: CGFloat = 300,
        forceSplitAllPages: Bool = false
    ) throws -> (outputPages: Int, splitSources: Int) {
        guard let source = PDFDocument(url: pdfURL) else {
            throw SplitError.sourceLoadFailed
        }
        let output = PDFDocument()
        var outIdx = 0
        var splitSources = 0

        for i in 0..<source.pageCount {
            guard let page = source.page(at: i) else { continue }
            let (displayW, displayH) = TwoUpDetector.displayDimensions(page)

            let shouldSplit: Bool
            if forceSplitAllPages {
                // Manual mode: split anything that's wider than tall.
                // We don't apply the gutter heuristic here — the user
                // already told us this is a two-up document.
                shouldSplit = displayH > 0 && displayW / displayH > 1.0
            } else {
                shouldSplit = TwoUpDetector.isTwoUpPage(page)
            }

            if shouldSplit {
                splitSources += 1
                if let leftPage = makeHalfPage(
                    of: page, side: .left,
                    displayWidth: displayW, displayHeight: displayH, dpi: dpi
                ) {
                    output.insert(leftPage, at: outIdx); outIdx += 1
                }
                if let rightPage = makeHalfPage(
                    of: page, side: .right,
                    displayWidth: displayW, displayHeight: displayH, dpi: dpi
                ) {
                    output.insert(rightPage, at: outIdx); outIdx += 1
                }
            } else {
                if let copy = makeFullPage(
                    of: page, displayWidth: displayW, displayHeight: displayH, dpi: dpi
                ) {
                    output.insert(copy, at: outIdx); outIdx += 1
                }
            }
        }

        guard outIdx > 0 else { throw SplitError.noPagesProduced }
        guard output.write(to: outputURL) else {
            throw SplitError.writeFailed
        }
        return (outIdx, splitSources)
    }

    private enum HalfSide { case left, right }

    /// Render the left or right half of `page` (in display
    /// orientation) at the given DPI and wrap as a fresh PDFPage.
    /// Implementation note: we render the full page first via
    /// `PDFPage.thumbnail` (which honors `/Rotate`), then crop the
    /// resulting image. Going via the rasterized image avoids
    /// having to rebuild PDFKit's rotation transform manually.
    private static func makeHalfPage(
        of page: PDFPage, side: HalfSide,
        displayWidth: CGFloat, displayHeight: CGFloat, dpi: CGFloat
    ) -> PDFPage? {
        guard let full = renderDisplayOriented(
            page: page, displayWidth: displayWidth,
            displayHeight: displayHeight, dpi: dpi
        ) else { return nil }
        let halfPixels = full.width / 2
        let cropRect: CGRect
        switch side {
        case .left:
            cropRect = CGRect(x: 0, y: 0, width: halfPixels, height: full.height)
        case .right:
            cropRect = CGRect(x: halfPixels, y: 0, width: full.width - halfPixels, height: full.height)
        }
        guard let cropped = full.cropping(to: cropRect) else { return nil }
        let nsImage = NSImage(
            cgImage: cropped,
            size: NSSize(width: cropped.width, height: cropped.height)
        )
        return PDFPage(image: nsImage)
    }

    /// Re-emit the full page (used for non-two-up pages in a mixed
    /// document) in display orientation at the chosen DPI.
    private static func makeFullPage(
        of page: PDFPage,
        displayWidth: CGFloat, displayHeight: CGFloat, dpi: CGFloat
    ) -> PDFPage? {
        guard let img = renderDisplayOriented(
            page: page, displayWidth: displayWidth,
            displayHeight: displayHeight, dpi: dpi
        ) else { return nil }
        let nsImage = NSImage(
            cgImage: img,
            size: NSSize(width: img.width, height: img.height)
        )
        return PDFPage(image: nsImage)
    }

    /// Render a PDF page to a CGImage in its display orientation
    /// (rotation applied) at the given DPI.
    private static func renderDisplayOriented(
        page: PDFPage,
        displayWidth: CGFloat, displayHeight: CGFloat, dpi: CGFloat
    ) -> CGImage? {
        let scale = dpi / 72.0
        let w = max(1, Int((displayWidth * scale).rounded()))
        let h = max(1, Int((displayHeight * scale).rounded()))
        let nsImage = page.thumbnail(of: NSSize(width: w, height: h), for: .mediaBox)
        var rect = CGRect(x: 0, y: 0, width: w, height: h)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
