import Foundation
import CoreGraphics
import OCR
import Layout

/// Phase 4.5 — per-region OCR cascade.
///
/// After Vision + layout analysis, evaluate each text-bearing region.
/// For regions whose Vision observations look bad — low mean confidence
/// or a vertical gap that smells like missing lines — re-OCR with the
/// next engine in the cascade:
///
///   Vision → Surya (whole-page re-OCR, region-by-region replacement)
///         → Tesseract (per-region crop + re-OCR for any region still
///           problematic after Surya)
///
/// Surya re-OCR is once-per-page (we render the page anyway, and Surya
/// pages are easier to feed than crops), then we project Surya lines
/// into the problematic regions. Tesseract is per-region because it's
/// fast and crops are easy.
enum RegionCascade {

    /// Mean region confidence below this triggers re-OCR.
    static let meanConfidenceFloor: Double = 0.85
    /// Any single observation in a region with confidence below this
    /// triggers re-OCR. Catches the "Vision is confidently mostly-OK
    /// but one line is garbage" case the mean smooths over.
    static let minObservationConfidenceFloor: Double = 0.70
    /// Vertical gap between consecutive observations in a region, in
    /// units of median observation height, that triggers re-OCR. A
    /// well-set paragraph has ~zero within-region gap; gap > 1× line
    /// height ≈ at least one missing line.
    static let gapMultiplier: CGFloat = 1.0
    /// Combined OCR-text quality (single-char ratio · long-word ratio
    /// · language confidence) below this triggers re-OCR. Catches
    /// over-confident garbage that the confidence/gap floors miss —
    /// Vision sometimes returns 0.9+ on text that's run together or
    /// split apart. 0.5 is conservative; tighten if false positives
    /// show up on clean PDFs.
    static let textQualityFloor: Double = 0.5
    /// How much to inflate region bboxes when matching observations
    /// (matches the value RegionAwareReflow uses).
    static let regionInflation: CGFloat = 0.005
    /// Crop margin around a region for Tesseract re-OCR (normalized).
    static let cropMargin: CGFloat = 0.02

    static let textBearingKinds: Set<LayoutRegion.Kind> = [
        .text, .sectionHeader, .title, .listItem, .caption,
    ]

    /// Run the cascade on a single page. Returns the (possibly
    /// updated) observation list. Callers pass in the page's source
    /// CGImage so we can crop it for per-region Tesseract calls.
    static func run(
        observations: [TextObservation],
        regions: [LayoutRegion],
        pageImage: CGImage,
        hints: OCRHints,
        suryaEngine: (any OCREngine)?,
        tesseractEngine: (any OCREngine)?
    ) async -> [TextObservation] {
        // Pre-flight: which regions are problematic?
        var problemIndices = problematicRegionIndices(
            observations: observations, regions: regions
        )
        if problemIndices.isEmpty { return observations }

        var result = observations

        // --- Stage 1: Surya whole-page re-OCR ---
        if !problemIndices.isEmpty, let surya = suryaEngine {
            do {
                let suryaResult = try await surya.recognize(image: pageImage, hints: hints)
                for i in problemIndices {
                    result = replace(
                        observations: result,
                        inRegion: regions[i],
                        with: filter(
                            observations: suryaResult.observations,
                            inRegion: regions[i]
                        )
                    )
                }
                problemIndices = problematicRegionIndices(
                    observations: result, regions: regions, candidates: problemIndices
                )
            } catch {
                // Surya failed; carry on with Vision results.
            }
        }

        // --- Stage 2: per-region Tesseract crops ---
        if !problemIndices.isEmpty, let tess = tesseractEngine {
            for i in problemIndices {
                let region = regions[i]
                guard let cropped = cropImage(pageImage, to: region.box) else { continue }
                do {
                    let cropResult = try await tess.recognize(image: cropped, hints: hints)
                    let translated = translate(
                        observations: cropResult.observations,
                        fromCropOf: region.box,
                        intoFullPage: pageImage
                    )
                    // Confine to the region: crop margin pulls in glyphs
                    // from neighboring regions, and without filtering
                    // those observations land outside `region.box` and
                    // get attributed to the wrong region downstream.
                    let confined = filter(observations: translated, inRegion: region)
                    result = replace(
                        observations: result, inRegion: region, with: confined
                    )
                } catch {
                    // continue with whatever we have
                }
            }
        }

        return result
    }

    // MARK: - problem detection

    /// Return the indices of regions whose Vision observations look bad.
    /// `candidates` optionally restricts the search (used to re-evaluate
    /// after a stage of the cascade ran).
    static func problematicRegionIndices(
        observations: [TextObservation],
        regions: [LayoutRegion],
        candidates: Set<Int>? = nil
    ) -> Set<Int> {
        var out = Set<Int>()
        for (i, region) in regions.enumerated() {
            if let candidates, !candidates.contains(i) { continue }
            guard textBearingKinds.contains(region.kind) else { continue }
            let inRegion = filter(observations: observations, inRegion: region)
            // Empty region: not problematic — region just has no text
            // to worry about (could be a misclassified empty region).
            guard !inRegion.isEmpty else { continue }
            if isProblematic(observations: inRegion) {
                out.insert(i)
            }
        }
        return out
    }

