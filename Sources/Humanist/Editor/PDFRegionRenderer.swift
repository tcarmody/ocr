import Foundation
import CoreGraphics
import AppKit
import PDFKit

/// Render a sub-rectangle of a `PDFPage` as a CGImage at a target
/// DPI. Used by the "Re-OCR Selection" feature to crop the user's
/// PDF text selection (or any PDF region) into an image OCR engines
/// can consume.
///
/// PDFs are vector — there's no upper bound on render quality. We
/// default to ~300 DPI, which matches the OCR pipeline's high-quality
/// page renders and gives all three engines (Vision, Surya, Tesseract)
/// the same input fidelity they'd get from a full-page render.
enum PDFRegionRenderer {
    static let defaultDPI: CGFloat = 300

    /// Render `region` (in PDF page coordinates) of `page` to a CGImage.
    /// `region` is intersected with the page's media box so a stray
    /// out-of-bounds selection still produces something sensible.
    /// Returns nil if the rect is degenerate.
    static func render(
        page: PDFPage,
        region: CGRect,
        dpi: CGFloat = defaultDPI
    ) -> CGImage? {
        let pageBounds = page.bounds(for: .mediaBox)
        let clipped = region.intersection(pageBounds)
        guard clipped.width > 1, clipped.height > 1 else { return nil }

        // PDF is 1/72 inch per unit. dpi/72 = pixels per PDF unit.
        let scale = dpi / 72.0
        let pixelWidth = max(1, Int((clipped.width * scale).rounded()))
        let pixelHeight = max(1, Int((clipped.height * scale).rounded()))

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // White background — matches what OCR engines expect from
        // page renders. PDF pages are notionally on white paper.
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // Translate so the clipped region's bottom-left maps to (0,0)
        // in the bitmap, then scale to DPI. PDFKit draws in
        // bottom-left-origin coordinates that match CG.
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -clipped.minX, y: -clipped.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}
