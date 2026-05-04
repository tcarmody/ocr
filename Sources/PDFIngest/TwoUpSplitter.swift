import Foundation
import AppKit
import CoreGraphics
import PDFKit

/// Splits a "two-up" PDF (two book pages per landscape PDF page)
/// into a new PDF with one book page per portrait page. Per-page
/// detection: pages flagged by `TwoUpDetector.isTwoUpPage` get
/// halved; everything else is passed through unchanged. Output is
/// rasterized at the chosen DPI — vector content from the source
/// is lost, but for scanned books the source is already raster-only,
/// and the OCR pipeline re-renders pages anyway.
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
    /// Returns the count of (output pages, source pages that were
    /// split). A source page that didn't split is counted as one
    /// output page; one that did contributes two.
    @discardableResult
    public static func split(
        pdfURL: URL,
        outputURL: URL,
        dpi: CGFloat = 300
    ) throws -> (outputPages: Int, splitSources: Int) {
        guard let source = PDFDocument(url: pdfURL) else {
            throw SplitError.sourceLoadFailed
        }
        let output = PDFDocument()
        var outIdx = 0
        var splitSources = 0

        for i in 0..<source.pageCount {
            guard let page = source.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            if TwoUpDetector.isTwoUpPage(page) {
                splitSources += 1
                let halfWidth = bounds.width / 2
                let leftBox = CGRect(
                    x: bounds.minX, y: bounds.minY,
                    width: halfWidth, height: bounds.height
                )
                let rightBox = CGRect(
                    x: bounds.minX + halfWidth, y: bounds.minY,
                    width: halfWidth, height: bounds.height
                )
                if let leftPage = makePage(of: page, region: leftBox, dpi: dpi) {
                    output.insert(leftPage, at: outIdx); outIdx += 1
                }
                if let rightPage = makePage(of: page, region: rightBox, dpi: dpi) {
                    output.insert(rightPage, at: outIdx); outIdx += 1
                }
            } else {
                if let copy = makePage(of: page, region: bounds, dpi: dpi) {
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

    /// Render `region` of `page` (in PDF point coordinates) at the
    /// given DPI and wrap the result in a fresh `PDFPage` ready to
    /// drop into the output document.
    private static func makePage(
        of page: PDFPage, region: CGRect, dpi: CGFloat
    ) -> PDFPage? {
        let scale = dpi / 72.0
        let pixelWidth = max(1, Int((region.width * scale).rounded()))
        let pixelHeight = max(1, Int((region.height * scale).rounded()))
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: bitmap
        ) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        page.draw(with: .mediaBox, to: ctx)
        guard let cgImage = ctx.makeImage() else { return nil }
        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        return PDFPage(image: nsImage)
    }
}
