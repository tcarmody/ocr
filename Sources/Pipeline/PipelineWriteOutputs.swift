import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Document
import EPUB
import PDFIngest

// MARK: - C-Pipeline-File-Split Stage 2 (output emission)
//
// Extracted from `PDFToEPUBPipeline.swift` 2026-05-18. Holds the
// final-stage output writers: the EPUB itself + sibling text /
// markdown / HTML / DOCX / searchable-PDF emission, plus the
// cover-from-page-0 raster helpers. Behavior-equivalent to the
// prior inline shape.
extension PDFToEPUBPipeline {

    /// Write the conversion's three on-disk artifacts: the EPUB
    /// (canonical output), the optional `.txt` / `.md` / `.html`
    /// siblings, and the optional searchable-PDF copy. The EPUB
    /// write is the only one that throws; sibling + searchable-PDF
    /// failures are swallowed (they're convenience outputs and the
    /// canonical EPUB is already on disk).
    static func writeOutputs(
        book: Book,
        correctionTrail: CorrectionTrail?,
        appliedTOC: ParsedTOC?,
        pageResults: [PageObservations],
        pdfURL: URL,
        outputURL: URL,
        options: Options,
        bilingualLayout: BilingualLayoutDetector.Layout? = nil
    ) throws {
        // Translate the layout's (pdfPage → partner pdfPage) map
        // into the (anchorId → partner anchorId) form the EPUB
        // writer needs. Keeps the EPUB module free of Pipeline
        // types so the dependency direction stays one-way.
        let facingPageMap: [String: String]
        if let layout = bilingualLayout {
            var m: [String: String] = [:]
            for (page, partner) in layout.pagePartners {
                let anchor = RegionAwareReflow.anchorId(forPageIndex: page)
                let partnerAnchor = RegionAwareReflow.anchorId(forPageIndex: partner)
                m[anchor] = partnerAnchor
            }
            facingPageMap = m
        } else {
            facingPageMap = [:]
        }
        try EPUBBuilder().write(
            book: book,
            correctionTrail: correctionTrail,
            parsedTOC: appliedTOC,
            sourcePDFURL: pdfURL,
            facingPageMap: facingPageMap,
            to: outputURL
        )

        // Tier 9 / V-Outputs: emit `.txt` + `.md` + `.html` siblings
        // next to the EPUB. Best-effort. Sibling URLs default to
        // next-to-EPUB; the configured-output-folder feature routes
        // them into per-format subfolders by setting the overrides.
        // mkdir -p the parents either way since the user could pick
        // a fresh root with no subfolders yet.
        if options.emitSiblingTextOutputs {
            let txtURL = options.siblingTextURLOverride
                ?? outputURL.deletingPathExtension().appendingPathExtension("txt")
            let mdURL = options.siblingMarkdownURLOverride
                ?? outputURL.deletingPathExtension().appendingPathExtension("md")
            for url in [txtURL, mdURL] {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
            }
            try? PlainTextWriter.render(book).write(
                to: txtURL, atomically: true, encoding: .utf8
            )
            try? MarkdownWriter.render(book).write(
                to: mdURL, atomically: true, encoding: .utf8
            )
        }
        if options.emitSiblingDocuments {
            let htmlURL = options.siblingHTMLURLOverride
                ?? outputURL.deletingPathExtension().appendingPathExtension("html")
            let docxURL = options.siblingDOCXURLOverride
                ?? outputURL.deletingPathExtension().appendingPathExtension("docx")
            for url in [htmlURL, docxURL] {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
            }
            try? HTMLWriter.render(book).write(
                to: htmlURL, atomically: true, encoding: .utf8
            )
            try? DOCXWriter.write(book, to: docxURL)
        }

        // Tier 9 / V-PDF-Searchable: write a searchable copy of the
        // source PDF using the OCR observations the pipeline already
        // computed. Failures are non-fatal.
        if options.emitSearchablePDF {
            let pdfURLOut = options.searchablePDFURLOverride
                ?? outputURL.deletingPathExtension()
                    .appendingPathExtension("searchable.pdf")
            let pages = pageResults.map {
                SearchablePDFWriter.PageData(
                    pageIndex: $0.pageIndex,
                    observations: $0.observations
                )
            }
            try? SearchablePDFWriter().write(
                sourcePDFURL: pdfURL,
                pages: pages,
                to: pdfURLOut
            )
        }
    }

    /// Rasterize PDF page 0 as a JPEG and wrap it in a
    /// FigureAsset stamped as the EPUB cover. The result lands
    /// in `book.chapters[0].figureAssets[0]` and the EPUB writer
    /// stamps `properties="cover-image"` on its manifest item.
    /// No `Block.figure` references the id, so the cover doesn't
    /// render inline — it surfaces only as the OPF cover-image.
    ///
    /// Renders at 150 dpi: on a typical 6×9" book page that's
    /// ~900×1350 px, under the EPUB 1600×2400 cover-size guidance
    /// while keeping per-book file size to ~100 KB. JPEG quality
    /// 0.85 — good enough for thumbnail / first-open use, far
    /// smaller than PNG for scanned/photographic content.
    ///
    /// Returns nil on any failure (load, encode); the EPUB writer
    /// proceeds without a cover, which is still valid.
    static func renderPDFPage0AsCover(
        pdf: LoadedPDF
    ) -> FigureAsset? {
        guard pdf.pageCount > 0 else { return nil }
        let renderer = PDFRenderer(dpi: 150)
        guard let image = try? renderer.renderPage(at: 0, of: pdf)
        else { return nil }
        guard let data = encodeCoverJPEG(image, quality: 0.85)
        else { return nil }
        return FigureAsset(
            id: "cover-page-0",
            data: data,
            mediaType: "image/jpeg",
            intrinsicSize: CGSize(
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            ),
            isCover: true
        )
    }

    /// JPEG-encode a CGImage with the given quality (0...1).
    /// Returns nil on encoder failure. Used by the cover-from-
    /// page-0 path; could be reused for other figure assets if
    /// the pipeline ever wants JPEG output for scanned figures.
    static func encodeCoverJPEG(
        _ image: CGImage, quality: CGFloat
    ) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1, nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}
