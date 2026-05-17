import Foundation
import PDFKit
import NaturalLanguage

/// Pre-flight document profiler. Samples a few pages from a PDF at
/// queue-add time, uses `NLLanguageRecognizer` to identify the
/// dominant language, and emits a `DocumentProfile` the queue UI
/// uses to seed per-book defaults (currently just the language
/// picker; future versions feed cost estimation and profile
/// warnings).
///
/// Architectural shape parallels `TwoUpDetector`: pure static API,
/// no instance state, returns a value that callers thread into the
/// queue's `ConversionOptions`. The profile is a hint, not a
/// directive — the user's picker still wins on low-confidence
/// detection or when the user has actively overridden.
///
/// **Scope (v1).** Profiling is **embedded-text-only**. Pages
/// without an embedded text layer (flatbed scans, image-only PDFs)
/// are flagged via `isLikelyScan: true`; the profile returns no
/// language guess and the queue falls back to the user's picker.
/// Adding a Vision-OCR fallback for scans would mean blocking the
/// queue-add interaction on Vision's per-page latency — deferred
/// until we decide that's worth the UX cost.
public enum DocumentProfiler {
    /// Per-page sample text + recognizer output. Surfaced for
    /// debugging / logging; the public `profile(...)` aggregates
    /// these into a single `DocumentProfile`.
    public struct Sample: Sendable, Equatable {
        public let pageIndex: Int
        public let charCount: Int
        public let dominantLanguage: String?  // BCP-47 primary subtag
        public let topConfidence: Double      // 0…1
    }

    /// Build a `DocumentProfile` for `pdfURL`. Samples up to
    /// `sampleCount` evenly-spaced body pages (skipping the cover);
    /// for each, reads the embedded text and feeds the result to
    /// `NLLanguageRecognizer`. Aggregates the per-page results into
    /// a confidence-weighted document-level guess.
    ///
    /// Returns the profile synchronously — embedded-text reads are
    /// cheap and the profile completes in well under 100ms on a
    /// typical book. Callers can still wrap the call in `Task` if
    /// they want to keep the main actor responsive.
    public static func profile(
        pdfURL: URL, sampleCount: Int = 3
    ) -> DocumentProfile {
        guard let doc = PDFDocument(url: pdfURL), doc.pageCount > 0 else {
            return DocumentProfile()
        }
        // Wrap the PDFDocument in LoadedPDF so the XObject probe
        // below can reuse its `pageRef` accessor.
        let loaded = LoadedPDF(url: pdfURL, document: doc)

        let pageIndices = sampleIndices(
            pageCount: doc.pageCount, target: sampleCount
        )
        var samples: [Sample] = []
        var languageWeights: [String: Double] = [:]
        var totalCharCount = 0
        var pagesWithText = 0
        // XObject probe: count embedded image XObjects per sampled
        // page. High counts on art books / journal articles flag
        // them as complex-layout candidates for Cloud page OCR,
        // which keeps figures + captions intact better than the
        // per-region cascade. Filtered to *real figures* (not
        // whole-page scans) by the detector's coverage thresholds.
        let xObjectDetector = PDFImageXObjectDetector()
        var totalImageXObjects = 0

        for i in pageIndices {
            guard let page = doc.page(at: i) else { continue }
            // Image XObjects on this sampled page. Detector
            // already filters whole-page scans (per-page raster
            // image) and decorative drop-caps via its coverage
            // thresholds, so the count is "real figures only."
            totalImageXObjects += xObjectDetector.detect(
                in: loaded, pageIndex: i
            ).count
            // PDFKit's `page.string` returns the embedded text layer
            // directly. Empty / whitespace-only when the PDF is a
            // flatbed scan with no OCR layer.
            let raw = page.string ?? ""
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= minSampleChars {
                pagesWithText += 1
                totalCharCount += text.count
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(text)
                let dominant = recognizer.dominantLanguage
                let conf: Double
                if let dom = dominant {
                    conf = recognizer.languageHypotheses(withMaximum: 5)[dom] ?? 0
                } else {
                    conf = 0
                }
                samples.append(Sample(
                    pageIndex: i, charCount: text.count,
                    dominantLanguage: dominant?.rawValue,
                    topConfidence: conf
                ))
                if let dom = dominant?.rawValue, conf > 0 {
                    // Weight by char count so a short ambiguous page
                    // doesn't drown out a long well-recognized one.
                    languageWeights[dom, default: 0] += Double(text.count) * conf
                }
            } else {
                samples.append(Sample(
                    pageIndex: i, charCount: text.count,
                    dominantLanguage: nil, topConfidence: 0
                ))
            }
        }

        // Aggregate. Primary = highest-weighted language; secondary =
        // any other languages with weight ≥ secondaryWeightFloor of
        // the primary.
        let isLikelyScan = pagesWithText == 0
        let imageXObjectsPerPage = samples.isEmpty
            ? 0
            : Double(totalImageXObjects) / Double(samples.count)

        guard let (primary, primaryWeight) = languageWeights
            .max(by: { $0.value < $1.value })
        else {
            return DocumentProfile(
                primaryLanguage: nil,
                secondaryLanguages: [],
                confidence: 0,
                isLikelyScan: isLikelyScan,
                pageCount: doc.pageCount,
                samplesAnalyzed: samples.count,
                imageXObjectsPerPage: imageXObjectsPerPage
            )
        }
        let secondary = languageWeights
            .filter { $0.key != primary
                && $0.value >= primaryWeight * secondaryWeightFloor }
            .keys
            .sorted()
        // Confidence: weighted-average top-hypothesis probability
        // for the primary language across pages where it was the
        // top guess. Captures both how much primary text we saw and
        // how confident NLR was in it.
        let primaryConfPages = samples.filter {
            $0.dominantLanguage == primary
        }
        let primaryCharSum = primaryConfPages.reduce(0) { $0 + $1.charCount }
        let confidence: Double
        if primaryCharSum > 0 {
            let weighted = primaryConfPages.reduce(0.0) {
                $0 + $1.topConfidence * Double($1.charCount)
            }
            confidence = weighted / Double(primaryCharSum)
        } else {
            confidence = 0
        }

        return DocumentProfile(
            primaryLanguage: primary,
            secondaryLanguages: Array(secondary),
            confidence: confidence,
            isLikelyScan: isLikelyScan,
            pageCount: doc.pageCount,
            samplesAnalyzed: samples.count,
            imageXObjectsPerPage: imageXObjectsPerPage
        )
    }

