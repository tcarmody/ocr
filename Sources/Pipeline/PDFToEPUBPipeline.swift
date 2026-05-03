import Foundation
import CoreGraphics
import Document
import PDFIngest
import OCR
import EPUB

/// End-to-end orchestration: PDF on disk → EPUB on disk.
///
/// Phase 1 walking-skeleton implementation:
///   * Render each page at a fixed DPI.
///   * Send the rendered page to a single OCR engine (Vision by default).
///   * Concatenate every observation into one `Chapter` of `Book`.
///   * Hand off to `EPUBBuilder`.
///
/// Layout-aware blocking, language routing, footnote detection, and
/// page-level parallelism arrive in later phases. The shape of this type
/// stays the same.
public actor PDFToEPUBPipeline {
    public struct Options: Sendable {
        public var dpi: CGFloat
        public var languages: [BCP47]
        public var ocrQuality: OCRHints.Quality

        public init(
            dpi: CGFloat = 300,
            languages: [BCP47] = [.en],
            ocrQuality: OCRHints.Quality = .accurate
        ) {
            self.dpi = dpi
            self.languages = languages
            self.ocrQuality = ocrQuality
        }
    }

    public struct Progress: Sendable {
        public var totalPages: Int
        public var completedPages: Int
        public var currentPageMeanConfidence: Double  // NaN if no observations
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void

    private let loader = PDFLoader()
    private let engine: any OCREngine

    public init(engine: any OCREngine = VisionOCREngine()) {
        self.engine = engine
    }

    /// Convert a single PDF to a single EPUB. Throws on any pipeline-stage
    /// failure; partial output is not preserved (EPUBBuilder writes
    /// atomically via ZIPFoundation's create-archive flow).
    public func convert(
        pdfURL: URL,
        outputURL: URL,
        options: Options = Options(),
        progress: ProgressHandler? = nil
    ) async throws {
        let pdf = try loader.load(pdfURL)
        let renderer = PDFRenderer(dpi: options.dpi)
        let hints = OCRHints(languages: options.languages, quality: options.ocrQuality)

        let title = pdf.title ?? pdfURL.deletingPathExtension().lastPathComponent
        let language = options.languages.first ?? .en

        var blocks: [Block] = []
        let total = pdf.pageCount

        for i in 0..<total {
            try Task.checkCancellation()

            let image = try renderer.renderPage(at: i, of: pdf)
            let result = try await engine.recognize(image: image, hints: hints)

            // Walking-skeleton conversion: one heading per page (so the
            // EPUB has *some* structure to navigate) followed by one
            // paragraph per Vision observation. Layout-aware blocking
            // arrives in Phase 4.
            blocks.append(.heading(level: 2, runs: [InlineRun("Page \(i + 1)")]))
            for obs in result.observations {
                let trimmed = obs.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    blocks.append(.paragraph(runs: [InlineRun(trimmed)]))
                }
            }

            progress?(Progress(
                totalPages: total,
                completedPages: i + 1,
                currentPageMeanConfidence: result.meanConfidence
            ))
        }

        let book = Book(
            title: title,
            language: language,
            chapters: [Chapter(title: title, blocks: blocks)]
        )

        try EPUBBuilder().write(book: book, to: outputURL)
    }
}
