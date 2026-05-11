import Foundation
import AppKit
import UniformTypeIdentifiers
import AI
import Document
import OCR
import PDFIngest
import Pipeline

/// View-side wrapper around the queue. Owns the option pickers
/// (language, high-accuracy) so the launcher window can render them
/// the same way the old single-PDF flow did, and adds enqueue helpers
/// for "drop one PDF" vs. "drop a folder of PDFs."
@MainActor
final class QueueViewModel: ObservableObject {
    /// User-facing language choice. Identical shape to what the old
    /// `ConversionViewModel` used so the picker UI didn't have to
    /// change.
    struct LanguageOption: Identifiable, Hashable, Sendable {
        let id: String
        let language: BCP47
        let label: String
        init(_ language: BCP47, _ label: String) {
            self.id = language.rawValue
            self.language = language
            self.label = label
        }
    }

    /// Truly immutable static data — Swift 6 lets us read it from
    /// any actor without isolation hops. Required because the
    /// detached profiling Task reads it off-main-actor.
    nonisolated static let supportedLanguages: [LanguageOption] = [
        .init(.en,         "English"),
        .init(.fr,         "French"),
        .init(.de,         "German"),
        .init(.it,         "Italian"),
        .init(.es,         "Spanish"),
        .init(.grc,        "Ancient Greek (polytonic)"),
        .init(.la,         "Latin"),
        .init("he",        "Hebrew"),
        .init("ar",        "Arabic"),
        .init("ru",        "Russian"),
    ]

    @Published var selectedLanguageIds: Set<String> = ["en"]
    /// "Use Surya OCR (local-only, slower)" toggle in the launcher.
    /// Forces Surya to run OCR on every region, bypassing the
    /// per-region cascade. Was previously called `useHighAccuracyOCR`
    /// — renamed to make the engine explicit now that there's also
    /// a Cloud-enhanced toggle.
    @Published var useSuryaOCR: Bool = false
    /// "Claude OCR ($$$)" toggle. Drives the end-to-end page-OCR
    /// path: one Sonnet call per page in, structured XHTML →
    /// `[Block]` out. Bypasses the Vision / Surya / Tesseract
    /// cascade entirely; Surya layout still runs for figures /
    /// tables. Only fires when the conversion is in Cloud mode
    /// with a configured API key — the toggle is allowed to be on
    /// in any mode but produces no Sonnet calls when those gates
    /// aren't met.
    @Published var useClaudePageOCR: Bool = false
    /// E-Vision-Modes / Manuscript track. When true, page OCR
    /// routes to Claude Opus 4.7 with a hand-family-specific
    /// prompt (see `manuscriptHand`). Mutually exclusive with
    /// `useClaudePageOCR` at the UI layer — the engine factory
    /// also lets manuscript win when both are set, but the
    /// launcher shouldn't let a user check both at once.
    /// Per-session toggle: snapshotted into `Job.options` at
    /// enqueue time; not persisted to Settings (manuscript is the
    /// exception, not the routine).
    @Published var useManuscriptMode: Bool = false
    /// Selected hand family for manuscript mode. Defaults to
    /// `.auto` — the model identifies the hand and transcribes
    /// accordingly. Specific cases (diplomatic / roundHand /
    /// cursive / contemporaryInformal) load a tuned prompt.
    @Published var manuscriptHand: ManuscriptHand = .auto
    /// Force-OCR override for new conversions in this session.
    /// Promoted from Settings to a launcher toggle since it's
    /// inherently per-conversion (some PDFs need it; most don't).
    @Published var forceOCR: Bool = false
    /// "Private Mode" override. When true, queueing a conversion
    /// disables every cloud feature for that job regardless of the
    /// global Settings — `cloudFeatures` is forced to all-off and
    /// the API-key provider returns nil in `JobRunner`. Useful for
    /// one-off privacy-sensitive runs without flipping global
    /// settings. Per-conversion: snapshotted into `Job.options` at
    /// enqueue time so a mid-batch toggle doesn't retroactively
    /// affect already-queued jobs.
    @Published var privateMode: Bool = false
    /// "Save log" toggle. When on, the pipeline keeps the staging
    /// directory after a successful conversion and writes a
    /// per-page diagnostic log next to the EPUB (under
    /// `<basename>.humanist-debug/`) — useful for investigating
    /// reflow / classification issues. Off by default to avoid
    /// leaving 50–100MB of artifacts next to every PDF.
    @Published var emitDebugLog: Bool = false
    /// Tier 9 / V-Outputs. When on (default), the pipeline writes
    /// Write `.txt` and `.md` siblings. Cheap; default on.
    @Published var emitSiblingTextOutputs: Bool = true
    /// Write `.html` and `.docx` siblings. Heavier; default off.
    @Published var emitSiblingDocuments: Bool = false
    /// Tier 9 / V-Trust-PerPage. User-typed page-range string —
    /// 1-based, comma-separated, with `N-M` ranges
    /// (e.g. "1-20, 150-160"). Pages in any range bypass the
    /// embedded-text trust path and force OCR. Empty = no per-page
    /// override. Snapshotted into ConversionOptions at queue-add.
    @Published var forceOCRPageRangesString: String = ""
    /// Optional output filename suffix. When non-empty, every
    /// output (EPUB, sibling .txt / .md, debug staging dir) gets
    /// "<basename> <suffix>" instead of just "<basename>". Lets
    /// the user run the same source PDF through different settings
    /// and have both outputs land side-by-side for A/B comparison
    /// via Tools → Compare EPUBs. Empty = original behavior.
    /// Snapshotted into ConversionOptions at queue-add.
    @Published var outputSuffix: String = ""
    /// Tier 9 / V-PDF-Searchable. When on, the conversion writes a
    /// searchable copy of the source PDF (`<basename>.searchable.pdf`)
    /// next to the EPUB. Off by default — most users only need the
    /// EPUB and the file is several MB per book.
    @Published var emitSearchablePDF: Bool = false

