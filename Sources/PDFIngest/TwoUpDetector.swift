import Foundation
import AppKit
import CoreGraphics
import PDFKit

/// Detects "two-up" scanned PDFs — books photocopied or flatbed-scanned
/// with two facing pages captured onto a single landscape PDF page. The
/// queue prompts the user to split these before OCR; otherwise Surya
/// reads the gutter as a column gap and reading order goes sideways.
///
/// Heuristic — a page is two-up when both signals fire:
///
///   1. **Aspect ratio.** displayed-width / displayed-height >
///      `landscapeRatio` (1.2). "Displayed" accounts for the page's
///      `/Rotate` entry — scans saved as portrait + rotated 90° still
///      get evaluated against their visible orientation.
///   2. **Center gutter.** A vertical band at the page's horizontal
///      center has substantially lower ink density than the flanking
///      regions. Filters out landscape documents that aren't book
///      scans (slides, posters, sheet music, infographics).
///
/// At the document level, we sample several pages and require a
/// majority to test positive — single misclassified pages don't drag
/// the verdict.
public enum TwoUpDetector {
    /// Aspect ratio above which we even consider checking for the
    /// gutter. Two portrait pages side-by-side land in the 1.3-1.6
    /// range, but tall books photographed two-up can dip to ~1.2,
    /// so we err on the permissive side here — the gutter check is
    /// the load-bearing signal.
    public static let landscapeRatio: CGFloat = 1.2
    /// Center-zone ink density must be at most this fraction of the
    /// average flanking-zone density to count as a gutter. Loosened
    /// from the original 0.30 — real book scans often have page
    /// numbers / running heads crossing the center, so a perfectly
    /// blank gutter is rare.
    public static let centerGutterMaxRatio: Double = 0.45
    /// Flanking zones must have at least this much ink to be
    /// meaningful (otherwise the page is mostly blank and the ratio
    /// test would false-positive on noise).
    public static let minFlankingInkDensity: Double = 0.02

    /// Per-page diagnostic captured during a detection run. Surfaces
    /// in the debug log / Console output so we can see why a page
    /// was (or wasn't) flagged. `verdict == true` only if all gates
    /// pass.
    public struct Diagnostic: Sendable, Equatable {
        public let pageIndex: Int
        public let aspect: CGFloat
        public let rotation: Int
        public let leftInk: Double
        public let centerInk: Double
        public let rightInk: Double
        public let verdict: Bool
        public let rejectedBy: String?

        public var summary: String {
            let v = verdict ? "TWO-UP" : "single"
            let r = rejectedBy.map { " (rejected: \($0))" } ?? ""
            return String(
                format: "page %d rot=%d aspect=%.2f L=%.3f C=%.3f R=%.3f → %@%@",
                pageIndex, rotation, Double(aspect),
                leftInk, centerInk, rightInk,
                v, r
            )
        }
    }

    /// Most-recent per-page diagnostics from `detectIsTwoUp`. Emptied
    /// at the start of each call. Read after the call to log or
    /// inspect what fired.
    public private(set) static var lastDiagnostics: [Diagnostic] = []

