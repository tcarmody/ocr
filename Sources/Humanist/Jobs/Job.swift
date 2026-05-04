import Foundation

/// One bulk-conversion task: PDF in, EPUB out, current status, progress.
/// The store persists these to JSON so a long batch can resume cleanly
/// across app launches.
struct Job: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
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
        finishedAt: Date? = nil
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