    /// Pick `target` evenly-spaced page indices from a `pageCount`-
    /// page document, skipping the cover (page 0) when the document
    /// has more than one page. Short documents return whatever
    /// they've got.
    static func sampleIndices(pageCount: Int, target: Int) -> [Int] {
        guard pageCount > 0, target > 0 else { return [] }
        if pageCount == 1 { return [0] }
        // Skip page 0 (often a cover / title page). Sample evenly
        // through the rest.
        let bodyStart = 1
        let bodyEnd = pageCount - 1
        let bodyCount = bodyEnd - bodyStart + 1
        guard bodyCount > 0 else { return [0] }
        if bodyCount <= target {
            return Array(bodyStart...bodyEnd)
        }
        // Pick `target` indices evenly across the body. For target=3
        // and bodyCount=100 you get roughly the 25%, 50%, 75% pages.
        var indices: [Int] = []
        for k in 0..<target {
            // Add 1 to numerator/denominator so we land *inside*
            // the body, not on the edges.
            let pos = bodyStart + Int(
                Double(k + 1) / Double(target + 1) * Double(bodyCount)
            )
            indices.append(min(pos, bodyEnd))
        }
        return indices
    }

    /// Below this many characters, a sampled page is too short to
    /// score reliably — `NLLanguageRecognizer` confidence collapses
    /// for very short strings and false matches multiply.
    public static let minSampleChars: Int = 100

    /// Secondary languages must have at least this fraction of the
    /// primary's weight to appear in the profile. 0.20 means the
    /// secondary language got ≥ 20% as much text as the primary —
    /// a real bilingual document, not just one stray word.
    public static let secondaryWeightFloor: Double = 0.20
}