    let store: JobStore
    let runner: JobRunner
    /// True when the Tesseract binary was found on init. Drives the
    /// "Tesseract not installed" badge in the picker row.
    let tesseractAvailable: Bool

    init(store: JobStore, runner: JobRunner) {
        self.store = store
        self.runner = runner
        self.tesseractAvailable = (TesseractOCREngine.detect() != nil)
        // Seed the launcher's per-conversion toggles from Settings
        // → Conversion → Defaults. Per-session overrides made in
        // the launcher UI don't persist back; the next launch
        // reads these Settings values again. This is intentional:
        // "Settings defaults, launcher overrides" matches the user
        // mental model that a per-job tweak shouldn't quietly
        // mutate their long-term preferences.
        let defaults = ConversionDefaults.current()
        self.useSuryaOCR = defaults.useSuryaOCR
        self.useClaudePageOCR = defaults.useClaudePageOCR
        self.forceOCR = defaults.forceOCR
        self.privateMode = defaults.privateMode
        self.emitDebugLog = defaults.emitDebugLog
        self.emitSiblingTextOutputs = defaults.emitSiblingTextOutputs
        self.emitSiblingDocuments = defaults.emitSiblingDocuments
        self.emitSearchablePDF = defaults.emitSearchablePDF
        // If a previous session left work in the queue, pick it up
        // automatically on launch.
        if store.hasPendingWork {
            runner.start()
        }
    }

    // MARK: - language picker mirror (same logic as ConversionViewModel)

    var selectedLanguages: [BCP47] {
        let selected = Self.supportedLanguages
            .filter { selectedLanguageIds.contains($0.id) }
            .map(\.language)
        return selected.isEmpty ? [.en] : selected
    }

    func isLanguageSelected(_ language: BCP47) -> Bool {
        selectedLanguageIds.contains(language.rawValue)
    }

    func toggleLanguage(_ language: BCP47) {
        if selectedLanguageIds.contains(language.rawValue) {
            guard selectedLanguageIds.count > 1 else { return }
            selectedLanguageIds.remove(language.rawValue)
        } else {
            selectedLanguageIds.insert(language.rawValue)
        }
    }

