import Foundation
import CoreGraphics
import Vision
import OCR

/// Apple Vision-backed figure detector. Stand-in for Surya's
/// `.picture` region detection when (a) Surya isn't installed and
/// (b) the PDF doesn't carry image XObjects we can extract directly.
/// Uses `VNGenerateObjectnessBasedSaliencyImageRequest`, which returns
/// the bounding boxes of the most object-like regions on a page — a
/// reasonable proxy for "this looks like a figure, not body text" on
/// scanned material.
///
/// Quality bounds: Vision's saliency model wasn't trained on document
/// layouts, so it will:
///   * Miss small figures (decorative spot illustrations) below the
///     saliency threshold.
///   * Trip on drop caps, large page-numbering ornaments, fancy
///     chapter-heading typography.
///   * Provide no `.formula` / `.table` distinction — every
///     detection is treated as a `.picture` region.
///
/// Despite the gaps, "some figures" is better than "no figures" on
/// scanned books with substantial illustrations when Surya isn't
/// available. The pipeline only consults this detector after both
/// the PDF-XObject path and Surya have come back empty.
public struct VisionFigureDetector: Sendable {

    public init() {}

    /// Minimum bbox area (as a fraction of page area) to count as a
    /// figure. Filters drop caps and decorative ornaments at the
    /// expense of small inline illustrations.
    public static let minPageCoverage: CGFloat = 0.02

    /// Maximum fraction of the page's *total text* allowed inside
    /// a candidate figure bbox before we reject it as a false
    /// positive. The saliency model frequently fires on body-text
    /// blocks, and "fraction of bbox covered by text" reads low for
    /// sparse text even when the region IS text. Symmetric check —
    /// "fraction of all page text inside this region" — is more
    /// robust: a real figure with a few text labels still passes
    /// (labels are a small fraction of the page's text), but a
    /// salient region that swallows most of the page's text gets
    /// rejected.
    public static let maxFractionOfPageTextInside: CGFloat = 0.3
    /// Hard cap on number of text observations a candidate figure
    /// bbox may contain. Belt-and-suspenders against the
    /// `maxFractionOfPageTextInside` floor — short pages (very few
    /// observations) can still produce salient regions that pass
    /// the fraction check while clearly containing prose. A figure
    /// with > this many labels is almost certainly text being
    /// misread as a figure.
    public static let maxTextObservationsInside: Int = 8

    /// Run Vision saliency on `pageImage`, filter against
    /// `textObservations`, and return picture-region bboxes in
    /// Vision-normalized coordinates (origin bottom-left, [0,1]).
    /// `kind` is always `.picture` — Vision can't distinguish
    /// pictures from formulas or tables.
    public func detect(
        pageImage: CGImage,
        textObservations: [OCR.TextObservation]
    ) async -> [LayoutRegion] {
        // Vision request + handler aren't Sendable, so we hop to a
        // background queue via a checked continuation rather than
        // `Task.detached`. The request body stays self-contained
        // (no captured non-Sendable state crosses an actor boundary).
        let salientObjects: [VNRectangleObservation] = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNGenerateObjectnessBasedSaliencyImageRequest()
                let handler = VNImageRequestHandler(cgImage: pageImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(returning: [])
                    return
                }
                let objects = request.results?.first?.salientObjects ?? []
                cont.resume(returning: objects)
            }
        }
        guard !salientObjects.isEmpty else { return [] }

        // Precompute total text area for the "fraction of page text
        // inside this bbox" gate. Zero when the page has no text
        // observations at all (page-OCR mode before saliency runs);
        // the gate then collapses to size + saliency confidence.
        let totalTextArea: CGFloat = textObservations.reduce(0) { sum, obs in
            sum + (obs.box.width * obs.box.height)
        }

        var regions: [LayoutRegion] = []
        // Vision returns boundingBox in normalized image coordinates
        // (origin bottom-left, [0,1]) — same convention the rest of
        // the pipeline uses. No translation needed.
        for (idx, salient) in salientObjects.enumerated() {
            let box = salient.boundingBox
            let coverage = box.width * box.height
            guard coverage >= Self.minPageCoverage else { continue }

            // Reject salient regions that swallow most of the page's
            // text. A genuine figure may have a few label observations
            // inside it; one that contains > 30% of the page's text
            // is body text being misclassified.
            if totalTextArea > 0 {
                let textInside = textObservations.reduce(0.0) { sum, obs in
                    let inter = obs.box.intersection(box)
                    return inter.isNull
                        ? sum
                        : sum + (inter.width * inter.height)
                }
                let fractionOfPageText = textInside / totalTextArea
                guard fractionOfPageText <= Self.maxFractionOfPageTextInside
                else { continue }
            }

            // Hard cap on text-observation count inside the region.
            // Belt-and-suspenders for short pages where the fraction
            // gate above doesn't bite (few small observations whose
            // total area is dwarfed by the bbox).
            let observationsInside = textObservations.filter { obs in
                box.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
            }.count
            guard observationsInside <= Self.maxTextObservationsInside
            else { continue }

            regions.append(LayoutRegion(
                kind: .picture,
                box: box,
                readingOrder: idx,
                confidence: Double(salient.confidence)
            ))
        }
        return regions
    }

    /// Fraction of `bbox` covered by any text observation. Uses
    /// bbox-area-weighted intersection sum (over-counts when two
    /// text observations overlap each other inside the bbox; close
    /// enough for a threshold gate).
    private func textCoverage(
        of bbox: CGRect, by observations: [OCR.TextObservation]
    ) -> CGFloat {
        guard bbox.width > 0, bbox.height > 0 else { return 0 }
        let bboxArea = bbox.width * bbox.height
        var covered: CGFloat = 0
        for obs in observations {
            let intersection = bbox.intersection(obs.box)
            if !intersection.isNull {
                covered += intersection.width * intersection.height
            }
        }
        return min(1, covered / bboxArea)
    }
}
