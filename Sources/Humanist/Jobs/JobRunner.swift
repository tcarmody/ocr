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
        if await runDedupeShortCircuit(for: job) {
            return
        }
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
        // (factories also gate on a non-empty key). `useClaudePageOCR`
        // is coerced off since it only fires under Cloud mode + key.
        let privateOn = job.options.privateMode
        let cloudFeatures: AISettings.CloudFeatures =
            privateOn ? AISettings.CloudFeatures() : aiSettings.cloudFeatures
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
            localFeatures: aiSettings.localFeatures,
            perBookCallCap: aiSettings.perBookCallCap,
            // Closure (not a captured string) so a key rotation in
            // Settings UI takes effect on the next request without
            // rebuilding the pipeline.
            anthropicAPIKeyProvider: keyProvider,
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
                )
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
            library?.recordConversion(
                epubURL: job.outputURL,
                title: job.sourceURL.deletingPathExtension().lastPathComponent,
                languages: job.options.languages,
                conversionType: convType
            )
            // R-Library-Dedupe. Stamp the source PDF's content
            // hash onto the freshly-created row so a future re-
            // drop hits the pre-flight short-circuit. Hashing
            // happens off the main actor; failures are silent
            // (worst case: the next drop re-runs OCR, which is
            // wasteful but not incorrect).
            if let lib = library {
                let sourceURL = job.sourceURL
                let hashTask = Task.detached(priority: .background) {
                    try ContentHash.sha256(of: sourceURL)
                }
                if let hash = try? await hashTask.value {
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
    /// source path is appended to the entry's `priorPaths`. Returns
    /// true when the short-circuit fired and the caller should bail
    /// out without running the pipeline.
    private func runDedupeShortCircuit(for job: Job) async -> Bool {
        guard let library else { return false }
        let sourceURL = job.sourceURL
        let hashTask = Task.detached(priority: .userInitiated) {
            try ContentHash.sha256(of: sourceURL)
        }
        guard let hash = try? await hashTask.value else { return false }
        let sourcePath = job.sourceURL.path
        let dupe: LibraryEntry? = await MainActor.run {
            guard let match = library.findEntryBySourceHash(hash)
            else { return nil }
            library.addPriorPath(sourcePath, to: match.id)
            return match
        }
        guard let dupe else { return false }
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
        return true
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