    static func isProblematic(observations: [TextObservation]) -> Bool {
        guard !observations.isEmpty else { return false }

        // Aggregate confidence checks.
        let confs = observations.map(\.confidence)
        let meanConf = confs.reduce(0, +) / Double(confs.count)
        if meanConf < meanConfidenceFloor { return true }
        if let minConf = confs.min(), minConf < minObservationConfidenceFloor {
            return true
        }

        // OCR-text quality check — catches over-confident gibberish
        // (words run together, words split apart, low language
        // confidence) that the confidence floors above miss because
        // Vision claimed 0.9+ on the bad output.
        let regionText = observations.map(\.text).joined(separator: " ")
        if let q = OCRTextQualityScorer().score(text: regionText),
           q.combined < textQualityFloor {
            return true
        }

        // Vertical gap check (within-region: smells like Vision dropped
        // a line or two and left us with a paragraph that reads as a
        // truncated fragment).
        let sorted = observations.sorted { $0.box.midY > $1.box.midY }  // top first
        guard sorted.count >= 2 else { return false }
        let medianH = sorted.map(\.box.height).sorted()[sorted.count / 2]
        guard medianH > 0 else { return false }
        for i in 1..<sorted.count {
            let prevBottom = sorted[i - 1].box.minY
            let currTop    = sorted[i].box.maxY
            let gap = prevBottom - currTop
            if gap > gapMultiplier * medianH { return true }
        }
        return false
    }

    // MARK: - region <-> observation operations

    static func filter(
        observations: [TextObservation], inRegion region: LayoutRegion
    ) -> [TextObservation] {
        let inflated = region.box.insetBy(dx: -regionInflation, dy: -regionInflation)
        return observations.filter { obs in
            inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
        }
    }

    static func replace(
        observations: [TextObservation],
        inRegion region: LayoutRegion,
        with replacements: [TextObservation]
    ) -> [TextObservation] {
        let inflated = region.box.insetBy(dx: -regionInflation, dy: -regionInflation)
        var out = observations.filter { obs in
            !inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
        }
        out.append(contentsOf: replacements)
        return out
    }

    // MARK: - cropping + coordinate translation

    /// Crop `image` to the region's normalized bbox, with `cropMargin`
    /// on each side. Returns the cropped CGImage or nil if the result
    /// would be degenerate.
    static func cropImage(_ image: CGImage, to normalizedRegionBox: CGRect) -> CGImage? {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        guard imgW > 0, imgH > 0 else { return nil }

        let inflated = normalizedRegionBox.insetBy(dx: -cropMargin, dy: -cropMargin)
        // Clamp to [0,1].
        let nx = max(0, min(1, inflated.minX))
        let ny = max(0, min(1, inflated.minY))
        let nMaxX = max(0, min(1, inflated.maxX))
        let nMaxY = max(0, min(1, inflated.maxY))
        let nw = nMaxX - nx
        let nh = nMaxY - ny
        guard nw > 0.001, nh > 0.001 else { return nil }

        // Convert normalized bottom-left to pixel top-left.
        let pixelX = nx * imgW
        let pixelY = (1 - nMaxY) * imgH
        let pixelW = nw * imgW
        let pixelH = nh * imgH
        let cropRect = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH).integral
        return image.cropping(to: cropRect)
    }

    /// Translate observations from a CROPPED image's coordinate space
    /// back to the full page's normalized coordinate space.
    static func translate(
        observations: [TextObservation],
        fromCropOf normalizedRegionBox: CGRect,
        intoFullPage pageImage: CGImage
    ) -> [TextObservation] {
        let inflated = normalizedRegionBox.insetBy(dx: -cropMargin, dy: -cropMargin)
        let nx = max(0, min(1, inflated.minX))
        let ny = max(0, min(1, inflated.minY))
        let nMaxX = max(0, min(1, inflated.maxX))
        let nMaxY = max(0, min(1, inflated.maxY))
        let regionW = nMaxX - nx
        let regionH = nMaxY - ny
        guard regionW > 0, regionH > 0 else { return [] }

        return observations.map { obs in
            // obs.box is in normalized coords of the CROPPED image
            // (Vision/Tesseract convention: bottom-left origin, [0,1]).
            // Translate to full-page normalized.
            let fullX = nx + obs.box.minX * regionW
            let fullY = ny + obs.box.minY * regionH
            let fullW = obs.box.width * regionW
            let fullH = obs.box.height * regionH
            return TextObservation(
                text: obs.text,
                confidence: obs.confidence,
                box: CGRect(x: fullX, y: fullY, width: fullW, height: fullH),
                source: obs.source
            )
        }
    }
}