    var languageButtonLabel: String {
        let labels = Self.supportedLanguages
            .filter { selectedLanguageIds.contains($0.id) }
            .map(\.label)
        if labels.isEmpty { return "English" }
        if labels.count <= 3 { return labels.joined(separator: ", ") }
        return "\(labels.count) languages"
    }

    var willUseTesseract: Bool {
        PDFToEPUBPipeline.shouldPreferTesseract(for: selectedLanguages)
    }

    // MARK: - enqueue

    /// Add a single PDF to the queue. Output goes either next to
    /// the source (`book.pdf` → `book.epub` — the original behavior)
    /// or under the user-configured output folder
    /// (`<root>/Books/book.epub`); existing files at that path will
    /// be overwritten when the job runs.
    ///
    /// Enqueues immediately in `.profiling` state, then runs
    /// `DocumentProfiler` in a background `Task` to detect the
    /// document's language. When the profile completes with confident
    /// detection (and the user hasn't manually selected a language for
    /// this drop), the job's `options.languages` are updated to the
    /// detected primary language before the runner is allowed to pick
    /// the job up. The runner skips `.profiling` jobs, so there's no
    /// race between profile and processing.
    func addPDF(_ url: URL) {
        let outputURL = ConversionOutputResolver.epubOutputURL(
            forSource: url, suffix: outputSuffix
        )
        // Non-PDF text inputs (TXT / MD / RTF) skip the OCR pipeline
        // and the document profiler entirely — they enqueue directly
        // and run through DocumentIngest in the JobRunner.
        if DocumentIngest.isSupported(url) {
            addTextDocument(url, outputURL: outputURL)
            return
        }
        let job = Job(
            sourceURL: url,
            outputURL: outputURL,
            options: ConversionOptions(
                languages: selectedLanguages.map { $0.rawValue },
                useSuryaOCR: useSuryaOCR,
                useClaudePageOCR: useClaudePageOCR,
                useManuscriptMode: useManuscriptMode,
                manuscriptHand: manuscriptHand,
                forceOCR: forceOCR,
                privateMode: privateMode,
                emitDebugLog: emitDebugLog,
                emitSiblingTextOutputs: emitSiblingTextOutputs,
                emitSiblingDocuments: emitSiblingDocuments,
                forceOCRPageRangesString: forceOCRPageRangesString,
                outputSuffix: outputSuffix,
                emitSearchablePDF: emitSearchablePDF
            ),
            status: .profiling
        )
        store.add(job)
        let suryaOn = useSuryaOCR
        let privateOn = privateMode
        // Phase 4c: surface the page-OCR pricing in the pre-flight
        // estimate. Same gates the runner applies — the user toggle
        // OR the hidden UserDefault dev knob.
        let pageOCROn = !privateOn && (
            useClaudePageOCR
            || UserDefaults.standard.bool(forKey: "humanist.useClaudePageOCR")
        )
        // Strong capture of `runner` (was `weak runner`): the
        // Task isn't retained by anything, so there's no cycle to
        // break, and Swift 6 strict mode flagged the weak-captured
        // var as unsafe to read across the MainActor.run boundary.
        Task.detached(priority: .userInitiated) { [store, runner] in
            let profile = DocumentProfiler.profile(pdfURL: url)
            // Compute the Cloud-mode cost estimate + content/config
            // warnings from the profile + the user's current AI
            // settings. Cheap (no I/O); the keychain read for
            // `hasAPIKey` runs once in this detached Task so we don't
            // hop main-thread for it later. Private Mode forces
            // `.empty` since no Claude calls will be made regardless
            // of the global cloud-feature toggles.
            let aiSettings = AISettingsStore().load()
            let estimate: CostEstimator.Estimate
            if privateOn {
                estimate = .empty
            } else if aiSettings.processingMode == .cloud {
                estimate = CostEstimator.estimate(
                    profile: profile,
                    cloudFeatures: aiSettings.cloudFeatures,
                    perBookCallCap: aiSettings.perBookCallCap,
                    useClaudePageOCR: pageOCROn
                )
            } else {
                estimate = .empty
            }
            let hasAPIKey = (AnthropicAPIKeyStore().read() ?? "").isEmpty == false
            let warnings = ProfileWarningEvaluator.evaluate(
                ProfileWarningInputs(
                    profile: profile,
                    useHighAccuracyOCR: suryaOn,
                    processingMode: aiSettings.processingMode,
                    cloudFeatures: aiSettings.cloudFeatures,
                    hasAPIKey: hasAPIKey,
                    pickerSupportedLanguages: Self.supportedLanguages.map(\.id)
                )
            )
            await MainActor.run {
                store.update(job.id) { mutable in
                    mutable.profile = profile
                    mutable.costEstimate = estimate
                    mutable.profileWarnings = warnings
                    // Apply detected language when:
                    //   * detection is confident (≥0.7 weighted)
                    //   * the detected language is one we support
                    //   * the user is on the default picker (haven't
                    //     actively chosen otherwise this session) —
                    //     respects an explicit override.
                    if let primary = profile.primaryLanguage,
                       profile.confidence >= Self.applyConfidenceFloor,
                       Self.supportedLanguages.contains(where: { $0.id == primary }) {
                        mutable.options.languages = [primary]
                    }
                    mutable.status = .queued
                }
                runner.start()
            }
        }
    }

