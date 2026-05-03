import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Document
import PDFIngest
import OCR
import EPUB
import Layout

/// End-to-end orchestration: PDF on disk → EPUB on disk.
///
/// Two-pass design:
///   1. Render every page, OCR it, collect observations + geometry.
///   2. Run the reflow pipeline:
///        a. `HeaderFooterClassifier` learns running heads / footers /
///           page numbers across pages and marks them for removal.
///        b. `ParagraphReflow` groups remaining observations into
///           paragraphs per page using bounding-box geometry.
///        c. Cross-page bridge merges paragraphs split mid-word at page
///           boundaries (soft hyphens spanning pages).
///
/// Tesseract routing, layout-aware blocking, footnote linking, and
/// page-level parallelism arrive in later phases. The shape of this
/// type stays the same.
public actor PDFToEPUBPipeline {
    public struct Options: Sendable {
        public var dpi: CGFloat
        public var languages: [BCP47]
        public var ocrQuality: OCRHints.Quality
        /// When true, write a per-observation debug log alongside the
        /// output EPUB (`output.epub.log.txt`). Useful when text appears
        /// to vanish or end up in the wrong paragraph.
        public var emitDebugLog: Bool
        /// Force Surya as the OCR engine for every page that goes
        /// through the reocr branch. Slower (~10–20 s/page on Apple
        /// Silicon vs Vision's ~1 s) but recovers lines that Vision
        /// silently drops on certain page typography.
        public var useHighAccuracyOCR: Bool

        public init(
            dpi: CGFloat = 400,
            languages: [BCP47] = [.en],
            ocrQuality: OCRHints.Quality = .accurate,
            emitDebugLog: Bool = true,
            useHighAccuracyOCR: Bool = false
        ) {
            self.dpi = dpi
            self.languages = languages
            self.ocrQuality = ocrQuality
            self.emitDebugLog = emitDebugLog
            self.useHighAccuracyOCR = useHighAccuracyOCR
        }
    }

    public struct Progress: Sendable {
        public var totalPages: Int
        public var completedPages: Int
        public var currentPageMeanConfidence: Double  // NaN if no observations
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void

    private let loader = PDFLoader()
    private let visionEngine: any OCREngine
    private let tesseractEngine: (any OCREngine)?
    private let suryaEngine: (any OCREngine)?
    private let layoutAnalyzer: SuryaLayoutAnalyzer?
    private let embeddedExtractor = EmbeddedTextExtractor()
    private let gapFiller = EmbeddedTextGapFiller()
    private let qualityScorer = EmbeddedTextQualityScorer()

    public init(
        visionEngine: any OCREngine = VisionOCREngine(),
        tesseractEngine: (any OCREngine)? = TesseractOCREngine.detect(),
        suryaConnection: SuryaConnection? = SuryaConnection.detect()
    ) {
        self.visionEngine = visionEngine
        self.tesseractEngine = tesseractEngine
        // Surya layout + OCR share one Python process. Constructing
        // both wrappers from the same connection means the sidecar
        // loads weights once even when both modes are exercised.
        if let suryaConnection {
            self.suryaEngine = SuryaOCREngine(connection: suryaConnection)
            self.layoutAnalyzer = SuryaLayoutAnalyzer(connection: suryaConnection)
        } else {
            self.suryaEngine = nil
            self.layoutAnalyzer = nil
        }
    }

    /// Route an OCR call to the right engine.
    ///
    ///   * `preferSurya` (high-accuracy mode): Surya wins if available.
    ///     Fall back through Tesseract → Vision when not.
    ///   * Otherwise: Tesseract for ancient/non-Latin scripts, Vision
    ///     for everything else.
    ///
    /// Missing engines degrade gracefully (logged, not raised).
    private func selectEngine(for languages: [BCP47], preferSurya: Bool) -> any OCREngine {
        if preferSurya, let suryaEngine { return suryaEngine }
        if let tesseractEngine, Self.shouldPreferTesseract(for: languages) {
            return tesseractEngine
        }
        return visionEngine
    }

    /// Languages where Tesseract beats Vision in the cases the plan
    /// enumerates: ancient scripts (Greek, Latin) and non-Latin scripts
    /// (Hebrew, Syriac, Coptic, Arabic, CJK, Cyrillic).
    public static func shouldPreferTesseract(for languages: [BCP47]) -> Bool {
        let tesseractStrong: Set<String> = [
            "grc", "la",                               // ancient
            "he", "ar",                                // RTL
            "syr", "cop", "san", "chu",                // other ancient/liturgical
            "zh", "ja", "ko",                          // CJK
            "ru", "uk",                                // Cyrillic
        ]
        for lang in languages {
            let primary = lang.rawValue.split(separator: "-", maxSplits: 1).first.map(String.init)
                ?? lang.rawValue
            if tesseractStrong.contains(primary) { return true }
        }
        return false
    }

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

        // Pass 1 — for each page:
        //   a. Extract the embedded text layer (cheap; PDFKit access).
        //   b. Score its quality.
        //   c. Branch:
        //        - .trust  → skip Vision entirely; emit observations
        //                    synthesized from embedded lines.
        //        - .reocr → render + Vision OCR, then gap-fill any lines
        //                    Vision missed using whatever embedded text
        //                    exists.
        var pageResults: [PageObservations] = []
        pageResults.reserveCapacity(pdf.pageCount)
        var extractorDiagnostics: [Int: EmbeddedTextExtractor.Diagnostics] = [:]
        var qualityScores: [Int: EmbeddedTextQualityScorer.Score] = [:]
        // Page index → sidecar/Surya error message when layout failed.
        // Surfaced in the debug log so silent layout failures aren't
        // invisible (they explain why a page reverts to heuristic reflow).
        var layoutErrors: [Int: String] = [:]

        for i in 0..<pdf.pageCount {
            try Task.checkCancellation()

            let extracted = embeddedExtractor.extract(from: pdf, pageIndex: i)
            extractorDiagnostics[i] = extracted.diagnostics
            let combinedText = extracted.lines.map(\.text).joined(separator: " ")
            let quality = qualityScorer.score(text: combinedText)
            qualityScores[i] = quality

            var observations: [TextObservation]
            let pageBounds: CGSize
            let confidenceForProgress: Double
            var layoutForPage: [LayoutRegion]? = nil

            switch quality.verdict {
            case .trust:
                // Embedded text is good — skip Vision OCR entirely.
                observations = extracted.lines.map { line in
                    TextObservation(
                        text: line.text,
                        confidence: 0.95,
                        box: line.box,
                        source: .embedded
                    )
                }
                if let pdfPage = pdf.document.page(at: i) {
                    let r = pdfPage.bounds(for: .mediaBox)
                    pageBounds = CGSize(width: r.width, height: r.height)
                } else {
                    pageBounds = .zero
                }
                confidenceForProgress = 1.0

            case .reocr:
                // Render, OCR, gap-fill from embedded.
                let image = try renderer.renderPage(at: i, of: pdf)
                let pngURL = outputURL.appendingPathExtension("page-\(i).png")
                // We need a stable image-on-disk for layout analysis;
                // also serves as the debug PNG when logging is on.
                Self.savePNG(image, to: pngURL)
                let pageEngine = selectEngine(
                    for: hints.languages,
                    preferSurya: options.useHighAccuracyOCR
                )
                let result = try await pageEngine.recognize(image: image, hints: hints)
                observations = gapFiller.fill(
                    visionObservations: result.observations,
                    embeddedLines: extracted.lines
                )
                pageBounds = CGSize(width: image.width, height: image.height)
                confidenceForProgress = result.meanConfidence

                // Phase 4: layout analysis. Optional — if Surya isn't
                // installed or fails, we fall back to the heuristic
                // reflow path as before.
                if let analyzer = layoutAnalyzer {
                    do {
                        layoutForPage = try await analyzer.analyze(
                            imageURL: pngURL, pageBounds: pageBounds
                        )
                    } catch {
                        // Pipeline keeps going on the heuristic path,
                        // but surface the specific failure in the
                        // debug log so silent missing-region pages
                        // aren't a mystery.
                        layoutForPage = nil
                        layoutErrors[i] = String(describing: error)
                    }
                }

                // Phase 4.5: per-region cascade. Vision → Surya
                // (whole-page re-OCR, region-by-region replacement) →
                // Tesseract (per-region crop). Skipped when the user
                // already forced Surya for the whole page (no point
                // re-OCRing what's already Surya output) or when
                // there's no layout to localize problems.
                if !options.useHighAccuracyOCR,
                   let regions = layoutForPage, !regions.isEmpty {
                    observations = await RegionCascade.run(
                        observations: observations,
                        regions: regions,
                        pageImage: image,
                        hints: hints,
                        suryaEngine: suryaEngine,
                        tesseractEngine: tesseractEngine
                    )
                }

                if !options.emitDebugLog {
                    try? FileManager.default.removeItem(at: pngURL)
                }
            }

            pageResults.append(PageObservations(
                pageIndex: i,
                pageBounds: pageBounds,
                observations: observations,
                layoutRegions: layoutForPage
            ))
            progress?(Progress(
                totalPages: pdf.pageCount,
                completedPages: i + 1,
                currentPageMeanConfidence: confidenceForProgress
            ))
        }

        // Pass 2 — reflow (and optionally a debug log of every observation's fate).
        let blocks: [Block]
        if options.emitDebugLog {
            let logURL = outputURL.appendingPathExtension("log.txt")
            blocks = Self.reflow(
                pageResults: pageResults,
                debugLogURL: logURL,
                extractorDiagnostics: extractorDiagnostics,
                qualityScores: qualityScores,
                layoutErrors: layoutErrors
            )
        } else {
            blocks = Self.reflow(pageResults: pageResults)
        }

        let book = Book(
            title: title,
            language: language,
            chapters: [Chapter(title: title, blocks: blocks)]
        )

        try EPUBBuilder().write(book: book, to: outputURL)
    }

    /// Convert per-page observations into a clean block stream.
    ///
    /// If any page has Surya layout regions, the region-aware reflow
    /// path runs (per-region body text, drops H/F/footnote regions
    /// structurally, uses Surya's reading order across columns).
    /// Pages without regions fall back through the heuristic
    /// HeaderFooterClassifier + ParagraphReflow path.
    ///
    /// Visible for testing.
    static func reflow(
        pageResults: [PageObservations],
        debugLogURL: URL? = nil,
        extractorDiagnostics: [Int: EmbeddedTextExtractor.Diagnostics] = [:],
        qualityScores: [Int: EmbeddedTextQualityScorer.Score] = [:],
        layoutErrors: [Int: String] = [:]
    ) -> [Block] {
        let hasAnyLayout = pageResults.contains { ($0.layoutRegions?.isEmpty == false) }

        let merged: [Block]
        let classification: HeaderFooterClassifier.Result

        if hasAnyLayout {
            // Layout path. We still run the H/F classifier so the debug
            // log can show what *would* have been dropped, but the
            // region-aware reflow makes its own structural decisions.
            classification = HeaderFooterClassifier().classifyWithReasons(pageResults)
            merged = RegionAwareReflow.reflow(pageResults: pageResults)
        } else {
            // Heuristic-only path (Phase 1.5 behavior).
            classification = HeaderFooterClassifier().classifyWithReasons(pageResults)
            let drop = classification.dropSet
            let reflower = ParagraphReflow()

            var blocks: [Block] = []
            for page in pageResults {
                let kept = page.observations.enumerated().compactMap { (idx, obs) -> TextObservation? in
                    let key = ObservationKey(pageIndex: page.pageIndex, observationIndex: idx)
                    return drop.contains(key) ? nil : obs
                }
                blocks.append(contentsOf: reflower.reflow(kept))
            }
            merged = Self.bridgeBoundaries(blocks)
        }

        if let debugLogURL {
            try? writeDebugLog(
                pages: pageResults,
                classification: classification,
                blocks: merged,
                extractorDiagnostics: extractorDiagnostics,
                qualityScores: qualityScores,
                layoutErrors: layoutErrors,
                to: debugLogURL
            )
        }
        return merged
    }

    /// Save a CGImage as PNG to the given URL. Used by the debug-log
    /// path so we can visually inspect what Vision was actually fed.
    /// Silently no-ops on failure — debug aid, not load-bearing.
    private static func savePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
    }

    private static func writeDebugLog(
        pages: [PageObservations],
        classification: HeaderFooterClassifier.Result,
        blocks: [Block],
        extractorDiagnostics: [Int: EmbeddedTextExtractor.Diagnostics],
        qualityScores: [Int: EmbeddedTextQualityScorer.Score],
        layoutErrors: [Int: String],
        to url: URL
    ) throws {
        var out = ""
        out += "Humanist debug log\n"
        out += "==================\n"
        out += "pages: \(pages.count)\n"
        out += "blocks emitted: \(blocks.count)\n"
        out += "observations dropped: \(classification.dropSet.count)\n\n"

        if !qualityScores.isEmpty {
            out += "EMBEDDED TEXT QUALITY (per page)\n"
            out += "format: page: verdict combined=N.NN  mojibake=N.NN  singleChar=N.NN  langConf=N.NN  lang=XX  chars=N words=N\n\n"
            for pageIdx in qualityScores.keys.sorted() {
                guard let q = qualityScores[pageIdx] else { continue }
                out += String(
                    format: "Page %d: %-5@ combined=%.2f  mojibake=%.2f  singleChar=%.2f  langConf=%.2f  lang=%@  chars=%d words=%d\n",
                    pageIdx, q.verdict.rawValue,
                    q.combined, q.mojibakeRatio, q.singleCharWordRatio, q.languageConfidence,
                    q.dominantLanguage ?? "—", q.totalCharCount, q.totalWordCount
                )
            }
            out += "\n"
        }

        if !extractorDiagnostics.isEmpty {
            out += "EMBEDDED TEXT EXTRACTOR DIAGNOSTICS\n"
            out += "format: page: pageStringChars=N selectionsByLine=N kept=N (fallback used? kept=N)\n\n"
            for pageIdx in extractorDiagnostics.keys.sorted() {
                guard let d = extractorDiagnostics[pageIdx] else { continue }
                let fallback = d.characterFallbackUsed
                    ? " | char-fallback used, kept=\(d.characterFallbackKept)"
                    : ""
                out += "Page \(pageIdx): pageStringChars=\(d.pageStringCharCount) " +
                    "selectionsByLine=\(d.selectionByLineCount) kept=\(d.selectionByLineKept)\(fallback)\n"
            }
            out += "\n"
        }

        if !layoutErrors.isEmpty {
            out += "LAYOUT ANALYZER ERRORS\n"
            out += "format: page: error message (Surya/sidecar failure → page fell back to heuristic reflow)\n\n"
            for pageIdx in layoutErrors.keys.sorted() {
                let msg = layoutErrors[pageIdx] ?? ""
                out += "Page \(pageIdx): \(msg)\n"
            }
            out += "\n"
        }

        // Surya layout regions per page — when Phase 4 is active.
        let pagesWithLayout = pages.filter { ($0.layoutRegions?.isEmpty == false) }
        if !pagesWithLayout.isEmpty {
            out += "LAYOUT REGIONS (Surya, per page in reading order)\n"
            out += "format: page/idx pos=N kind=K box=[x, y, w, h] conf=N.NN\n\n"
            for page in pages {
                guard let regions = page.layoutRegions, !regions.isEmpty else { continue }
                out += "--- Page \(page.pageIndex) — \(regions.count) regions\n"
                let sorted = regions.sorted { a, b in
                    switch (a.readingOrder, b.readingOrder) {
                    case let (x, y) where x >= 0 && y >= 0: return x < y
                    case (let x, _) where x >= 0:           return true
                    case (_, let y) where y >= 0:           return false
                    default:                                 return false
                    }
                }
                for (idx, r) in sorted.enumerated() {
                    let b = r.box
                    out += String(
                        format: "%d/%-3d pos=%-3d kind=%-14@ box=[%.3f, %.3f, %.3f, %.3f] conf=%.2f\n",
                        page.pageIndex, idx, r.readingOrder, r.kind.rawValue,
                        b.minX, b.minY, b.width, b.height, r.confidence
                    )
                }
                out += "\n"
            }
        }

        out += "OBSERVATIONS (per page)\n"
        out += "format: [FATE] page/idx src (x, y, w, h) conf=N.NN region=POS:KIND | text\n"
        out += "  src = v (Vision), t (Tesseract), s (Surya), e (embedded PDF text layer)\n"
        out += "  region = which Surya region the observation was attributed to (RegionAwareReflow only)\n\n"
        for page in pages {
            let visionCount    = page.observations.filter { $0.source == .vision }.count
            let tesseractCount = page.observations.filter { $0.source == .tesseract }.count
            let suryaCount     = page.observations.filter { $0.source == .surya }.count
            let embeddedCount  = page.observations.filter { $0.source == .embedded }.count
            out += "--- Page \(page.pageIndex) — \(page.observations.count) observations " +
                "(\(visionCount) Vision, \(tesseractCount) Tesseract, " +
                "\(suryaCount) Surya, \(embeddedCount) embedded)\n"
            for (i, obs) in page.observations.enumerated() {
                let key = ObservationKey(pageIndex: page.pageIndex, observationIndex: i)
                let fate: String
                if let reason = classification.reasons[key] {
                    fate = "DROP \(reason.rawValue)"
                } else if classification.dropSet.contains(key) {
                    fate = "DROP unknown"
                } else {
                    fate = "KEEP"
                }
                let b = obs.box
                let src: String
                switch obs.source {
                case .vision:    src = "v"
                case .tesseract: src = "t"
                case .surya:     src = "s"
                case .embedded:  src = "e"
                }
                let regionInfo: String
                if let attr = RegionAwareReflow.lastAttributions[key] {
                    regionInfo = " region=\(attr.regionReadingOrder):\(attr.regionKind)"
                } else if pages.contains(where: { ($0.layoutRegions?.isEmpty == false) }) {
                    regionInfo = " region=UNASSIGNED"
                } else {
                    regionInfo = ""
                }
                out += String(
                    format: "[%@] %d/%-3d %@ (%.3f, %.3f, %.3f, %.3f) conf=%.2f%@ | %@\n",
                    fate, page.pageIndex, i, src,
                    b.minX, b.minY, b.width, b.height,
                    obs.confidence,
                    regionInfo,
                    obs.text.replacingOccurrences(of: "\n", with: " ⏎ ")
                )
            }
            out += "\n"
        }

        out += "BLOCKS (post-reflow + bridging)\n\n"
        for (i, block) in blocks.enumerated() {
            switch block {
            case .heading(let level, let runs):
                out += "[\(i)] H\(level): \(runs.map(\.text).joined())\n"
            case .paragraph(let runs):
                out += "[\(i)] P: \(runs.map(\.text).joined())\n"
            }
            out += "\n"
        }

        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Merge adjacent paragraphs that should not have been split. Two
    /// cases handled:
    ///
    ///   1. **Soft hyphen across boundaries** — first paragraph ends in
    ///      `letter-`, second starts with a lowercase letter
    ///      → join with the hyphen dropped (the "Mendelssohn" case).
    ///   2. **Mid-sentence break across boundaries** — first paragraph
    ///      doesn't end with a sentence terminator AND the second starts
    ///      with a lowercase letter → join with a space.
    ///
    /// Both fire across column transitions within a page and across page
    /// transitions. They're geometric blind spots — the per-column reflow
    /// can't see that the next column's first paragraph is actually a
    /// continuation of the previous column's last paragraph.
    ///
    /// Length guard on case 2 prevents accidentally swallowing short
    /// headings or labels into the previous paragraph.
    static func bridgeBoundaries(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        out.reserveCapacity(blocks.count)
        for block in blocks {
            guard case let .paragraph(runs) = block,
                  case let .paragraph(prevRuns) = out.last,
                  let lastPrevText = prevRuns.last?.text,
                  let firstNewText = runs.first?.text,
                  let bridgeKind = bridgeKind(prev: prevRuns, prevTail: lastPrevText, nextHead: firstNewText)
            else {
                out.append(block)
                continue
            }

            let mergedTail: String
            switch bridgeKind {
            case .softHyphen:
                mergedTail = Dehyphenation.join(lastPrevText, firstNewText)
            case .midSentence:
                mergedTail = lastPrevText.trimmingCharacters(in: .whitespaces)
                    + " " + firstNewText.trimmingCharacters(in: .whitespaces)
            }

            var combinedRuns = prevRuns
            combinedRuns[combinedRuns.count - 1] = InlineRun(
                mergedTail, language: combinedRuns.last?.language
            )
            combinedRuns.append(contentsOf: runs.dropFirst())

            out.removeLast()
            out.append(.paragraph(runs: combinedRuns))
        }
        return out
    }

    private enum BridgeKind { case softHyphen, midSentence }

    private static func bridgeKind(
        prev: [InlineRun], prevTail: String, nextHead: String
    ) -> BridgeKind? {
        if Dehyphenation.shouldDehyphenate(lhs: prevTail, rhs: nextHead) {
            return .softHyphen
        }
        // Mid-sentence join: prev didn't end with a terminator, next
        // begins with a lowercase letter, prev paragraph is long enough
        // to plausibly be prose (not a heading or short label).
        let prevWhole = prev.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prevWhole.count >= 20 else { return nil }
        guard !endsWithSentenceTerminator(prevWhole) else { return nil }
        let nextHeadTrimmed = nextHead.trimmingCharacters(in: .whitespaces)
        guard let firstChar = nextHeadTrimmed.first,
              firstChar.isLetter, firstChar.isLowercase
        else { return nil }
        return .midSentence
    }

    /// Treat `.`, `?`, `!`, `…`, `;`, `:` (optionally followed by closing
    /// quotes/brackets) as sentence-ish terminators.
    private static func endsWithSentenceTerminator(_ s: String) -> Bool {
        var t = Substring(s)
        while let last = t.last, "\")]}”’»".contains(last) {
            t = t.dropLast()
        }
        guard let last = t.last else { return false }
        return ".?!;:\u{2026}".contains(last)
    }
}
