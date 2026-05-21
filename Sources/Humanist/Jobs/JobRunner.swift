import Foundation
import AI
import Document
import EPUB
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
    /// Library catalog. When non-nil, successful conversions are
    /// recorded here so the Library window can list them. Optional
    /// so test fixtures (which exercise pause/resume + state
    /// machinery) don't have to plumb a real library through.
    let library: LibraryStore?

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

    init(
        store: JobStore,
        library: LibraryStore? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.library = library
        self.defaults = defaults
        // Two paths to a paused launch state:
        //   * Session pause: the user hit Pause last session,
        //     `pausedKey` is true. Round-trip the choice.
        //   * Persistent preference: "Start paused on launch" is on
        //     in Settings. Override the session state so every
        //     launch begins paused, regardless of how the user
        //     left the queue last time. Persist the resulting
        //     pause back into `pausedKey` so the rest of the
        //     runner (pause()/resume()) keeps a single source of
        //     truth.
        let sessionPause = defaults.bool(forKey: Self.pausedKey)
        let startPausedPref = defaults.bool(forKey: ConversionSettingsKeys.startPausedOnLaunch)
        let initialPause = sessionPause || startPausedPref
        self.isPaused = initialPause
        if startPausedPref, !sessionPause {
            defaults.set(true, forKey: Self.pausedKey)
        }
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
        // Branch by source extension. Non-PDF text-based formats
        // (TXT / MD / RTF) go through DocumentIngest — no OCR, no
        // rasterization, no Claude calls. PDFs continue down the
        // OCR pipeline.
        if DocumentIngest.isSupported(job.sourceURL) {
            await runDocumentIngest(for: job)
            return
        }
        // R-Library-Dedupe content-hash pre-flight. Hash the
        // source PDF and check against the catalog's recorded
        // source hashes. On a match, flip the job to .done with
        // `skippedReason` set; the queue UI renders that in place
        // of stats, no OCR runs, no EPUB gets written, and the
        // existing catalog row is reused (Open / Reveal point at
        // the canonical EPUB). Pre-feature catalogs have empty
        // `sourceContentHashes`, so this only fires after a
        // conversion has stamped a hash — exactly the scenarios
        // the user runs into when they re-drop the same PDF.
        //
        // Returns the computed hash on the no-dedupe path so the
        // claim step below can reuse it — hashing once is enough.
        let (dedupeHit, sourceHash) = await runDedupeShortCircuitWithHash(for: job)
        if dedupeHit { return }

        // R-Library-Rescan: rename the existing EPUB to
        // `<basename>.bak.epub` before the pipeline overwrites
        // it. Cheap rollback — if the new conversion is worse
        // than the original, the user can pull the .bak.epub
        // back manually. The backup overwrites any previous
        // .bak.epub (one rollback level — multi-level history
        // would be a UX problem to design, not implement). No-op
        // when the destination doesn't exist or when this isn't
        // a rescan job.
        if job.options.bypassDedupe {
            makeRescanBackup(of: job.outputURL)
        }

        // Multi-Mac claim pre-flight. When a peer Mac sharing the
        // catalog is already converting this exact source, stamp
        // the job as skipped and bail without running the pipeline.
        // The claim *itself* is recorded by `tryClaimForJob` so
        // peers see our reservation; release happens unconditionally
        // via `defer` below so a crash / cancel / failure doesn't
        // strand the claim.
        var claimedHash: String?
        if let hash = sourceHash,
           await tryClaimForJob(job, sourceHash: hash) {
            claimedHash = hash
        } else if sourceHash != nil {
            // tryClaimForJob already updated the job to .done with
            // the "being converted by <host>" skippedReason. We're
            // done.
            return
        }
        // sourceHash == nil means hashing failed (file moved/locked
        // mid-flight). Proceed without claim; worst case is the
        // dedupe short-circuit catches a peer's conversion after
        // the catalog syncs.
        defer {
            if let claimedHash {
                library?.releaseClaim(
                    hash: claimedHash, hostName: Self.localHostName
                )
            }
        }
        let pipeline = PDFToEPUBPipeline()
        let languages = job.options.languages.map { BCP47($0) }
        // Read the user's current AI processing mode + per-feature
        // toggles + cost cap at job-start time. Per-book overrides
        // are deferred (Phase 8 in the migration plan); the global
        // setting applies to every queued conversion.
        let aiSettings = AISettingsStore().load()
        let keyStore = AnthropicAPIKeyStore()
        let geminiKeyStore = GeminiAPIKeyStore()
        let googleCloudVisionKeyStore = GoogleCloudVisionAPIKeyStore()
        let landingAIKeyStore = LandingAIAPIKeyStore()
        // Private Mode override: zero out every cloud surface for
        // this conversion regardless of global Settings. Empty
        // `CloudFeatures` makes every `make*ClaudeX` factory return
        // nil; the nil-returning key provider is belt-and-suspenders
        // (factories also gate on a non-empty key). `useClaudePageOCR`
        // is coerced off since it only fires under Cloud mode + key.
        let privateOn = job.options.privateMode
        var cloudFeatures: AISettings.CloudFeatures =
            privateOn ? AISettings.CloudFeatures() : aiSettings.cloudFeatures
        // Per-job Batch API flag. Seeded in the launcher from the
        // user's Settings default; the launcher toggle can flip it
        // per-session. Skipped in private mode — no Cloud calls
        // means nothing to batch.
        if !privateOn {
            cloudFeatures.useBatchAPI = job.options.useBatchAPI
        }
        // The user-visible "Claude OCR ($$$)" toggle drives the
        // end-to-end page-OCR path (one Sonnet call per page,
        // structured XHTML in, [Block] out). The legacy cascade-
        // Sonnet shortcut path (`useCloudEnhancedOCR` on the
        // pipeline Options struct) is no longer reachable from the
        // UI — pass `false` so the cascade doesn't fire even when
        // cloud features are enabled. The cascade implementation
        // stays in the pipeline for SpikeRunner / dev measurement.
        let claudePageOCR = !privateOn && (
            job.options.useClaudePageOCR
            || UserDefaults.standard.bool(forKey: "humanist.useClaudePageOCR")
        )
        let cloudEnhancedOCR = false
        let keyProvider: @Sendable () -> String?
        let geminiKeyProvider: @Sendable () -> String?
        let googleCloudVisionKeyProvider: @Sendable () -> String?
        let landingAIKeyProvider: @Sendable () -> String?
        if privateOn {
            keyProvider = { nil }
            geminiKeyProvider = { nil }
            googleCloudVisionKeyProvider = { nil }
            landingAIKeyProvider = { nil }
        } else {
            keyProvider = { keyStore.read() }
            geminiKeyProvider = { geminiKeyStore.read() }
            googleCloudVisionKeyProvider = { googleCloudVisionKeyStore.read() }
            landingAIKeyProvider = { landingAIKeyStore.read() }
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
            localFeatures: aiSettings.localFeatures,
            perBookCallCap: aiSettings.perBookCallCap,
            // Closure (not a captured string) so a key rotation in
            // Settings UI takes effect on the next request without
            // rebuilding the pipeline.
            anthropicAPIKeyProvider: keyProvider,
            geminiAPIKeyProvider: geminiKeyProvider,
            googleCloudVisionAPIKeyProvider: googleCloudVisionKeyProvider,
            landingAIAPIKeyProvider: landingAIKeyProvider,
            // Per-job override wins when the launcher picked a
            // specific provider (e.g. "Gemini OCR — Typeset" from
            // the OCR Engine picker); otherwise fall back to the
            // user's Settings → AI default.
            pageOCRProvider: job.options.pageOCRProvider
                ?? aiSettings.pageOCRProvider,
            useClaudePageOCR: claudePageOCR,
            useManuscriptMode: !job.options.privateMode
                && job.options.useManuscriptMode,
            manuscriptHand: job.options.manuscriptHand,
            useEarlyPrintMode: !job.options.privateMode
                && job.options.useEarlyPrintMode,
            earlyPrintTypeface: job.options.earlyPrintTypeface,
            emitSiblingTextOutputs: job.options.emitSiblingTextOutputs,
            emitSiblingDocuments: job.options.emitSiblingDocuments,
            forceOCRPageRanges: PageRangeParser.parse(
                job.options.forceOCRPageRangesString
            ),
            siblingTextURLOverride: ConversionOutputResolver
                .siblingTextOverrides(
                    forSource: job.sourceURL,
                    suffix: job.options.outputSuffix
                ).txt,
            siblingMarkdownURLOverride: ConversionOutputResolver
                .siblingTextOverrides(
                    forSource: job.sourceURL,
                    suffix: job.options.outputSuffix
                ).md,
            siblingHTMLURLOverride: ConversionOutputResolver
                .siblingDocumentOverrides(
                    forSource: job.sourceURL,
                    suffix: job.options.outputSuffix
                ).html,
            siblingDOCXURLOverride: ConversionOutputResolver
                .siblingDocumentOverrides(
                    forSource: job.sourceURL,
                    suffix: job.options.outputSuffix
                ).docx,
            // Tier 9 / V-PDF-Searchable: forwards both the toggle
            // and the configured-output-folder routing.
            emitSearchablePDF: job.options.emitSearchablePDF,
            searchablePDFURLOverride: ConversionOutputResolver
                .searchablePDFOutputURL(
                    forSource: job.sourceURL,
                    suffix: job.options.outputSuffix
                ),
            // Same idea for the debug staging dir → <root>/Logs/.
            // Only honored when emitDebugLog is on; otherwise the
            // pipeline keeps the resume-friendly next-to-source-PDF
            // location.
            debugStagingURLOverride: ConversionOutputResolver
                .debugStagingURL(
                    forSource: job.sourceURL,
                    suffix: job.options.outputSuffix
                ),
            forceBilingualFacingPage: job.options.forceBilingualFacingPage
        )
        let storeRef = store
        let jobID = job.id
        do {
            let stats = try await pipeline.convert(
                pdfURL: job.sourceURL,
                outputURL: job.outputURL,
                options: options,
                progress: { p in
                    let mapped: JobProgress.Phase = switch p.phase {
                    case .processing:   .processing
                    case .batchWaiting: .batchWaiting
                    }
                    Task { @MainActor in
                        storeRef.update(jobID) { mutable in
                            mutable.progress = JobProgress(
                                completedPages: p.completedPages,
                                totalPages: p.totalPages,
                                phase: mapped
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
            // R-Library: record the successful conversion in the
            // library catalog so the Library window surfaces it.
            // Title falls back to the source PDF's basename — a
            // future iteration can read the actual book title from
            // the OPF metadata.
            //
            // R-Auto-Collections Phase 1: stamp the conversionType
            // so the auto-collection generator can bucket by Type
            // without re-deriving provenance from job options.
            // Manuscript wins over Early Print which wins over the
            // plain Print path — same priority order the engine
            // factory uses.
            let convType: BookConversionType = {
                if job.options.useManuscriptMode { return .manuscript }
                if job.options.useEarlyPrintMode { return .earlyPrint }
                return .print
            }()
            // R-Library-Rescan: on a rescan, the entry already
            // exists at `outputURL` and the user may have edited
            // the title via the metadata editor since the original
            // conversion. Preserve their edits by passing the
            // existing title back to `recordConversion` instead of
            // re-deriving from the source filename. Fresh
            // conversions take the filename-derived path.
            let recordedTitle: String
            if job.options.bypassDedupe,
               let existing = library?.entries.first(where: {
                   $0.epubURL.canonicalForFile == job.outputURL.canonicalForFile
               }) {
                recordedTitle = existing.title
            } else {
                recordedTitle = job.sourceURL
                    .deletingPathExtension().lastPathComponent
            }
            library?.recordConversion(
                epubURL: job.outputURL,
                title: recordedTitle,
                languages: job.options.languages,
                conversionType: convType
            )
            // R-Library-Dedupe. Stamp the source PDF's content
            // hash onto the freshly-created row so a future re-
            // drop hits the pre-flight short-circuit. Hashing
            // happens off the main actor; failures are silent
            // (worst case: the next drop re-runs OCR, which is
            // wasteful but not incorrect). Hash is also reused
            // by the consolidation step below — pass it through
            // to avoid hashing the same file twice.
            var stampedSourceHash: String?
            if let lib = library {
                let sourceURL = job.sourceURL
                let hashTask = Task.detached(priority: .background) {
                    try ContentHash.sha256(of: sourceURL)
                }
                if let hash = try? await hashTask.value {
                    stampedSourceHash = hash
                    let outputURL = job.outputURL
                    await MainActor.run {
                        let canonical = outputURL.canonicalForFile
                        if let entryID = lib.entries.first(where: {
                            $0.epubURL.canonicalForFile == canonical
                        })?.id {
                            lib.recordSourceHash(hash, on: entryID)
                        }
                    }
                }
            }

            // R-PDFs-Consolidation. Move the source PDF out of
            // `Input/` (or copy from anywhere else) into
            // `<outputRoot>/PDFs/` and update the EPUB sidecar to
            // reference the new location. No-op when no output
            // root is configured. Failures are non-fatal — the
            // EPUB is already written and the catalog is already
            // stamped; a consolidation failure just leaves the
            // sidecar pointing at the source's original location
            // (or, in the file-op-succeeded-but-sidecar-failed
            // edge case, at a path the editor's resolveSourcePDF
            // fallback won't find — File → Consolidate PDFs Into
            // Library Folder… is the recovery path).
            let consolidationSource = job.sourceURL
            let consolidationOutput = job.outputURL
            let consolidationHash = stampedSourceHash
            let consolidationLib = library
            do {
                let plan = PDFConsolidator.plan(
                    sourcePDF: consolidationSource,
                    sourceHash: consolidationHash
                )
                try PDFConsolidator.execute(plan)
                if let target = plan.targetPDFURL, plan.willMutate {
                    try PDFConsolidator.writeSidecar(
                        intoEPUB: consolidationOutput,
                        pointingAt: target
                    )
                }
                // Input-rooted duplicate-content case: execute()
                // doesn't carry the source URL through the
                // .linkToExistingDuplicate action, so clean up
                // here. The user's intent ("clear Input") still
                // applies even though the consolidated copy was
                // already present at the target.
                if case .linkToExistingDuplicate = plan.action,
                   ConversionOutputResolver.isInsideInputFolder(
                       consolidationSource
                   ) {
                    try? FileManager.default.removeItem(
                        at: consolidationSource
                    )
                    // Update sidecar to point at the existing
                    // duplicate so future opens find it via the
                    // sidecar's `as-is` resolution step.
                    if let target = plan.targetPDFURL {
                        try? PDFConsolidator.writeSidecar(
                            intoEPUB: consolidationOutput,
                            pointingAt: target
                        )
                    }
                }
                // R-PDFs-Consolidation cache: stamp the resolved
                // path onto the library entry so the migrate
                // command skips unpacking on subsequent runs.
                // Hop to the main actor for the store mutation —
                // LibraryStore.recordLinkedSourcePDF is
                // @MainActor like the rest of the store API.
                if let target = plan.targetPDFURL {
                    let cachedPath = target.canonicalForFile.path
                    let outputURL = consolidationOutput
                    await MainActor.run {
                        consolidationLib?.recordLinkedSourcePDF(
                            cachedPath, forEPUB: outputURL
                        )
                    }
                }
            } catch {
                NSLog(
                    "Humanist: PDF consolidation failed for %@: %@",
                    consolidationSource.lastPathComponent,
                    error.localizedDescription
                )
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

    /// R-Library-Dedupe pre-flight. Hashes `job.sourceURL` and
    /// short-circuits the conversion when an existing catalog row
    /// already records the same source hash. On a hit, the job is
    /// transitioned to `.done` with `skippedReason` set, its
    /// `outputURL` updated to point at the existing entry's EPUB
    /// (so Open / Reveal target the canonical copy), and the
    /// source path is appended to the entry's `priorPaths`.
    ///
    /// Returns `(true, hash)` when the short-circuit fired,
    /// `(false, hash)` when the conversion should proceed, and
    /// `(false, nil)` when hashing failed (caller proceeds without
    /// a claim — the in-flight protection degrades to "no
    /// coordination across Macs for this job"). The hash is plumbed
    /// to the caller so the claim step doesn't re-hash the same
    /// file.
    private func runDedupeShortCircuitWithHash(for job: Job) async -> (hit: Bool, hash: String?) {
        guard let library else { return (false, nil) }
        let sourceURL = job.sourceURL
        let hashTask = Task.detached(priority: .userInitiated) {
            try ContentHash.sha256(of: sourceURL)
        }
        guard let hash = try? await hashTask.value else { return (false, nil) }
        // R-Library-Rescan: user explicitly requested a re-run of
        // the OCR pipeline against an already-cataloged source.
        // Compute the hash so the success path can still record it
        // on the (updated) entry, but skip the catalog-match
        // short-circuit so the pipeline actually runs.
        if job.options.bypassDedupe { return (false, hash) }
        let sourcePath = job.sourceURL.path
        let dupe: LibraryEntry? = await MainActor.run {
            guard let match = library.findEntryBySourceHash(hash)
            else { return nil }
            library.addPriorPath(sourcePath, to: match.id)
            return match
        }
        guard let dupe else { return (false, hash) }
        let jobID = job.id
        let canonicalURL = dupe.epubURL
        let title = dupe.title
        store.update(jobID) { mutable in
            mutable.status = .done
            mutable.finishedAt = Date()
            mutable.outputURL = canonicalURL
            mutable.skippedReason = "Already in library: \(title)"
            mutable.progress = nil
        }
        return (true, hash)
    }

    /// Attempt to claim `sourceHash` for the local Mac. Returns
    /// true when the claim was taken (caller proceeds and the
    /// `defer`d release fires on every exit path). Returns false
    /// when a peer Mac holds a fresh claim; in that case the job
    /// is updated to `.done` with a "being converted by <host>"
    /// skippedReason and the caller bails. No-op (returns true)
    /// when no library is attached — tests and standalone usage
    /// shouldn't have to set up a real catalog to exercise the
    /// runner.
    private func tryClaimForJob(_ job: Job, sourceHash: String) async -> Bool {
        guard let library else { return true }
        let hostName = Self.localHostName
        let result = library.tryClaim(hash: sourceHash, hostName: hostName)
        switch result {
        case .claimed:
            return true
        case .heldByOther(let marker):
            store.update(job.id) { mutable in
                mutable.status = .done
                mutable.finishedAt = Date()
                mutable.skippedReason = "Being converted by \(marker.hostName)"
                mutable.progress = nil
            }
            return false
        }
    }

    /// Friendly device name shown to peers in the "being converted
    /// by <host>" skippedReason. Falls back to the FQDN when the
    /// localized name isn't available — better than nothing.
    static var localHostName: String {
        Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
    }

    /// R-Library-Rescan. Snapshot the existing EPUB at
    /// `<basename>.bak.epub` before the pipeline overwrites it.
    /// Best-effort: a failed rename falls through (the rescan
    /// will still run; the user just loses the rollback safety
    /// net). Any prior .bak.epub is overwritten — one rollback
    /// level only.
    private func makeRescanBackup(of epubURL: URL) {
        guard FileManager.default.fileExists(atPath: epubURL.path) else {
            return
        }
        let backupURL = epubURL
            .deletingPathExtension()
            .appendingPathExtension("bak.epub")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: epubURL, to: backupURL)
    }

    /// Non-PDF text input → EPUB. Bypasses the OCR pipeline entirely:
    /// `DocumentIngest` builds the `Book` IR directly from the
    /// source file, then `EPUBBuilder` writes it out using the same
    /// machinery the PDF pipeline finishes with.
    private func runDocumentIngest(for job: Job) async {
        let jobID = job.id
        let storeRef = store
        let langID = job.options.languages.first ?? "en"
        let language = BCP47(langID)
        // Make sure the output directory exists — the user may have
        // configured a fresh root with no `Books/` subfolder yet.
        let outputDir = job.outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true
        )
        let sourceURL = job.sourceURL
        let outputURL = job.outputURL
        let emitText = job.options.emitSiblingTextOutputs
        let emitDocs = job.options.emitSiblingDocuments
        let suffix = job.options.outputSuffix
        let txtURL = ConversionOutputResolver
            .siblingTextOverrides(forSource: sourceURL, suffix: suffix).txt
            ?? outputURL.deletingPathExtension().appendingPathExtension("txt")
        let mdURL = ConversionOutputResolver
            .siblingTextOverrides(forSource: sourceURL, suffix: suffix).md
            ?? outputURL.deletingPathExtension().appendingPathExtension("md")
        let htmlURL = ConversionOutputResolver
            .siblingDocumentOverrides(forSource: sourceURL, suffix: suffix).html
            ?? outputURL.deletingPathExtension().appendingPathExtension("html")
        let docxURL = ConversionOutputResolver
            .siblingDocumentOverrides(forSource: sourceURL, suffix: suffix).docx
            ?? outputURL.deletingPathExtension().appendingPathExtension("docx")
        do {
            let book = try await Task.detached(priority: .userInitiated) {
                try DocumentIngest().ingest(from: sourceURL, language: language)
            }.value
            try await Task.detached(priority: .userInitiated) {
                try EPUBBuilder().write(
                    book: book,
                    sourcePDFURL: sourceURL,
                    to: outputURL
                )
                if emitText {
                    for url in [txtURL, mdURL] {
                        try? FileManager.default.createDirectory(
                            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                        )
                    }
                    try? PlainTextWriter.render(book).write(to: txtURL, atomically: true, encoding: .utf8)
                    try? MarkdownWriter.render(book).write(to: mdURL, atomically: true, encoding: .utf8)
                }
                if emitDocs {
                    for url in [htmlURL, docxURL] {
                        try? FileManager.default.createDirectory(
                            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                        )
                    }
                    try? HTMLWriter.render(book).write(to: htmlURL, atomically: true, encoding: .utf8)
                    try? DOCXWriter.write(book, to: docxURL)
                }
            }.value
            store.update(jobID) { mutable in
                mutable.status = .done
                mutable.finishedAt = Date()
                mutable.progress = JobProgress(completedPages: 1, totalPages: 1)
            }
            // R-Auto-Collections Phase 1: document-ingest path
            // (txt / md / rtf / docx / odt / html → EPUB) is by
            // definition a born-digital source — no scan, no OCR.
            // Stamp as .digital.
            library?.recordConversion(
                epubURL: outputURL,
                title: book.title,
                languages: job.options.languages,
                conversionType: .digital,
                author: book.author
            )
            _ = storeRef
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
