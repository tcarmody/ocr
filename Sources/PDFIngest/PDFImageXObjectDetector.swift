import Foundation
import CoreGraphics
import PDFKit

/// Walks a PDF page's content stream to find image XObject placements.
/// Used as a born-digital figure detector — when a PDF carries
/// embedded image XObjects (the typical born-digital art book /
/// magazine / journal pattern), this gives us pixel-perfect placement
/// bboxes without any layout-model heuristics. Complements Surya:
/// when both report a figure at the same place we trust the XObject
/// bbox; when only Surya reports (rasterized scan), we use Surya's.
///
/// Returns nothing for fully-scanned PDFs (where the only XObject per
/// page is the page-sized scanned image — we explicitly filter those
/// out via the page-coverage threshold below). The pipeline then
/// falls through to Surya / Vision saliency.
///
/// Implementation: registers callbacks for the four operators that
/// matter for image placement — `q` (save graphics state), `Q`
/// (restore), `cm` (concatenate matrix), `Do` (invoke XObject) — and
/// walks the stream with `CGPDFScannerScan`. For each `Do`, looks up
/// the XObject in the page's Resources dictionary; if it's an Image
/// XObject, records the current transformation matrix applied to the
/// unit square as the placement bbox. Form XObjects (nested content
/// streams) are not recursed into — the surface-level pass catches
/// the common case (Image XObject placed directly on the page).
///
/// Coordinates are returned in **Vision's normalized convention**
/// (origin bottom-left, [0,1] on both axes), which matches the
/// `LayoutRegion.box` contract so callers can drop the result into
/// the existing figure-extraction path with no translation.
public struct PDFImageXObjectDetector: Sendable {

    public struct DetectedImage: Sendable, Equatable {
        public let pageIndex: Int
        /// Placement bbox in Vision-normalized coordinates
        /// (bottom-left origin, [0,1] on both axes).
        public let box: CGRect
    }

    public init() {}

    /// Coverage threshold above which we treat a detection as "the
    /// whole page is one image" — typical of scanned books. We drop
    /// those because they wouldn't add anything useful as a figure
    /// region (the cascade already handles whole-page rasters).
    public static let fullPageCoverageThreshold: CGFloat = 0.85

    /// Minimum coverage to count as a figure. Filters drop-cap
    /// images, decorative ornaments, and signature glyphs that
    /// some publishers embed at <2% of page area.
    public static let minCoverageThreshold: CGFloat = 0.01

    public func detect(in pdf: LoadedPDF, pageIndex: Int) -> [DetectedImage] {
        guard let page = pdf.document.page(at: pageIndex)?.pageRef else {
            return []
        }
        let pageBox = page.getBoxRect(.mediaBox)
        guard pageBox.width > 0, pageBox.height > 0 else { return [] }

        // Walker state lives inside this Swift class; we hand a
        // retained pointer to the scanner's `info` slot so the
        // C callbacks can recover it.
        let state = WalkerState(page: page, pageBox: pageBox)
        let info = Unmanaged.passRetained(state).toOpaque()
        defer { Unmanaged<WalkerState>.fromOpaque(info).release() }

        guard let table = CGPDFOperatorTableCreate() else { return [] }
        defer { CGPDFOperatorTableRelease(table) }

        CGPDFOperatorTableSetCallback(table, "q",  qCallback)
        CGPDFOperatorTableSetCallback(table, "Q",  QCallback)
        CGPDFOperatorTableSetCallback(table, "cm", cmCallback)
        CGPDFOperatorTableSetCallback(table, "Do", DoCallback)

        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)

        // Filter, deduplicate, and convert to Vision coords. PDF
        // user space has origin bottom-left already — that matches
        // Vision's convention — but the placement bbox is in
        // *page-user-space* units, not normalized. Divide by the
        // page box to get [0,1] coordinates.
        var out: [DetectedImage] = []
        for rect in state.imageBoxes {
            let normalized = CGRect(
                x: (rect.minX - pageBox.minX) / pageBox.width,
                y: (rect.minY - pageBox.minY) / pageBox.height,
                width: rect.width / pageBox.width,
                height: rect.height / pageBox.height
            )
            // Clamp to [0,1]; some PDFs place images that extend
            // beyond the media box (bleed) and we don't want
            // negative or >1 coords downstream.
            let clamped = CGRect(
                x: max(0, min(1, normalized.minX)),
                y: max(0, min(1, normalized.minY)),
                width: max(0, min(1, normalized.width)),
                height: max(0, min(1, normalized.height))
            )
            let coverage = clamped.width * clamped.height
            guard coverage >= Self.minCoverageThreshold,
                  coverage <= Self.fullPageCoverageThreshold else {
                continue
            }
            out.append(DetectedImage(pageIndex: pageIndex, box: clamped))
        }
        return out
    }
}

