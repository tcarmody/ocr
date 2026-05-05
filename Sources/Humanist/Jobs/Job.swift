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
        costEstimate: CostEstimator.Estimate? = nil
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
    }

    /// Custom decoder so the optional `profile`, `costEstimate`, and
    /// (already-optional) `stats` survive a queue store JSON written
    /// before any of those fields existed.
    enum CodingKeys: String, CodingKey {
        case id, sourceURL, outputURL, options, status, progress, error
        case addedAt, startedAt, finishedAt, stats, profile, costEstimate
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
    }
}

/// Subset of `PDFToEPUBPipeline.Options` we let the queue carry.
/// Languages are stored as their BCP-47 raw values for clean
/// JSON encoding.
struct ConversionOptions: Codable, Equatable {
    var languages: [String]
    var useHighAccuracyOCR: Bool

    init(languages: [String] = ["en"], useHighAccuracyOCR: Bool = false) {
        self.languages = languages
        self.useHighAccuracyOCR = useHighAccuracyOCR
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
