import Foundation
import PDFIngest
import Pipeline

/// One bulk-conversion task: PDF in, EPUB out, current status, progress.
/// The store persists these to JSON so a long batch can resume cleanly
/// across app launches.
struct Job: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        /// Briefly held in this state while `DocumentProfiler` samples
        /// the PDF for language detection. The runner skips
        /// `.profiling` jobs — they flip to `.queued` once the
        /// profile completes (or `.queued` immediately on profile
        /// failure, which is non-fatal).
        case profiling
        case queued, running, done, failed, cancelled
    }

    let id: UUID
    /// Source PDF on disk.
    var sourceURL: URL
    /// Destination EPUB. Default convention: same folder as source, same
    /// basename, `.epub` extension.
    var outputURL: URL
    /// Conversion options snapshotted when the job was added — the user
    /// can change the picker between adds and each job remembers what
    /// was chosen.
    var options: ConversionOptions
    var status: Status
    /// Pages processed so far / total pages. nil before the runner picks
    /// the job up.
    var progress: JobProgress?
    /// Failure message — populated when `status == .failed`.
    var error: String?
    var addedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    /// Post-conversion stats — Claude calls, cost, per-source
    /// observation counts. Populated by `JobRunner` when convert()
    /// returns successfully. Nil for jobs persisted before this
    /// field existed (the queue store JSON-decodes optionally) and
    /// for queued/running jobs that haven't completed yet.
    var stats: ConversionStats?
    /// Pre-flight document profile — primary/secondary language
    /// detection and scan flag. Populated by `QueueViewModel` after
    /// `DocumentProfiler` runs at queue-add time. Nil for jobs
    /// persisted before this field existed and for jobs currently
    /// in `.profiling` state.
    var profile: DocumentProfile?
    /// Pre-flight Cloud-mode cost estimate. Populated alongside
    /// `profile` when the user has Cloud mode enabled. `.empty` when
    /// Cloud mode is off or no Cloud features are toggled. Nil for
    /// jobs persisted before this field existed.
    var costEstimate: CostEstimator.Estimate?
    /// Pre-flight content-vs-config warnings. Populated alongside
    /// `profile`; empty array means no nudges to show. Nil for jobs
    /// persisted before this field existed (queue store decodes
    /// optionally and treats nil as empty in the UI).
    var profileWarnings: [ProfileWarning]?

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        outputURL: URL,
        options: ConversionOptions,
        status: Status = .queued,
        progress: JobProgress? = nil,
        error: String? = nil,
        addedAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        stats: ConversionStats? = nil,
        profile: DocumentProfile? = nil,
        costEstimate: CostEstimator.Estimate? = nil,
        profileWarnings: [ProfileWarning]? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.options = options
        self.status = status
        self.progress = progress
        self.error = error
        self.addedAt = addedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.stats = stats
        self.profile = profile
        self.costEstimate = costEstimate
        self.profileWarnings = profileWarnings
    }

    /// Custom decoder so the optional `profile`, `costEstimate`,
    /// `profileWarnings`, and (already-optional) `stats` survive a
    /// queue store JSON written before any of those fields existed.
    enum CodingKeys: String, CodingKey {
        case id, sourceURL, outputURL, options, status, progress, error
        case addedAt, startedAt, finishedAt, stats, profile, costEstimate
        case profileWarnings
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.sourceURL = try c.decode(URL.self, forKey: .sourceURL)
        self.outputURL = try c.decode(URL.self, forKey: .outputURL)
        self.options = try c.decode(ConversionOptions.self, forKey: .options)
        self.status = try c.decode(Status.self, forKey: .status)
        self.progress = try c.decodeIfPresent(JobProgress.self, forKey: .progress)
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
        self.addedAt = try c.decode(Date.self, forKey: .addedAt)
        self.startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        self.finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.stats = try c.decodeIfPresent(ConversionStats.self, forKey: .stats)
        self.profile = try c.decodeIfPresent(DocumentProfile.self, forKey: .profile)
        self.costEstimate = try c.decodeIfPresent(
            CostEstimator.Estimate.self, forKey: .costEstimate
        )
        self.profileWarnings = try c.decodeIfPresent(
            [ProfileWarning].self, forKey: .profileWarnings
        )
    }
}

