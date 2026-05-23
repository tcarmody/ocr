import Foundation
import Document
import Layout
import OCR
import PDFIngest

// MARK: - C-Pipeline-File-Split Stage 2 (reflow)
//
// Extracted from `PDFToEPUBPipeline.swift` 2026-05-18. Holds the
// `ReflowOutput` value type and the `reflow(...)` static helper
// that turns per-page observations into the body block stream
// (+ footnotes / page anchors / figure assets). The
// `writeDebugLog` helper it calls remains on `PDFToEPUBPipeline`
// directly so the debug-log internals don't fragment across two
// files; its access modifier widens from `private` to default
// internal so this sibling extension can reach it.
extension PDFToEPUBPipeline {

    public struct ReflowOutput: Sendable, Equatable {
        public let blocks: [Block]
        public let footnotes: [Footnote]
        public let pageAnchors: [PageAnchor]
        public let figureAssets: [FigureAsset]
        public init(
            blocks: [Block],
            footnotes: [Footnote],
            pageAnchors: [PageAnchor] = [],
            figureAssets: [FigureAsset] = []
        ) {
            self.blocks = blocks
            self.footnotes = footnotes
            self.pageAnchors = pageAnchors
            self.figureAssets = figureAssets
        }
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
        figureExtractions: [Int: [FigureExtractor.ExtractedFigure]] = [:],
        tableExtractions: [CaptionAssociator.PageRegionKey: [[TableCell]]] = [:],
        mathExtractions: [CaptionAssociator.PageRegionKey: String] = [:],
        captionAssociations: CaptionAssociator.Associations = CaptionAssociator.Associations(
            captionByFigure: [:], orientation: .below
        ),
        debugLogURL: URL? = nil,
        extractorDiagnostics: [Int: EmbeddedTextExtractor.Diagnostics] = [:],
        qualityScores: [Int: EmbeddedTextQualityScorer.Score] = [:],
        layoutErrors: [Int: String] = [:],
        ocrErrors: [Int: String] = [:]
    ) -> ReflowOutput {
        let hasAnyLayout = pageResults.contains { ($0.layoutRegions?.isEmpty == false) }

        let merged: [Block]
        let footnotes: [Footnote]
        let pageAnchors: [PageAnchor]
        let figureAssets: [FigureAsset]
        let classification: HeaderFooterClassifier.Result
        // Reflow diagnostics for the debug log. Empty (defaulted) on
        // the heuristic-only path, populated with per-page audit
        // trails on the layout path. Was previously read as a set of
        // static vars on RegionAwareReflow; now flows through the
        // Result struct.
        var reflowDiagnostics = RegionAwareReflow.Diagnostics()

        if hasAnyLayout {
            // Layout path. We still run the H/F classifier so the debug
            // log can show what *would* have been dropped, but the
            // region-aware reflow makes its own structural decisions.
            classification = HeaderFooterClassifier().classifyWithReasons(pageResults)
            let result = RegionAwareReflow.reflow(
                pageResults: pageResults,
                figureExtractions: figureExtractions,
                tableExtractions: tableExtractions,
                mathExtractions: mathExtractions,
                captionAssociations: captionAssociations
            )
            merged = result.blocks
            footnotes = result.footnotes
            pageAnchors = result.pageAnchors
            figureAssets = result.figureAssets
            reflowDiagnostics = result.diagnostics
        } else {
            // Heuristic-only path (Phase 1.5 behavior). No layout
            // regions means no footnote regions, so no popups either.
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
            footnotes = []
            pageAnchors = []
            figureAssets = []
        }

        if let debugLogURL {
            try? writeDebugLog(
                pages: pageResults,
                classification: classification,
                blocks: merged,
                extractorDiagnostics: extractorDiagnostics,
                qualityScores: qualityScores,
                layoutErrors: layoutErrors,
                ocrErrors: ocrErrors,
                footnotes: footnotes,
                reflowDiagnostics: reflowDiagnostics,
                to: debugLogURL
            )
        }
        return ReflowOutput(
            blocks: merged,
            footnotes: footnotes,
            pageAnchors: pageAnchors,
            figureAssets: figureAssets
        )
    }
}