    /// Detect by sampling up to `sampleCount` pages from the document.
    /// Skips the very first page (often a single-image cover that
    /// fails the gutter check even when body pages are clearly
    /// two-up). Majority verdict wins.
    public static func detectIsTwoUp(
        pdfURL: URL, sampleCount: Int = 4
    ) -> Bool {
        lastDiagnostics = []
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
            let diag = analyzePage(page, pageIndex: i)
            lastDiagnostics.append(diag)
            if diag.verdict { twoUpCount += 1 }
        }
        guard checked > 0 else { return false }
        return Double(twoUpCount) / Double(checked) >= 0.5
    }

    /// Per-page test. Used both for document-level sampling and by
    /// the splitter when deciding which individual pages to actually
    /// split (a few mixed-orientation pages in an otherwise two-up
    /// scan get passed through unchanged).
    public static func isTwoUpPage(_ page: PDFPage) -> Bool {
        analyzePage(page, pageIndex: -1).verdict
    }

    /// Full per-page analysis returning a `Diagnostic` so callers can
    /// log the signals. Public so the splitter and manual command
    /// can both see what fired.
    public static func analyzePage(_ page: PDFPage, pageIndex: Int) -> Diagnostic {
        let (displayW, displayH) = displayDimensions(page)
        let aspect = displayH > 0 ? displayW / displayH : 0

        guard aspect > landscapeRatio else {
            return Diagnostic(
                pageIndex: pageIndex, aspect: aspect, rotation: page.rotation,
                leftInk: 0, centerInk: 0, rightInk: 0,
                verdict: false, rejectedBy: "aspect"
            )
        }
        guard let image = renderForAnalysis(page: page,
                                            displayWidth: displayW,
                                            displayHeight: displayH)
        else {
            return Diagnostic(
                pageIndex: pageIndex, aspect: aspect, rotation: page.rotation,
                leftInk: 0, centerInk: 0, rightInk: 0,
                verdict: false, rejectedBy: "render-failed"
            )
        }
        let inks = computeColumnInks(image)
        let flankAvg = (inks.left + inks.right) / 2
        let lowFlanks = inks.left <= minFlankingInkDensity
            || inks.right <= minFlankingInkDensity
        let gutterClear = inks.center < centerGutterMaxRatio * flankAvg
        let rejected: String?
        let verdict: Bool
        if lowFlanks {
            rejected = "blank-flanks"; verdict = false
        } else if !gutterClear {
            rejected = "no-gutter"; verdict = false
        } else {
            rejected = nil; verdict = true
        }
        return Diagnostic(
            pageIndex: pageIndex, aspect: aspect, rotation: page.rotation,
            leftInk: inks.left, centerInk: inks.center, rightInk: inks.right,
            verdict: verdict, rejectedBy: rejected
        )
    }

    /// Page dimensions in display orientation. Honors `/Rotate` so a
    /// landscape scan saved with rotation=90 still reports as wide.
    static func displayDimensions(_ page: PDFPage) -> (width: CGFloat, height: CGFloat) {
        let raw = page.bounds(for: .mediaBox)
        let rot = page.rotation
        if rot == 90 || rot == 270 {
            return (raw.height, raw.width)
        }
        return (raw.width, raw.height)
    }

    /// Render the page in its display orientation at low DPI. Uses
    /// `PDFPage.thumbnail` because it's the only PDFKit entry point
    /// that automatically applies the page's rotation transform —
    /// `page.draw(with:to:)` does not.
    private static func renderForAnalysis(
        page: PDFPage,
        displayWidth: CGFloat,
        displayHeight: CGFloat
    ) -> CGImage? {
        // ~108 DPI is plenty for ink-density analysis.
        let scale: CGFloat = 1.5
        let w = max(1, Int((displayWidth * scale).rounded()))
        let h = max(1, Int((displayHeight * scale).rounded()))
        let nsImage = page.thumbnail(of: NSSize(width: w, height: h), for: .mediaBox)
        var rect = CGRect(x: 0, y: 0, width: w, height: h)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Per-column ink fraction → does the center column have a
    /// sustained dip vs. the flanking columns?
    private static func computeColumnInks(_ image: CGImage) -> (left: Double, center: Double, right: Double) {
        guard image.width > 0, image.height > 0,
              let cfData = image.dataProvider?.data
        else { return (0, 0, 0) }
        // Pixels darker than this count as ink. 200/255 catches body
        // text + line art without being fooled by aged-paper tan.
        let darkThreshold: UInt8 = 200
        let data = cfData as Data
        let w = image.width
        let h = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = (image.bitsPerPixel + 7) / 8

        var inkPerColumn = [Double](repeating: 0, count: w)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let buf = raw.bindMemory(to: UInt8.self)
            for y in 0..<h {
                let rowStart = y * bytesPerRow
                for x in 0..<w {
                    // For multi-channel images (RGB/RGBA), check the
                    // first byte (red for RGB, blue for BGRA — close
                    // enough for "is this pixel dark"). Pure grayscale
                    // (1 byte/pixel) just reads the byte directly.
                    if buf[rowStart + x * bytesPerPixel] < darkThreshold {
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

        // Left flank, center gutter (slightly wider band — 12% — so
        // a gutter that's not perfectly centered still gets caught),
        // right flank.
        return (
            left: avg(0.20, 0.40),
            center: avg(0.44, 0.56),
            right: avg(0.60, 0.80)
        )
    }
}
