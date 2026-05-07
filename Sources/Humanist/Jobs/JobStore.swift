import Foundation
import Combine

/// Persistent JSON-backed queue. One file in
/// `~/Library/Application Support/Humanist/queue.json` — small enough
/// that a full rewrite on every change is fine; simple enough that we
/// don't need GRDB until the queue gets very large.
///
/// Recovery: any job left in `.running` when the app died (e.g. crash
/// mid-batch) is rolled back to `.queued` on next launch so the runner
/// re-processes it instead of leaving a phantom in-flight entry.
@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [Job] = []

    let storeURL: URL

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let dir = support.appendingPathComponent("Humanist", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            self.storeURL = dir.appendingPathComponent("queue.json")
        }
        load()
    }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              var decoded = try? JSONDecoder().decode([Job].self, from: data)
        else { return }
        // Recovery: a job in `.running` at load time is from a previous
        // launch that died mid-conversion. Roll it back so the runner
        // re-picks it up.
        for i in decoded.indices where decoded[i].status == .running {
            decoded[i].status = .queued
            decoded[i].progress = nil
            decoded[i].startedAt = nil
        }
        // `.profiling` jobs got persisted before the profiler finished.
        // The runner skips them, so without this they'd stick forever.
        // Promote to `.queued` — picker languages were set at create
        // time, so they're already runnable; the user just won't get
        // the auto-detected language for that one job.
        for i in decoded.indices where decoded[i].status == .profiling {
            decoded[i].status = .queued
        }
        jobs = decoded
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - mutations

    func add(_ job: Job) {
        jobs.append(job)
        save()
    }

    func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        save()
    }

    func update(_ id: UUID, _ mutate: (inout Job) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[idx])
        save()
    }

    /// Drag-reorder support for the queue list. SwiftUI's `.onMove`
    /// hands us the source `IndexSet` + destination offset; we just
    /// delegate to `Array.move(fromOffsets:toOffset:)` and persist.
    /// The runner picks `nextQueued` (first `.queued` in array order),
    /// so reordering directly changes what runs next.
    ///
    /// Non-queued jobs (running / done / failed / cancelled) can be
    /// dragged too — the reorder still permutes the array, but only
    /// queued jobs affect the runner's next pick. Letting users
    /// freely reorder beats imposing per-row drag-eligibility rules
    /// that would surprise them.
    func move(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        jobs.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Drop every job whose status has resolved (done, failed, cancelled).
    /// Keeps the queue panel uncluttered after a successful batch.
    func clearFinished() {
        jobs.removeAll { job in
            switch job.status {
            case .done, .failed, .cancelled:        return true
            case .queued, .running, .profiling:     return false
            }
        }
        save()
    }

    // MARK: - queries

    var nextQueued: Job? {
        jobs.first { $0.status == .queued }
    }

    var hasPendingWork: Bool {
        jobs.contains {
            $0.status == .queued || $0.status == .running || $0.status == .profiling
        }
    }

    /// Jobs the launcher renders at the top of the queue list —
    /// the user's active focus. Order matches `jobs` (arrival, with
    /// any user reorder applied via `move(from:to:)`).
    var activeJobs: [Job] {
        jobs.filter {
            switch $0.status {
            case .queued, .running, .profiling: return true
            case .done, .failed, .cancelled:    return false
            }
        }
    }

    /// Jobs the launcher renders inside the History disclosure at
    /// the bottom of the queue list. Sorted most-recent-finish first
    /// so a quick scan after a bulk run shows the newest results at
    /// the top of the disclosure. Jobs missing `finishedAt`
    /// (shouldn't happen for finished statuses, but defensively)
    /// sort to the bottom.
    var finishedJobs: [Job] {
        jobs.filter {
            switch $0.status {
            case .done, .failed, .cancelled:    return true
            case .queued, .running, .profiling: return false
            }
        }
        .sorted { (a, b) in
            switch (a.finishedAt, b.finishedAt) {
            case (nil, nil): return false
            case (nil, _):   return false
            case (_, nil):   return true
            case (let l?, let r?): return l > r
            }
        }
    }
}
