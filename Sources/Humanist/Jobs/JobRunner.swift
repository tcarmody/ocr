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
    /// `true` when the user has paused the queue. Soft-pause: the
    /// currently-running job (if any) finishes; the loop then exits
    /// and won't pick up further `.queued` jobs until `resume()`.
    /// Persisted via `UserDefaults` so a "I'll come back to this"
    /// pause survives app restart.
    @Published private(set) var isPaused: Bool
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
    /// `UserDefaults` instance backing the persisted-pause flag. Test
    /// seam — production passes `.standard`; tests pass an isolated
    /// suite so they can assert on persistence without polluting the
    /// app's defaults.
    private let defaults: UserDefaults

    /// Persistence key for `isPaused`. App-scoped so it round-trips
    /// across launches; cleared on first run by `removeObject` since
    /// `bool(forKey:)` returns `false` when missing — that's the
    /// right default ("not paused").
    static let pausedKey = "humanist.queuePaused"

    init(store: JobStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.isPaused = defaults.bool(forKey: Self.pausedKey)
    }

    /// Kick off the loop if nothing is in flight. Safe to call after
    /// every add — no-op when already running, and no-op when the
    /// queue is paused (the user has explicitly told us to hold off).
    func start() {
        guard !isPaused else { return }
        guard loopTask == nil else { return }
        loopTask = Task { @MainActor in
            isRunning = true
            defer {
                isRunning = false
                loopTask = nil
            }
            while let job = store.nextQueued {
                // Soft-pause check between jobs: lets a long Surya
                // run finish gracefully rather than mid-page-cancel,
                // then exits the loop until `resume()`.
                if isPaused { break }
                await processJob(job)
                if Task.isCancelled { break }
            }
        }
    }

    /// User-initiated pause. The currently-running job (if any)
    /// finishes; subsequent `.queued` jobs stay queued until
    /// `resume()`. Persists across launches.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        defaults.set(true, forKey: Self.pausedKey)
    }

    /// Clear the pause flag and re-enter the run loop. No-op when
    /// not paused. Always calls `start()`; if there's nothing
    /// queued, that's a cheap no-op of its own.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        defaults.set(false, forKey: Self.pausedKey)
        start()
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
        // Private Mode override: zero out every cloud surface for
        // this conversion regardless of global Settings. Empty
        // `CloudFeatures` makes every `make*ClaudeX` factory return
        // nil; the nil-returning key provider is belt-and-suspenders
        // (factories also gate on a non-empty key). `useCloudEnhancedOCR`
        // is coerced off since it only fires under Cloud mode + key.
        let privateOn = job.options.privateMode
        let cloudFeatures: AISettings.CloudFeatures =
            privateOn ? AISettings.CloudFeatures() : aiSettings.cloudFeatures
        // Phase 3: the user-visible "Claude OCR ($$$)" toggle now
        // drives the end-to-end page-OCR path (one Sonnet call per
        // page, structured XHTML in, [Block] out). The legacy
        // cascade-Sonnet shortcut path (Vision → Sonnet escalation
        // for low-quality regions only) is no longer reachable from
        // the UI — pass `useCloudEnhancedOCR: false` to the pipeline
        // so the cascade doesn't fire even when cloud features are
        // enabled. The cascade implementation stays available for
        // SpikeRunner / dev measurement; users get the simpler,
        // higher-quality page-OCR experience.
        let claudePageOCR = !privateOn && (
            job.options.useCloudEnhancedOCR
            || UserDefaults.standard.bool(forKey: "humanist.useClaudePageOCR")
        )
        let cloudEnhancedOCR = false
        let keyProvider: @Sendable () -> String?
        if privateOn {
            keyProvider = { nil }
        } else {
            keyProvider = { keyStore.read() }
        }
        let options = PDFToEPUBPipeline.Options(
            documentProfile: job.profile,
            languages: languages,
            emitDebugLog: job.options.emitDebugLog,
            useHighAccuracyOCR: job.options.useSuryaOCR,
            useCloudEnhancedOCR: cloudEnhancedOCR,
            forceOCR: job.options.forceOCR,
            processingMode: aiSettings.processingMode,
            cloudFeatures: cloudFeatures,
            perBookCallCap: aiSettings.perBookCallCap,
            // Closure (not a captured string) so a key rotation in
            // Settings UI takes effect on the next request without
            // rebuilding the pipeline.
            anthropicAPIKeyProvider: keyProvider,
            useClaudePageOCR: claudePageOCR
        )
        let storeRef = store
        let jobID = job.id
        do {
            let stats = try await pipeline.convert(
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
                mutable.stats = stats
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
