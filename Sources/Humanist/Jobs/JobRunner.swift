import Foundation
import AI
import Document
import Pipeline

/// Serial job processor. Picks the next `.queued` job from the store
/// and runs it through `PDFToEPUBPipeline`, surfacing per-page progress
/// back into the store so the queue UI updates live.
///
/// Concurrency: one job at a time. Surya is the bottleneck, lives in a
/// single Python process, and is the most likely engine to be invoked
/// in bulk runs — running multiple jobs in parallel against the same
/// sidecar would just contend on it. Configurable later if there's
/// demand.
@MainActor
final class JobRunner: ObservableObject {
    let store: JobStore

    /// `true` while the run loop is processing a job (or about to).
    @Published private(set) var isRunning: Bool = false
    /// Job IDs the user has asked to cancel but whose pipeline hasn't
    /// finished winding down yet. The UI reads this to show
    /// "Cancelling…" instead of the Cancel button — without it,
    /// clicking Cancel on a long Surya call appears to do nothing
    /// for ~10s while the engine completes the current page.
    @Published private(set) var cancellingJobIDs: Set<UUID> = []

    private var loopTask: Task<Void, Never>?
    /// Pipeline task for the currently-running job. Holding it here
    /// lets per-job cancel reach into the pipeline via cooperative
    /// cancellation.
    private var currentJobTask: Task<Void, Never>?
    private var currentJobID: UUID?

    init(store: JobStore) {
        self.store = store
    }

    /// Kick off the loop if nothing is in flight. Safe to call after
    /// every add — no-op when already running.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { @MainActor in
            isRunning = true
            defer {
                isRunning = false
                loopTask = nil
            }
            while let job = store.nextQueued {
                await processJob(job)
                if Task.isCancelled { break }
            }
        }
    }

    /// Cancel a specific job. Running → propagates Task.cancel into the
    /// pipeline; queued → just marks as cancelled and the runner skips
    /// it on the next pass.
    func cancel(jobID: UUID) {
        if currentJobID == jobID {
            // Immediate UI feedback — pipeline may take seconds to
            // catch up. Cleared in `processJob` when the task ends.
            cancellingJobIDs.insert(jobID)
            currentJobTask?.cancel()
        } else {
            store.update(jobID) { job in
                if job.status == .queued {
                    job.status = .cancelled
                    job.finishedAt = Date()
                }
            }
        }
    }

    /// Bulk cancel — used by Cancel All / Pause Queue actions.
    func cancelAll() {
        if let id = currentJobID {
            cancellingJobIDs.insert(id)
        }
        currentJobTask?.cancel()
        for job in store.jobs where job.status == .queued {
            store.update(job.id) { mutable in
                mutable.status = .cancelled
                mutable.finishedAt = Date()
            }
        }
    }

    /// Move a finished/cancelled job back to `.queued` so the runner
    /// re-attempts it. Called from the per-job Retry button.
    func retry(jobID: UUID) {
        store.update(jobID) { job in
            job.status = .queued
            job.error = nil
            job.progress = nil
            job.startedAt = nil
            job.finishedAt = nil
        }
        start()
    }

    // MARK: - job execution

    private func processJob(_ job: Job) async {
        currentJobID = job.id
        store.update(job.id) { mutable in
            mutable.status = .running
            mutable.startedAt = Date()
            mutable.error = nil
            mutable.progress = nil
        }

        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPipeline(for: job)
        }
        currentJobTask = task
        await task.value
        currentJobTask = nil
        currentJobID = nil
        cancellingJobIDs.remove(job.id)
    }

    private func runPipeline(for job: Job) async {
        let pipeline = PDFToEPUBPipeline()
        let languages = job.options.languages.map { BCP47($0) }
        // Read the user's current AI processing mode + per-feature
        // toggles + cost cap at job-start time. Per-book overrides
        // are deferred (Phase 8 in the migration plan); the global
        // setting applies to every queued conversion.
        let aiSettings = AISettingsStore().load()
        let keyStore = AnthropicAPIKeyStore()
        let options = PDFToEPUBPipeline.Options(
            languages: languages,
            useHighAccuracyOCR: job.options.useHighAccuracyOCR,
            processingMode: aiSettings.processingMode,
            cloudFeatures: aiSettings.cloudFeatures,
            perBookCallCap: aiSettings.perBookCallCap,
            // Closure (not a captured string) so a key rotation in
            // Settings UI takes effect on the next request without
            // rebuilding the pipeline.
            anthropicAPIKeyProvider: { keyStore.read() }
        )
        let storeRef = store
        let jobID = job.id
        do {
            try await pipeline.convert(
                pdfURL: job.sourceURL,
                outputURL: job.outputURL,
                options: options,
                progress: { p in
                    Task { @MainActor in
                        storeRef.update(jobID) { mutable in
                            mutable.progress = JobProgress(
                                completedPages: p.completedPages,
                                totalPages: p.totalPages
                            )
                        }
                    }
                }
            )
            store.update(jobID) { mutable in
                mutable.status = .done
                mutable.finishedAt = Date()
            }
        } catch is CancellationError {
            store.update(jobID) { mutable in
                mutable.status = .cancelled
                mutable.finishedAt = Date()
            }
        } catch {
            store.update(jobID) { mutable in
                mutable.status = .failed
                mutable.error = error.localizedDescription
                mutable.finishedAt = Date()
            }
        }
    }
}
