import Foundation
import CoreGraphics
import PDFKit

/// Detects "two-up" scanned PDFs — books photocopied or flatbed-scanned
/// with two facing pages captured onto a single landscape PDF page. The
/// queue prompts the user to split these before OCR; otherwise Surya
/// reads the gutter as a column gap and reading order goes sideways.
///
/// Heuristic — a page is two-up when both signals fire:
///
///   1. **Aspect ratio.** width/height > `landscapeRatio` (1.3 by
///      default). Eliminates portrait scans immediately.
///   2. **Center gutter.** A vertical band at the page's horizontal
///      center has dramatically lower ink density than the flanking
///      regions. Filters out landscape documents that aren't book
///      scans (slides, posters, sheet music, infographics).
///
/// At the document level, we sample several pages and require a
/// majority to test positive — single misclassified pages don't drag
/// the verdict.
public enum TwoUpDetector {
    /// Aspect ratio above which we even consider checking for the
    /// gutter. Most book pages are roughly 0.65-0.8 (portrait); two
    /// portrait pages side-by-side land in the 1.3-1.6 range.
    public static let landscapeRatio: CGFloat = 1.3
    /// Center-zone ink density must be at most this fraction of the
    /// average flanking-zone density to count as a gutter.
    public static let centerGutterMaxRatio: Double = 0.30
    /// Flanking zones must have at least this much ink to be
    /// meaningful (otherwise the page is mostly blank and the ratio
    /// test would false-positive on noise).
    public static let minFlankingInkDensity: Double = 0.02

    /// Detect by sampling up to `sampleCount` pages from the document.
    /// Skips the very first page (often a single-image cover that
    /// fails the gutter check even when body pages are clearly
    /// two-up). Majority verdict wins.
    public static func detectIsTwoUp(
        pdfURL: URL, sampleCount: Int = 4
    ) -> Bool {
        guard let doc = PDFDocument(url: pdfURL), doc.pageCount > 0 else {
            return false
        }
        // Skip page 0 (cover); start at page 1 if available.
        let startPage = doc.pageCount > 1 ? 1 : 0
        var twoUpCount = 0
        var checked = 0
        for offset in 0..<sampleCount {
            let i = startPage + offset
            guard i < doc.pageCount, let page = doc.page(at: i) else { break }
            checked += 1
            if isTwoUpPage(page) { twoUpCount += 1 }
        }
        guard checked > 0 else { return false }
        return Double(twoUpCount) / Double(checked) >= 0.5
    }

    /// Per-page test. Used both for document-level sampling and by
    /// the splitter when deciding which individual pages to actually
    /// split (a few mixed-orientation pages in an otherwise two-up
    /// scan get passed through unchanged).
    public static func isTwoUpPage(_ page: PDFPage) -> Bool {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.height > 0 else { return false }
        guard bounds.width / bounds.height > landscapeRatio else { return false }
        guard let image = renderForAnalysis(page: page) else { return false }
        return hasCenterGutter(image: image)
    }

    /// Render the page at low DPI to grayscale for ink-density
    /// analysis. ~108 DPI is plenty — we just need a coarse view of
    /// where the dark pixels live.
    private static func renderForAnalysis(page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 1.5
        let w = max(1, Int(bounds.width * scale))
        let h = max(1, Int(bounds.height * scale))
        let cs = CGColorSpaceCreateDeviceGray()
        let bitmap = CGImageAlphaInfo.none.rawValue
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: cs, bitmapInfo: bitmap
        ) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Per-column ink fraction → does the center column have a
    /// sustained dip vs. the flanking columns?
    private static func hasCenterGutter(image: CGImage) -> Bool {
        guard image.width > 0, image.height > 0,
              let cfData = image.dataProvider?.data
        else { return false }
        let data = cfData as Data
        let w = image.width
        let h = image.height
        let bytesPerRow = image.bytesPerRow
        // Pixels darker than this count as ink. 200/255 catches body
        // text + line art without being fooled by aged-paper tan.
        let darkThreshold: UInt8 = 200

        var inkPerColumn = [Double](repeating: 0, count: w)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let buf = raw.bindMemory(to: UInt8.self)
            for y in 0..<h {
                let rowStart = y * bytesPerRow
                for x in 0..<w {
                    if buf[rowStart + x] < darkThreshold {
                        inkPerColumn[x] += 1
                    }
                }
            }
        }
        for x in 0..<w {
            inkPerColumn[x] /= Double(h)
        }

        func avg(_ frac0: Double, _ frac1: Double) -> Double {
            let lo = max(0, Int(frac0 * Double(w)))
            let hi = min(w, Int(frac1 * Double(w)))
            guard hi > lo else { return 0 }
            var s = 0.0
            for x in lo..<hi { s += inkPerColumn[x] }
            return s / Double(hi - lo)
        }

        // Left flank, center gutter, right flank.
        let leftAvg = avg(0.20, 0.40)
        let centerAvg = avg(0.45, 0.55)
        let rightAvg = avg(0.60, 0.80)

        guard leftAvg > minFlankingInkDensity,
              rightAvg > minFlankingInkDensity
        else { return false }
        let flankAvg = (leftAvg + rightAvg) / 2
        return centerAvg < centerGutterMaxRatio * flankAvg
    }
}