/// Subset of `PDFToEPUBPipeline.Options` we let the queue carry.
/// Languages are stored as their BCP-47 raw values for clean
/// JSON encoding.
struct ConversionOptions: Codable, Equatable {
    var languages: [String]
    /// Force Surya OCR on every region of every page (bypassing
    /// the per-region cascade). Slow but a useful local-only
    /// quality lever for books whose Vision output is poor and
    /// for which the user has no API key. Previously named
    /// `useHighAccuracyOCR`; renamed to make the engine explicit.
    var useSuryaOCR: Bool
    /// "Claude OCR ($$$)" toggle in the launcher. Drives the
    /// end-to-end page-OCR path: one Sonnet call per page returns
    /// structured XHTML in, `[Block]` out. Bypasses the Vision /
    /// Surya / Tesseract cascade entirely; Surya layout still runs
    /// for figure + table extraction. Only fires when the
    /// conversion is in Cloud mode and an API key is configured —
    /// otherwise inert (the toggle is allowed to be on regardless).
    /// Persisted under the legacy key `useCloudEnhancedOCR` so
    /// existing queued jobs still load (see `CodingKeys`).
    var useClaudePageOCR: Bool
    /// Skip the embedded-text trust path and re-OCR every page.
    /// Per-job because some PDFs ship with bad embedded text
    /// layers (broken `ToUnicode`, mojibake) that the trust scorer
    /// can mistake for legitimate prose. Previously lived on
    /// `AISettings`; promoted to ConversionOptions so the launcher
    /// can offer it as a per-conversion toggle.
    var forceOCR: Bool
    /// Override Settings to disable every cloud feature for this
    /// conversion. Forces `cloudFeatures` to all-off and clears the
    /// API-key provider in the runner — no Claude calls happen
    /// regardless of the user's global processing-mode / cloud
    /// toggles. `useClaudePageOCR` is also coerced off, since it
    /// only fires on Cloud mode + key. Useful for one-off privacy-
    /// sensitive conversions without flipping global settings.
    var privateMode: Bool
    /// Emit `<basename>.humanist-debug/<basename>.log` next to the
    /// EPUB output and skip the staging-dir cleanup so the per-page
    /// PNGs and checkpoint JSON survive for inspection. Surfaces the
    /// pipeline's `emitDebugLog` flag — only useful for diagnosing
    /// conversion issues, otherwise leaves a directory's worth of
    /// artifacts on disk.
    var emitDebugLog: Bool
    /// Write `.txt` and `.md` siblings next to the EPUB. Cheap;
    /// default on.
    var emitSiblingTextOutputs: Bool
    /// Write `.html` and `.docx` siblings next to the EPUB. Heavier
    /// (binary DOCX, large self-contained HTML); default off.
    var emitSiblingDocuments: Bool
    /// Tier 9 / V-Trust-PerPage. User-typed page-range string —
    /// 1-based, comma-separated, with `N-M` ranges:
    /// "1-20, 150-160". Pages in any range bypass the embedded-
    /// text trust path and force OCR. Empty string = no per-page
    /// override (the global `forceOCR` still applies if set).
    /// Stored as the typed string so the UI can show what the
    /// user entered; parsed to `[ClosedRange<Int>]` at job-run
    /// time via `PageRangeParser`.
    var forceOCRPageRangesString: String
    /// Optional output-filename suffix. When non-empty, appended
    /// (with a leading space) to the source basename for every
    /// output: `<basename> <suffix>.epub`, `<basename> <suffix>.txt`,
    /// `<basename> <suffix>.md`, `<basename> <suffix>.humanist-debug/`.
    /// Lets the user run the same source PDF through different
    /// settings (e.g. "claude" vs "local") so both outputs land
    /// side-by-side without manual rename, and Tools → Compare
    /// EPUBs can A/B them. Empty string = original behavior
    /// (basename only).
    var outputSuffix: String
    /// Tier 9 / V-PDF-Searchable. When true, the conversion writes
    /// a searchable copy of the source PDF (`<basename>.searchable.pdf`)
    /// alongside the EPUB. Off by default — searchable PDFs are
    /// several MB per book and most users only need the EPUB.
    var emitSearchablePDF: Bool

