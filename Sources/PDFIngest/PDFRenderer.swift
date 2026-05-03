import Foundation
import CoreGraphics
import PDFKit

/// Rasterizes PDF pages to CGImage at a chosen DPI.
///
/// The plan calls for adaptive DPI (300 for scanned, 220 for born-digital
/// with images, 150 for pure born-digital text), driven by an
/// embedded-text-quality score. That arrives in Phase 2; Phase 1 uses a
/// fixed DPI good enough for Vision OCR on typical book scans.
public struct PDFRenderer {
    public var dpi: CGFloat
    /// Standard PDF unit is 1/72".
    private let pdfUnitsPerInch: CGFloat = 72

    public init(dpi: CGFloat = 300) {
        self.dpi = dpi
    }

    public func renderPage(at index: Int, of pdf: LoadedPDF) throws -> CGImage {
        guard index >= 0, index < pdf.pageCount else {
            throw PDFIngestError.pageOutOfRange(index, count: pdf.pageCount)
        }
        guard let page = pdf.document.page(at: index) else {
            throw PDFIngestError.pageOutOfRange(index, count: pdf.pageCount)
        }
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / pdfUnitsPerInch
        let pixelWidth  = max(1, Int((bounds.width * scale).rounded()))
        let pixelHeight = max(1, Int((bounds.height * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw PDFIngestError.renderFailed(pageIndex: index)
        }

        // White background — important for scanned pages with transparent areas
        // and for Vision, which is calibrated against white-paper input.
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        ctx.scaleBy(x: scale, y: scale)
        // Translate so PDF origin (lower-left) lines up with our context.
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)

        page.draw(with: .mediaBox, to: ctx)

        guard let image = ctx.makeImage() else {
            throw PDFIngestError.renderFailed(pageIndex: index)
        }
        return image
    }
}
