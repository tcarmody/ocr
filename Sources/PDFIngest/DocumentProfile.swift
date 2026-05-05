import Foundation

/// Output of `DocumentProfiler` — a coarse pre-flight profile of a
/// PDF, computed by sampling a few pages at queue-add time. The
/// queue uses this to seed the language picker default per book so
/// the user doesn't have to remember to switch from English before
/// dropping a Greek scan.
///
/// Codable so a profile can persist on a `Job` (and survive the
/// queue store's JSON round-trip) — surfacing the detected language
/// in the queue row even after an app restart.
public struct DocumentProfile: Sendable, Equatable, Codable {
    /// Primary BCP-47 language guess. Nil when no sample produced
    /// confident detection — caller should fall back to the user's
    /// picker default in that case.
    public var primaryLanguage: String?
    /// Other languages that showed up across samples with at least
    /// `secondaryConfidenceFloor` confidence. Mostly relevant for
    /// books with foreign-language quotations (Greek body, English
    /// preface) — the profile flags both so the user / pipeline can
    /// configure for it.
    public var secondaryLanguages: [String]
    /// Aggregate confidence in `primaryLanguage`. Mean of per-sample
    /// `NLLanguageRecognizer` top-hypothesis probabilities, weighted
    /// by sample text length so long well-recognized passages
    /// dominate over short ambiguous ones. 0 when no detection.
    public var confidence: Double
    /// True when the profiler had to render + Vision OCR the sampled
    /// pages because no embedded text was available (or the embedded
    /// text was bad enough to look like a scan with a bad ToUnicode
    /// table). Surfaced to the queue UI so the user knows whether
    /// `Force OCR` or `useHighAccuracyOCR` are likely to matter.
    public var isLikelyScan: Bool
    /// PDF page count at profile time.
    public var pageCount: Int
    /// Number of pages the profiler sampled. Less than three usually
    /// means a very short document (1–2 pages).
    public var samplesAnalyzed: Int

    public init(
        primaryLanguage: String? = nil,
        secondaryLanguages: [String] = [],
        confidence: Double = 0,
        isLikelyScan: Bool = false,
        pageCount: Int = 0,
        samplesAnalyzed: Int = 0
    ) {
        self.primaryLanguage = primaryLanguage
        self.secondaryLanguages = secondaryLanguages
        self.confidence = confidence
        self.isLikelyScan = isLikelyScan
        self.pageCount = pageCount
        self.samplesAnalyzed = samplesAnalyzed
    }
}