// MARK: - Walker internals

/// Mutable state threaded through the CGPDFScanner callbacks. Held
/// retained for the scan duration via `Unmanaged.passRetained`; the
/// C `info` pointer is its opaque handle.
private final class WalkerState {
    let page: CGPDFPage
    let pageBox: CGRect
    /// CTM stack. PDF spec: `q` pushes, `Q` pops, `cm` concatenates
    /// onto the top entry. Initial CTM is identity.
    var ctmStack: [CGAffineTransform] = [.identity]
    /// Accumulated image XObject placement bboxes (in page-user-space,
    /// pre-normalization). `detect()` converts to [0,1] coords on
    /// return.
    var imageBoxes: [CGRect] = []

    init(page: CGPDFPage, pageBox: CGRect) {
        self.page = page
        self.pageBox = pageBox
    }
}

private let qCallback: CGPDFOperatorCallback = { _, info in
    guard let info else { return }
    let state = Unmanaged<WalkerState>.fromOpaque(info).takeUnretainedValue()
    let top = state.ctmStack.last ?? .identity
    state.ctmStack.append(top)
}

private let QCallback: CGPDFOperatorCallback = { _, info in
    guard let info else { return }
    let state = Unmanaged<WalkerState>.fromOpaque(info).takeUnretainedValue()
    // Keep at least one entry so unbalanced Q operators (malformed
    // PDFs) don't underflow.
    if state.ctmStack.count > 1 {
        state.ctmStack.removeLast()
    }
}

private let cmCallback: CGPDFOperatorCallback = { scanner, info in
    guard let info else { return }
    let state = Unmanaged<WalkerState>.fromOpaque(info).takeUnretainedValue()
    // PDF spec: `cm` operands are 6 numbers (a b c d e f), pushed in
    // order. CGPDFScannerPopNumber pops them in reverse.
    var values: [CGFloat] = Array(repeating: 0, count: 6)
    for i in 0..<6 {
        var n: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &n) else { return }
        values[5 - i] = CGFloat(n)
    }
    let m = CGAffineTransform(
        a: values[0], b: values[1],
        c: values[2], d: values[3],
        tx: values[4], ty: values[5]
    )
    let top = state.ctmStack.removeLast()
    // PDF "concatenate" is left-multiplication: new CTM = m × top.
    state.ctmStack.append(m.concatenating(top))
}

private let DoCallback: CGPDFOperatorCallback = { scanner, info in
    guard let info else { return }
    let state = Unmanaged<WalkerState>.fromOpaque(info).takeUnretainedValue()

    // The operand is the XObject name (a /Name PDF object).
    var rawName: UnsafePointer<Int8>?
    guard CGPDFScannerPopName(scanner, &rawName), let rawName else { return }
    let xobjectName = String(cString: rawName)

    // Look up the page's Resources dictionary → XObject sub-dictionary
    // → the named XObject. PDFs can also inherit Resources from
    // ancestor page tree nodes; CGPDFPage already resolves this.
    guard let pageDict = state.page.dictionary else { return }
    var resourcesDict: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resourcesDict),
          let resourcesDict else { return }
    var xobjectsDict: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(resourcesDict, "XObject", &xobjectsDict),
          let xobjectsDict else { return }
    var xobjectStream: CGPDFStreamRef?
    guard CGPDFDictionaryGetStream(xobjectsDict, xobjectName, &xobjectStream),
          let xobjectStream else { return }
    let streamDict = CGPDFStreamGetDictionary(xobjectStream)
    guard let streamDict else { return }

    // Confirm Subtype = /Image. Form XObjects (Subtype = /Form) are
    // recursive content streams; we don't currently descend into
    // them, so we just skip.
    var subtypeRaw: UnsafePointer<Int8>?
    guard CGPDFDictionaryGetName(streamDict, "Subtype", &subtypeRaw),
          let subtypeRaw,
          String(cString: subtypeRaw) == "Image" else {
        return
    }

    // Image XObject placement: the unit square (0,0)-(1,1) in image
    // space, transformed by the current CTM, gives the rectangle on
    // the page where the image is drawn.
    let ctm = state.ctmStack.last ?? .identity
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    let placed = unit.applying(ctm)
    // `applying` returns the AABB of the four corners — exactly
    // what we want for a placement bbox even when the image is
    // rotated or sheared.
    state.imageBoxes.append(placed)
}
