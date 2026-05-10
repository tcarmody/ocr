import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AI
import Document
import Layout
import PDFIngest
import Pipeline

/// Launcher window — queue-centric. Drop one PDF or a folder of PDFs;
/// each becomes a job. Existing jobs from previous sessions persist
/// and resume on next launch.
struct ContentView: View {
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var runner: JobRunner
    @State private var isTargeted = false
    @State private var showingWelcome = false
    @State private var showingSuryaSetup = false
    @State private var showingTesseractSetup = false
    @StateObject private var twoUpProcessor = TwoUpProcessor()

    /// Background scanner for the configured `<outputRoot>/Input/`
    /// folder. Started when the `autoScanInputFolder` Settings
    /// toggle is on; stopped when off. Idle by default — no
    /// filesystem watcher running, no overhead for users who don't
    /// opt in.
    @StateObject private var inputScanner = InputFolderScanner()
    @AppStorage(ConversionSettingsKeys.autoScanInputFolder)
    private var autoScanInputFolder: Bool = false
    @AppStorage(ConversionSettingsKeys.outputFolderPath)
    private var outputFolderPath: String = ""
    /// History disclosure state. Defaults collapsed so a long
    /// bulk run doesn't push the active queue off-screen; users
    /// expand it to inspect past conversions or retry failures.
    /// Per-session only — once the user toggles it, the choice
    /// persists for the launcher's lifetime but resets across
    /// app launches.
    @State private var historyExpanded: Bool = false
    @Environment(\.openWindow) private var openWindow
    /// First-run flag. When false, `onAppear` flips
    /// `showingWelcome` true so the welcome sheet presents
    /// automatically. The sheet flips this true on dismiss
    /// (regardless of whether the user clicked "Got it" or "Open
    /// Settings"), so subsequent launches skip it.
    @AppStorage(WelcomeSheet.welcomeShownKey) private var welcomeShown: Bool = false
    /// Per-user preference for whether the Advanced options
    /// (Force OCR pages, Output suffix) are expanded. Defaults
    /// collapsed so the launcher's default view stays uncluttered.
    @AppStorage("humanist.launcher.advancedExpanded")
    private var advancedExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ModeStrip()
            Divider()
            if SuryaConnection.shared == nil {
                SuryaAbsentBanner { showingSuryaSetup = true }
                Divider()
            }
            VStack(spacing: 14) {
                optionsBlock
                if store.jobs.isEmpty {
                    // Queue empty: hero drop zone takes the room.
                    DropZone(isTargeted: isTargeted, compact: false)
                        .frame(maxWidth: .infinity, minHeight: 200)
                    Spacer()
                } else {
                    // Queue has jobs: thin "drop more here" strip
                    // gives the queue its space.
                    DropZone(isTargeted: isTargeted, compact: true)
                        .frame(maxWidth: .infinity, minHeight: 36)
                    queueList
                }
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Drop target accepts PDFs (added to queue) or EPUBs (open editor
        // directly). Folders enumerate to PDFs.
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { isTargeted = $0 }
        // File > Open menu deliveries that target a PDF go through here
        // since the menu can't reach our viewmodel directly.
        .onReceive(NotificationCenter.default.publisher(for: .humanistConvertPDF)) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            handlePDFDrops([url])
        }
        // Two-up detection / split progress + decision UI. Bound to
        // processor.phase != .idle so the sheet auto-dismisses when
        // the processor returns to idle (success, cancel, or error).
        .sheet(isPresented: Binding(
            get: { twoUpProcessor.phase != .idle },
            set: { _ in }
        )) {
            TwoUpProgressSheet(processor: twoUpProcessor)
        }
        .sheet(isPresented: $showingWelcome) {
            WelcomeSheet(isPresented: $showingWelcome)
        }
        .sheet(isPresented: $showingSuryaSetup) {
            SuryaSetupSheet(isPresented: $showingSuryaSetup)
        }
        .sheet(isPresented: $showingTesseractSetup) {
            TesseractSetupSheet(isPresented: $showingTesseractSetup)
        }
        .onAppear {
            if !welcomeShown { showingWelcome = true }
            refreshInputScannerLifecycle()
        }
        // Track the auto-scan toggle and the output-folder picker
        // both — flipping the toggle starts/stops the watcher, and
        // changing the output folder out from under an active
        // watcher needs a restart so it points at the new
        // `<root>/Input/`.
        .onChange(of: autoScanInputFolder) { _, _ in
            refreshInputScannerLifecycle()
        }
        .onChange(of: outputFolderPath) { _, _ in
            refreshInputScannerLifecycle()
        }
        // Help menu's "Show Welcome…" posts this notification so a
        // user who dismissed the first-run sheet can re-open it
        // without resetting the flag manually.
        .onReceive(NotificationCenter.default.publisher(
            for: .humanistShowWelcome
        )) { _ in
            showingWelcome = true
        }
        // Tools → Compare EPUBs… stashes the diff on
        // `EPUBDiffPresenter.shared` then posts this; we open the
        // single-instance "epub-diff" Window scene here. Keeping
        // the openWindow in this view (rather than the menu
        // command) is the only place a SwiftUI menu callback can
        // reach an `@Environment(\.openWindow)` reference.
        .onReceive(NotificationCenter.default.publisher(
            for: .humanistShowEPUBDiff
        )) { _ in
            openWindow(id: "epub-diff")
        }
    }