    /// Detected primary language must reach this confidence to
    /// override the user's picker. Below it the picker stays in
    /// effect (better to OCR with a slightly-wrong language hint
    /// than to confidently set a wrong one).
    static let applyConfidenceFloor: Double = 0.7

    /// Enqueue a non-PDF text input (TXT / MD / RTF). No profiling,
    /// no cost estimate, no Claude warnings — straight to `.queued`.
    private func addTextDocument(_ url: URL, outputURL: URL) {
        let job = Job(
            sourceURL: url,
            outputURL: outputURL,
            options: ConversionOptions(
                languages: selectedLanguages.map { $0.rawValue },
                useSuryaOCR: false,
                useClaudePageOCR: false,
                forceOCR: false,
                privateMode: privateMode,
                emitDebugLog: false,
                emitSiblingTextOutputs: emitSiblingTextOutputs,
                forceOCRPageRangesString: "",
                outputSuffix: outputSuffix,
                // No source PDF means no searchable-PDF target.
                emitSearchablePDF: false
            ),
            status: .queued
        )
        store.add(job)
        runner.start()
    }

    /// Add every PDF inside `folder` (recursively). Hidden files,
    /// .DS_Store, and macOS package contents are skipped.
    func addFolder(_ folder: URL) {
        for pdf in Self.enumeratePDFs(in: folder) {
            addPDF(pdf)
        }
    }

    /// Add anything dropped (or selected via the file picker) — PDFs
    /// and the supported non-PDF text inputs go straight in, folders
    /// get walked. Returns the count actually enqueued so the drop
    /// callback can decide whether to play a "nothing matched" beep
    /// (currently no-op).
    @discardableResult
    func addDropped(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let before = store.jobs.count
                addFolder(url)
                added += store.jobs.count - before
            } else if url.pathExtension.lowercased() == "pdf"
                       || DocumentIngest.isSupported(url) {
                // `addPDF` self-dispatches: PDFs go through the OCR
                // path, supported text inputs branch to the
                // DocumentIngest path.
                addPDF(url)
                added += 1
            }
        }
        return added
    }

    static func enumeratePDFs(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "pdf" {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: - convenience actions for the queue UI

    func chooseFiles() {
        let panel = NSOpenPanel()
        // Resolve every accepted extension via UTType.init(filenameExtension:)
        // so the picker treats `.md` (no system-assigned UTType in
        // some installs) the same way it treats `.txt`. Falling back
        // to the static UTType constants directly worked for `.pdf`
        // / `.txt` / `.rtf` but silently rejected `.md` files at
        // selection time.
        let extensions = ["pdf"] + DocumentIngest.supportedExtensions
        panel.allowedContentTypes = extensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            addDropped(panel.urls)
        }
    }
}

