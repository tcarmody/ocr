import Foundation
import CoreGraphics
import CoreText
import AppKit
import OCR

/// Write a "searchable" copy of a source PDF: every page renders the
/// original page content unchanged, with an invisible text overlay
/// per OCR observation positioned over the box where that text was
/// recognized. The result behaves like the input visually but is
/// fully selectable, copy-able, and Cmd+F searchable in Preview /
/// Spotlight / any PDF viewer.
///
/// Tier 9 / V-PDF-Searchable. Sibling output of the standard
/// PDF→EPUB conversion — runs once OCR is complete, reusing the
/// same per-page observations the EPUB was built from.
public struct SearchablePDFWriter {
    public init() {}

    public enum Failure: Error, LocalizedError {
        case sourceUnreadable
        case destinationUnwritable

        public var errorDescription: String? {
            switch self {
            case .sourceUnreadable:    return "Couldn't read source PDF"
            case .destinationUnwritable: return "Couldn't write searchable PDF"
            }
        }
    }

    /// One page's worth of OCR data, indexed by source-PDF page
    /// number (0-based). `observations[i].box` is in Vision's
    /// normalized [0,1] coordinate system, origin lower-left of the
    /// page image — the same form `PageObservations.observations`
    /// uses throughout the pipeline.
    public struct PageData: Sendable {
        public let pageIndex: Int
        public let observations: [TextObservation]

        public init(pageIndex: Int, observations: [TextObservation]) {
            self.pageIndex = pageIndex
            self.observations = observations
        }
    }

    /// Write a searchable copy of `sourcePDFURL` to `outputURL`.
    /// `pages` may cover only a subset; pages without an entry get
    /// their original content with no overlay (still visible / still
    /// extractable to whatever degree the source PDF was).
    public func write(
        sourcePDFURL: URL,
        pages: [PageData],
        to outputURL: URL
    ) throws {
        guard let cgDoc = CGPDFDocument(sourcePDFURL as CFURL) else {
            throw Failure.sourceUnreadable
        }
        // Make sure the destination directory exists. Same posture as
        // the txt/md sibling write: the caller may have routed the
        // output into a configured root that doesn't have the Books
        // subdirectory yet.
        let parent = outputURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try? FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true
            )
        }

        guard let consumer = CGDataConsumer(url: outputURL as CFURL) else {
            throw Failure.destinationUnwritable
        }
        // mediaBox: nil means "use whatever the page declares" — each
        // beginPDFPage call below supplies the page's media box.
        guard let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw Failure.destinationUnwritable
        }

        let observationsByPage: [Int: [TextObservation]] = Dictionary(
            uniqueKeysWithValues: pages.map { ($0.pageIndex, $0.observations) }
        )

        for i in 0..<cgDoc.numberOfPages {
            // CGPDFDocument is 1-indexed.
            guard let cgPage = cgDoc.page(at: i + 1) else { continue }
            let mediaBox = cgPage.getBoxRect(.mediaBox)
            ctx.beginPDFPage(pageInfo(mediaBox: mediaBox))
            ctx.drawPDFPage(cgPage)
            if let obs = observationsByPage[i] {
                drawInvisibleOverlay(
                    observations: obs,
                    pageRect: mediaBox,
                    in: ctx
                )
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Pack a CGRect into the CFDictionary form CGContext.beginPDFPage
    /// expects for `kCGPDFContextMediaBox`. The key takes a CFData
    /// wrapping the raw bytes of a CGRect.
    private func pageInfo(mediaBox: CGRect) -> CFDictionary {
        var rect = mediaBox
        let data = withUnsafeBytes(of: &rect) { Data($0) } as CFData
        return [kCGPDFContextMediaBox as String: data] as CFDictionary
    }

    /// Draw one invisible text run per observation, positioned so
    /// the run's bounding box approximately matches the observation
    /// box. PDF readers care that the text is *somewhere on the
    /// page* — exact glyph placement is unnecessary for search and
    /// fine-grained-enough for selection.
    private func drawInvisibleOverlay(
        observations: [TextObservation],
        pageRect: CGRect,
        in ctx: CGContext
    ) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for obs in observations {
            let text = obs.text
            guard !text.isEmpty else { continue }
            // Map normalized [0,1] (origin bottom-left) into PDF
            // page-space. Vision's coordinate system already matches
            // PDF's (bottom-left origin, y-up), so this is a
            // straight scale.
            let r = CGRect(
                x: pageRect.origin.x + obs.box.minX * pageRect.width,
                y: pageRect.origin.y + obs.box.minY * pageRect.height,
                width:  obs.box.width  * pageRect.width,
                height: obs.box.height * pageRect.height
            )
            guard r.width > 0, r.height > 0 else { continue }
            // Pick a font size such that the line's natural width
            // approximately matches the box's width — uniform glyph
            // scaling, no `textMatrix` distortion. Distorted glyphs
            // confuse PDFKit's text-extraction heuristic into
            // inserting a space between every character.
            //
            // Probe at the box height first to read the typographic
            // width, then scale the font to fit horizontally. Cap on
            // both axes so unusually wide / narrow boxes don't blow
            // up the font.
            let probeSize = max(1, r.height)
            let probeFont = NSFont.systemFont(ofSize: probeSize)
            let probeAttr = NSAttributedString(
                string: text, attributes: [.font: probeFont]
            )
            let probeLine = CTLineCreateWithAttributedString(probeAttr)
            let probeWidth = CGFloat(
                CTLineGetTypographicBounds(probeLine, nil, nil, nil)
            )
            let widthFit = probeWidth > 0 ? probeSize * (r.width / probeWidth) : probeSize
            let fontSize = max(1, min(widthFit, r.height * 4))
            let font = NSFont.systemFont(ofSize: fontSize)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font])
            )
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: r.minX, y: r.minY)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }
}