    /// Start or stop the Input-folder scanner to match current
    /// Settings. The scanner is idempotent on `start(queue:)`, so
    /// calling this from multiple `onAppear` / `onChange` paths is
    /// safe.
    private func refreshInputScannerLifecycle() {
        let shouldRun = autoScanInputFolder && !outputFolderPath.isEmpty
        if shouldRun {
            inputScanner.start(queue: queue)
        } else {
            inputScanner.stop()
        }
    }

    /// Route dropped URLs: EPUBs open immediately; PDFs go through
    /// the async two-up processor (which prompts on detection hits
    /// and otherwise enqueues straight through); folders walk and
    /// queue every PDF inside as-is (no two-up prompt for folders —
    /// would be too noisy at scale).
    ///
    /// Returns true synchronously if anything will be handled — the
    /// PDF/EPUB cases queue async work but we still want the drop
    /// to register as "accepted" for the OS feedback.
    private func handleDrop(_ urls: [URL]) -> Bool {
        var pdfBatch: [URL] = []
        var handledImmediately = false
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let isDir = (try? url.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) ?? false
            if ext == "epub" {
                OpenRouter.open(url, openWindow: openWindow)
                handledImmediately = true
            } else if ext == "pdf" {
                pdfBatch.append(url)
            } else if DocumentIngest.isSupported(url) {
                queue.addPDF(url)
                handledImmediately = true
            } else if isDir {
                // Folders skip two-up detection entirely. Queue
                // every PDF as-is — the per-file detection cost
                // across a 50-book drop is too much, and the
                // prompts would be unmanageable.
                for pdf in QueueViewModel.enumeratePDFs(in: url) {
                    queue.addPDF(pdf)
                    handledImmediately = true
                }
            }
        }
        if !pdfBatch.isEmpty {
            handlePDFDrops(pdfBatch)
            return true
        }
        return handledImmediately
    }

    /// Run the async two-up pipeline for a batch of PDF URLs and
    /// queue whatever resolves. Cancelled/empty results no-op.
    private func handlePDFDrops(_ pdfs: [URL]) {
        Task {
            let resolved = await twoUpProcessor.process(pdfs)
            for url in resolved {
                queue.addPDF(url)
            }
        }
    }

    // MARK: - options + bottom bar

    /// Per-conversion options. Single horizontal row when the
    /// window is wide enough, plus a separator + tesseract badge.
    /// Each toggle / picker only affects new jobs you queue —
    /// existing queued/running jobs keep their snapshotted options.
    @ViewBuilder
    private var optionsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Row 1 — language + engine badge (one visual cluster)
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    languageMenu
                    Divider().frame(height: 14)
                    tesseractStatusBadge
                }
                Spacer(minLength: 0)
            }
            .font(.callout)

            // Row 2 — processing mode toggles
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                Toggle("Force Private", isOn: $queue.privateMode)
                    .toggleStyle(.checkbox)
                    .help("""
                        Per-job override that disables every cloud feature \
                        regardless of your global Settings. No Claude \
                        calls, no cost. Coerces Claude OCR off; Surya OCR \
                        / Force OCR still apply. Redundant when the \
                        ModeStrip already shows "Private" — but harmless.
                        """)
                Toggle("Force OCR", isOn: $queue.forceOCR)
                    .toggleStyle(.checkbox)
                    .help("Skip the PDF's embedded text layer and run OCR on every page. Use when the embedded text is the output of a previous bad OCR pass.")
                Toggle("Claude OCR ($$$)", isOn: $queue.useClaudePageOCR)
                    .toggleStyle(.checkbox)
                    .help("""
                        Sonnet OCRs each page end-to-end. Replaces the \
                        Vision/Surya/Tesseract cascade with one call \
                        per page; produces structured paragraphs, \
                        headings, footnotes, and language spans \
                        directly. Best quality for hard scripts, \
                        complex multi-column layouts, and dense \
                        academic prose. Requires Cloud mode + API key \
                        (configure in Settings); inert otherwise. \
                        Costs ≈ $15–25 per book at current Sonnet \
                        pricing.
                        """)
                Toggle("Surya OCR", isOn: $queue.useSuryaOCR)
                    .toggleStyle(.checkbox)
                    .disabled(SuryaConnection.shared == nil)
                    .help(SuryaConnection.shared == nil
                          ? "Surya is not installed — use \"Set up Surya…\" in the banner above to install it."
                          : "Force Surya OCR on every region of every page. Local-only; works without an API key. Slower than the standard cascade — use when offline and getting poor Vision results.")
                Spacer(minLength: 0)
            }
            .font(.callout)

            // Row 3 — output format toggles
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                Toggle("Searchable PDF", isOn: $queue.emitSearchablePDF)
                    .toggleStyle(.checkbox)
                    .help("""
                        Write `<basename>.searchable.pdf` next to the \
                        EPUB — visually identical to the source PDF, \
                        with invisible OCR text per page so the result \
                        is fully Cmd+F searchable / selectable / \
                        Spotlight-indexed. Off by default; output is \
                        several MB per book.
                        """)
                Toggle(".txt + .md", isOn: $queue.emitSiblingTextOutputs)
                    .toggleStyle(.checkbox)
                    .help("""
                        Write `<basename>.txt` and `<basename>.md` \
                        next to the EPUB. Cheap (plain text); on by \
                        default. Good for search / archival / RAG \
                        pipelines.
                        """)
                Toggle(".html + .docx", isOn: $queue.emitSiblingDocuments)
                    .toggleStyle(.checkbox)
                    .help("""
                        Write a self-contained `<basename>.html` and \
                        a `<basename>.docx` next to the EPUB. Heavier \
                        than the text outputs (DOCX is a binary zip, \
                        HTML inlines all CSS); off by default.
                        """)
                Toggle("Save log", isOn: $queue.emitDebugLog)
                    .toggleStyle(.checkbox)
                    .help("""
                        Keep the per-page staging directory after \
                        conversion and write a diagnostic log next to \
                        the EPUB (under <basename>.humanist-debug/). \
                        Includes Surya region kinds + reading order, \
                        Vision observation bboxes, header/footer / \
                        footnote / heading-promotion decisions, and \
                        trust verdicts. Leaves 50–100MB of artifacts \
                        on disk per book — only enable when \
                        diagnosing conversion issues.
                        """)
                Spacer(minLength: 0)
            }
            .font(.callout)

            // Advanced — collapsed by default. Holds per-page Force OCR
            // override and the output-suffix field that A/B users need.
            advancedDisclosure
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Collapsed by default. Holds the niche per-page Force OCR
    /// override and the output-suffix field most users never touch.
    @ViewBuilder
    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text("Force OCR pages:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("e.g. 1-20, 150-160",
                          text: $queue.forceOCRPageRangesString)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .frame(maxWidth: 200)
                    .help("""
                        Re-OCR these specific pages even when their \
                        embedded text would otherwise pass the trust \
                        scorer. 1-based, comma-separated, with N-M \
                        ranges (e.g. "1-20, 150-160"). Useful for \
                        mixed-quality books — born-digital front \
                        matter + scanned appendix, or any pages where \
                        the embedded text is bad OCR. The global \
                        "Force OCR" toggle overrides every page; this \
                        field overrides only the listed pages.
                        """)
                Text("Output suffix:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("e.g. claude or local",
                          text: $queue.outputSuffix)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .frame(maxWidth: 160)
                    .help("""
                        Append this suffix to the output filenames so \
                        the same source PDF can produce multiple \
                        variants side-by-side. With "claude" set: \
                        "<book> claude.epub" / ".txt" / ".md". Empty \
                        keeps the default "<book>.epub". Pair with \
                        Tools → Compare EPUBs for A/B-ing OCR \
                        methods or settings.
                        """)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
        } label: {
            Text("Advanced")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var languageMenu: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            Menu {
                ForEach(QueueViewModel.supportedLanguages) { opt in
                    Button {
                        queue.toggleLanguage(opt.language)
                    } label: {
                        if queue.isLanguageSelected(opt.language) {
                            Label(opt.label, systemImage: "checkmark")
                        } else {
                            Text(opt.label)
                        }
                    }
                }
            } label: {
                Text(queue.languageButtonLabel)
                    .frame(maxWidth: 200, alignment: .leading)
            }
            .frame(maxWidth: 220)
        }
    }

    /// Bottom action bar. Choose Files always present; Pause /
    /// Resume + Show Queue + Clear Done + Cancel All conditional
    /// on queue state.
    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                queue.chooseFiles()
            } label: {
                Label("Choose Files or Folder…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            // Open the dedicated full-queue window (R-Launcher-FullQueue).
            // Visible whenever the queue has any rows — gives the user
            // a way to see the whole list at once without the
            // launcher's drop / options bar competing for vertical
            // space. Window menu also has this command (⇧⌘Q).
            if !store.jobs.isEmpty {
                Button {
                    openWindow(id: "queue")
                } label: {
                    Label("Show Queue", systemImage: "rectangle.split.3x1")
                }
                .help("Open the full-queue window")
            }
            // Pause / Resume Queue. Visible when there's pending work
            // OR the queue is currently paused (so an empty paused
            // queue can still be unpaused — e.g. user paused mid-run,
            // current job finished, hasPendingWork is now false but
            // they may still want to "re-arm" before adding more PDFs).
            if store.hasPendingWork || runner.isPaused {
                Button {
                    if runner.isPaused {
                        runner.resume()
                    } else {
                        runner.pause()
                    }
                } label: {
                    if runner.isPaused {
                        Label("Resume Queue", systemImage: "play.fill")
                    } else {
                        Label("Pause Queue", systemImage: "pause.fill")
                    }
                }
            }
            if store.jobs.contains(where: \.isFinished) {
                Button("Clear Done") { store.clearFinished() }
            }
            if store.hasPendingWork {
                Button("Cancel All", role: .destructive) {
                    runner.cancelAll()
                }
            }
        }
    }

    @ViewBuilder
    private var tesseractStatusBadge: some View {
        if queue.willUseTesseract && !queue.tesseractAvailable {
            Button {
                showingTesseractSetup = true
            } label: {
                Label("Tesseract not installed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help("Click to install Tesseract — improves accuracy on classical scripts")
        } else if queue.willUseTesseract {
            Label("Tesseract", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Vision", systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - queue

    @ViewBuilder
    private var queueList: some View {
        // Caller (`body`) only renders this when `store.jobs` is
        // non-empty — the empty-queue case is handled by the
        // hero drop zone above instead of an "empty queue" label.
        //
        // Two sections (R-Launcher-History): active jobs at the top
        // (reorderable via `.onMove`, the user's working surface),
        // and a collapsible "History" disclosure at the bottom for
        // done / failed / cancelled jobs. The disclosure defaults
        // to collapsed so a long bulk run doesn't push the active
        // queue off-screen; the user expands it when they want to
        // open a past EPUB or retry a failure.
        List {
            ForEach(store.activeJobs) { job in
                JobRow(job: job)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .padding(.vertical, 3)
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            .onMove { source, destination in
                store.move(from: source, to: destination)
            }

            // History disclosure — only present when there are
            // finished jobs, so the section header doesn't render
            // as an empty stub on a fresh queue.
            let finished = store.finishedJobs
            if !finished.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $historyExpanded) {
                        ForEach(finished) { job in
                            JobRow(job: job)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                        .padding(.vertical, 3)
                                )
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                    } label: {
                        Text("History (\(finished.count))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: 280)
    }
}

private struct JobRow: View {
    let job: Job
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var runner: JobRunner
    @Environment(\.openWindow) private var openWindow

    /// One-line cost estimate for the queue row, shown only when
    /// Cloud mode is on and at least one feature is enabled (i.e.
    /// the estimate is non-zero). Tooltip carries the per-feature
    /// breakdown.
    private func costEstimateSummary(_ job: Job) -> String? {
        guard let est = job.costEstimate, est.estimatedCalls > 0 else {
            return nil
        }
        let prefix = est.clampedByCap ? "Cloud (capped): " : "Cloud: "
        return "\(prefix)~\(est.estimatedCalls) calls (~\(formatCost(est.estimatedCostUSD)))"
    }

    /// Multi-line tooltip for the cost-estimate row — per-feature
    /// breakdown, plus a note about the estimate's coarseness.
    private func costEstimateTooltip(_ job: Job) -> String? {
        guard let est = job.costEstimate, !est.perFeature.isEmpty else {
            return nil
        }
        var lines: [String] = []
        for line in est.perFeature {
            lines.append(
                "\(line.label): ~\(line.calls) calls × \(line.model) ≈ \(formatCost(line.costUSD))"
            )
        }
        if est.clampedByCap {
            lines.append("Capped by per-book limit; unclamped estimate above.")
        }
        lines.append(
            "Estimate is approximate — actual cost depends on which regions trip the cascade's quality floor."
        )
        return lines.joined(separator: "\n")
    }

    /// Format a USD amount for display. Uses the same precision
    /// rules `ConversionStats.formattedCost` does so the queue row
    /// reads consistently before vs after conversion.
    private func formatCost(_ usd: Double) -> String {
        if usd < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }

    /// Compact summary of the document profile for the queue row —
    /// "Latin auto-detected", "Likely scan; using picker default",
    /// etc. Only shows when there's something interesting to say,
    /// so users on born-digital English books aren't visually nagged.
    private func profileSummary(_ job: Job) -> String? {
        guard let p = job.profile else { return nil }
        if let primary = p.primaryLanguage,
           p.confidence >= QueueViewModel.applyConfidenceFloor,
           QueueViewModel.supportedLanguages.contains(where: { $0.id == primary }) {
            let label = QueueViewModel.supportedLanguages
                .first(where: { $0.id == primary })?.label ?? primary
            return "Detected: \(label)"
        }
        if p.isLikelyScan {
            return "Likely scan; using picker default"
        }
        return nil
    }

    /// Per-source observation breakdown for the row's tooltip,
    /// plus per-page verdict counts (trust vs reocr) so the user
    /// can see whether OCR actually ran. Useful for verifying the
    /// cascade did what was expected on a given book.
    private func statsTooltip(_ stats: ConversionStats) -> String {
        let perSource = stats.observationsBySource
            .sorted { $0.key < $1.key }
            .filter { $0.value > 0 }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        var lines: [String] = []
        let totalPages = stats.pagesTrustedEmbeddedText + stats.pagesReOCRd
        if totalPages > 0 {
            lines.append(
                "Pages — OCR'd: \(stats.pagesReOCRd), trusted embedded: \(stats.pagesTrustedEmbeddedText)"
            )
        }
        if !perSource.isEmpty { lines.append("Observations — \(perSource)") }
        if stats.claudeCallCount > 0 {
            lines.append("Estimated cost: \(stats.formattedCost)")
        }
        lines.append("Elapsed: \(String(format: "%.1fs", stats.elapsed))")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.sourceURL.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLine
            }
            Spacer()
            actionButtons
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .profiling:
            ProgressView().controlSize(.small)
        case .queued:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch job.status {
        case .profiling:
            Text("Profiling…").font(.caption).foregroundStyle(.secondary)
        case .queued:
            VStack(alignment: .leading, spacing: 2) {
                Text("Queued").font(.caption).foregroundStyle(.secondary)
                if let detected = profileSummary(job) {
                    Text(detected).font(.caption2).foregroundStyle(.secondary)
                }
                if let costLine = costEstimateSummary(job) {
                    Text(costLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(costEstimateTooltip(job) ?? "")
                }
                ForEach(job.profileWarnings ?? [], id: \.rawValue) { warning in
                    Label(warning.headline, systemImage: warning.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        case .running:
            if let p = job.progress, p.totalPages > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Page \(p.completedPages) of \(p.totalPages)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: p.fraction)
                }
            } else {
                Text("Starting…").font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            VStack(alignment: .leading, spacing: 2) {
                Text("Done — \(job.outputURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let stats = job.stats {
                    // Surface Cloud-mode usage so the user knows
                    // whether Claude actually fired on this book.
                    // Stats persisted on the Job, not recomputed.
                    Text(stats.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(statsTooltip(stats))
                }
            }
        case .failed:
            Text(job.error ?? "Failed")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .textSelection(.enabled)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch job.status {
        case .profiling:
            // Profile completes within a fraction of a second on most
            // PDFs — don't bother offering a Cancel button for the
            // brief flash of `.profiling`. The job becomes cancelable
            // as soon as it flips to `.queued`.
            EmptyView()
        case .queued:
            Button("Cancel", role: .destructive) {
                runner.cancel(jobID: job.id)
            }
            .controlSize(.small)
        case .running:
            if runner.cancellingJobIDs.contains(job.id) {
                Text("Cancelling…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Cancel", role: .destructive) {
                    runner.cancel(jobID: job.id)
                }
                .controlSize(.small)
            }
        case .done:
            Button("Open") {
                RecentsStore.add(job.outputURL)
                openWindow(id: "editor", value: job.outputURL)
            }
            .controlSize(.small)
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([job.outputURL])
            }
            .controlSize(.small)
            Button {
                store.remove(job.id)
            } label: { Image(systemName: "xmark") }
                .controlSize(.small)
                .help("Remove from queue")
        case .failed, .cancelled:
            Button("Retry") {
                runner.retry(jobID: job.id)
            }
            .controlSize(.small)
            Button {
                store.remove(job.id)
            } label: { Image(systemName: "xmark") }
                .controlSize(.small)
                .help("Remove from queue")
        }
    }
}

private extension Job {
    var isFinished: Bool {
        switch status {
        case .done, .failed, .cancelled:        return true
        case .queued, .running, .profiling:     return false
        }
    }
}

/// Status strip across the top of the launcher. Tells the user at
/// a glance what processing mode they're in (Private vs Cloud),
/// surfaces Cloud-mode misconfigurations (no API key, no features
/// enabled) before they queue anything, and gives one-click access
/// to Settings via the trailing gear button.
///
/// Refreshes itself off the AISettings store on appear and
/// whenever the Settings sheet might have closed (`scenePhase`
/// Shown at the top of the launcher when Surya isn't installed.
/// Communicates Vision-only mode and offers a direct path to setup.
private struct SuryaAbsentBanner: View {
    let onSetup: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Surya not installed — layout analysis disabled")
                    .font(.callout.weight(.semibold))
                Text("Conversions will use Apple Vision OCR only. For better structure (headings, footnotes, tables), set up Surya below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set up Surya…") { onSetup() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}

/// transitions). Keeps the strip honest without subscribing to
/// every UserDefaults change.
private struct ModeStrip: View {
    @State private var settings: AISettings = AISettings()
    @State private var hasAPIKey: Bool = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: 12) {
            modeBadge
            Divider().frame(height: 16)
            detailLine
            Spacer()
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Open Settings (⌘,)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, _ in refresh() }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var modeBadge: some View {
        Button {
            // Land on the AI pane: the badge is the user's entry point
            // for "what mode am I in" — that decision lives in AI
            // Settings, not whatever tab was last viewed.
            UserDefaults.standard.set(
                SettingsTab.ai.rawValue,
                forKey: SettingsTab.storageKey
            )
            openSettings()
        } label: {
            switch settings.processingMode {
            case .privateLocal:
                Label("Private", systemImage: "lock.shield")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            case .cloud:
                Label("Cloud", systemImage: "cloud")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
            }
        }
        .buttonStyle(.borderless)
        .help("Processing mode — click to open AI Settings (⌘,)")
    }

    @ViewBuilder
    private var detailLine: some View {
        switch settings.processingMode {
        case .privateLocal:
            Text("Local-only — no data leaves this machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .cloud:
            HStack(spacing: 8) {
                if !hasAPIKey {
                    Label("No API key", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    let active = enabledFeatureCount(settings.cloudFeatures)
                    if active == 0 {
                        Label("0 features enabled", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Label("\(active) feature\(active == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Cap: \(settings.perBookCallCap) calls/book")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func enabledFeatureCount(_ f: AISettings.CloudFeatures) -> Int {
        var n = 0
        if f.hardRegionOCR { n += 1 }
        if f.tableExtraction { n += 1 }
        if f.postOCRCleanup { n += 1 }
        if f.semanticClassification { n += 1 }
        if f.tocParsing { n += 1 }
        return n
    }

    private func refresh() {
        settings = AISettingsStore().load()
        hasAPIKey = (AnthropicAPIKeyStore().read() ?? "").isEmpty == false
    }
}

/// Visual indicator only — actual drop handling lives on the outer
/// view so users can drop anywhere in the window. `isTargeted` is owned
/// by the parent and driven by the outer `dropDestination` callback.
///
/// `compact: true` shrinks the zone to a thin "Drop more PDFs here"
/// strip — used when the queue already has jobs and the user wants
/// the queue to take the room. The full hero variant lands on the
/// empty-queue first-run case.
private struct DropZone: View {
    let isTargeted: Bool
    let compact: Bool
    // Static `HumanistTheme.accent` etc. resolve via dynamic
    // NSColor at draw time but their SwiftUI Color identity
    // doesn't change on theme switch — without observing the
    // store directly, this view won't redraw and AppKit won't
    // re-ask for the colors.
    @ObservedObject private var themeStore = HumanistThemeStore.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 8 : 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? HumanistTheme.accent : HumanistTheme.divider,
                    style: StrokeStyle(
                        lineWidth: isTargeted ? 2.5 : 1.5,
                        dash: [6, 4]
                    )
                )
                .background(
                    RoundedRectangle(cornerRadius: compact ? 8 : 14, style: .continuous)
                        .fill(isTargeted
                              ? HumanistTheme.accentMuted
                              : HumanistTheme.surface.opacity(0.5))
                )
            if compact {
                HStack(spacing: 8) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.callout)
                        .foregroundStyle(isTargeted
                            ? AnyShapeStyle(HumanistTheme.accent)
                            : AnyShapeStyle(HumanistTheme.inkSecondary))
                    Text(isTargeted ? "Release to add" : "Drop more documents here")
                        .font(.callout)
                        .foregroundStyle(HumanistTheme.inkSecondary)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.image")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(isTargeted
                            ? AnyShapeStyle(HumanistTheme.accent)
                            : AnyShapeStyle(HumanistTheme.inkTertiary))
                    Text(isTargeted ? "Release to add to queue" : "Drop documents or a folder")
                        .font(.system(.title3, design: .serif))
                        .foregroundStyle(HumanistTheme.inkPrimary)
                    Text("PDF, DOCX, HTML, RTF, MD, TXT — folders enumerate every PDF inside, recursively.")
                        .font(.callout)
                        .foregroundStyle(HumanistTheme.inkTertiary)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