    init(
        languages: [String] = ["en"],
        useSuryaOCR: Bool = false,
        useClaudePageOCR: Bool = false,
        forceOCR: Bool = false,
        privateMode: Bool = false,
        emitDebugLog: Bool = false,
        emitSiblingTextOutputs: Bool = true,
        emitSiblingDocuments: Bool = false,
        forceOCRPageRangesString: String = "",
        outputSuffix: String = "",
        emitSearchablePDF: Bool = false
    ) {
        self.languages = languages
        self.useSuryaOCR = useSuryaOCR
        self.useClaudePageOCR = useClaudePageOCR
        self.forceOCR = forceOCR
        self.privateMode = privateMode
        self.emitDebugLog = emitDebugLog
        self.emitSiblingTextOutputs = emitSiblingTextOutputs
        self.emitSiblingDocuments = emitSiblingDocuments
        self.forceOCRPageRangesString = forceOCRPageRangesString
        self.outputSuffix = outputSuffix
        self.emitSearchablePDF = emitSearchablePDF
    }

    /// Codable: decodes both the new `useSuryaOCR` / `useClaudePageOCR`
    /// keys and the legacy `useHighAccuracyOCR` / `useCloudEnhancedOCR`
    /// keys so persisted jobs from pre-rename versions still load.
    private enum CodingKeys: String, CodingKey {
        case languages
        case useSuryaOCR
        case useHighAccuracyOCR  // legacy alias for useSuryaOCR
        case useClaudePageOCR
        case useCloudEnhancedOCR  // legacy alias for useClaudePageOCR
        case forceOCR
        case privateMode
        case emitDebugLog
        case emitSiblingTextOutputs
        case emitSiblingDocuments
        case forceOCRPageRangesString
        case outputSuffix
        case emitSearchablePDF
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.languages = try c.decode([String].self, forKey: .languages)
        if let surya = try c.decodeIfPresent(Bool.self, forKey: .useSuryaOCR) {
            self.useSuryaOCR = surya
        } else {
            self.useSuryaOCR = try c.decodeIfPresent(
                Bool.self, forKey: .useHighAccuracyOCR
            ) ?? false
        }
        if let claude = try c.decodeIfPresent(
            Bool.self, forKey: .useClaudePageOCR
        ) {
            self.useClaudePageOCR = claude
        } else {
            self.useClaudePageOCR = try c.decodeIfPresent(
                Bool.self, forKey: .useCloudEnhancedOCR
            ) ?? false
        }
        self.forceOCR = try c.decodeIfPresent(Bool.self, forKey: .forceOCR) ?? false
        self.privateMode = try c.decodeIfPresent(
            Bool.self, forKey: .privateMode
        ) ?? false
        self.emitDebugLog = try c.decodeIfPresent(
            Bool.self, forKey: .emitDebugLog
        ) ?? false
        // Default-on for legacy decode: existing users keep txt+md.
        self.emitSiblingTextOutputs = try c.decodeIfPresent(
            Bool.self, forKey: .emitSiblingTextOutputs
        ) ?? true
        // Default-off: html+docx are opt-in (heavier files).
        self.emitSiblingDocuments = try c.decodeIfPresent(
            Bool.self, forKey: .emitSiblingDocuments
        ) ?? false
        self.forceOCRPageRangesString = try c.decodeIfPresent(
            String.self, forKey: .forceOCRPageRangesString
        ) ?? ""
        self.outputSuffix = try c.decodeIfPresent(
            String.self, forKey: .outputSuffix
        ) ?? ""
        // Default-off for legacy decode: existing users opt in to
        // searchable-PDF output explicitly.
        self.emitSearchablePDF = try c.decodeIfPresent(
            Bool.self, forKey: .emitSearchablePDF
        ) ?? false
    }

    /// Encode under the new keys only — the legacy aliases are for
    /// reads, not writes.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(languages, forKey: .languages)
        try c.encode(useSuryaOCR, forKey: .useSuryaOCR)
        try c.encode(useClaudePageOCR, forKey: .useClaudePageOCR)
        try c.encode(forceOCR, forKey: .forceOCR)
        try c.encode(privateMode, forKey: .privateMode)
        try c.encode(emitDebugLog, forKey: .emitDebugLog)
        try c.encode(emitSiblingTextOutputs, forKey: .emitSiblingTextOutputs)
        try c.encode(emitSiblingDocuments, forKey: .emitSiblingDocuments)
        try c.encode(forceOCRPageRangesString, forKey: .forceOCRPageRangesString)
        try c.encode(outputSuffix, forKey: .outputSuffix)
        try c.encode(emitSearchablePDF, forKey: .emitSearchablePDF)
    }
}

struct JobProgress: Codable, Equatable {
    var completedPages: Int
    var totalPages: Int

    var fraction: Double {
        guard totalPages > 0 else { return 0 }
        return Double(completedPages) / Double(totalPages)
    }
}
