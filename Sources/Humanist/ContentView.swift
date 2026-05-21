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
    @Environment(JobStore.self) private var store
    @EnvironmentObject private var runner: JobRunner
    @EnvironmentObject private var library: LibraryStore
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
        // U-HIG-Launcher-Toolbar (β): per-job options live in
        // toolbar menus (OCR Engine / Languages / Outputs); the
        // content area is drop zone + queue + Choose Files CTA +
        // a compact per-job overrides disclosure. The custom
        // ModeStrip strip is gone — the mode badge sits in the
        // toolbar's `.principal` placement now.
        VStack(spacing: 0) {
            if SuryaConnection.shared == nil {
                SuryaAbsentBanner { showingSuryaSetup = true }
                Divider()
            }
            VStack(spacing: 14) {
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
                chooseFilesCTA
                perJobOverridesDisclosure
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Humanist")
        .toolbar { toolbarContent }
        // No explicit `.background(.windowBackgroundColor)` here —
        // the window itself paints that color, and the redundant
        // paint would block macOS 26's Liquid Glass treatment if
        // U-HIG-Launcher-Toolbar later promotes ModeStrip into a
        // real `.toolbar` (the floating-glass toolbar samples
        // through to the content beneath; an opaque root
        // background defeats it). `ModeStrip` itself uses
        // `.background(.bar)`, the system material that adapts
        // automatically.
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
            // Re-read keychain so a key just pasted in Settings →
            // AI appears in the OCR Engine picker without a relaunch.
            queue.refreshAPIKeyAvailability()
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
    /// Settings. The scanner is idempotent on
    /// `start(queue:library:)`, so calling this from multiple
    /// `onAppear` / `onChange` paths is safe. The library is
    /// threaded through so the scanner can consult catalog source
    /// hashes (dedupe + rejection) before enqueuing.
    private func refreshInputScannerLifecycle() {
        let shouldRun = autoScanInputFolder && !outputFolderPath.isEmpty
        if shouldRun {
            inputScanner.start(queue: queue, library: library)
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

    // MARK: - Toolbar (U-HIG-Launcher-Toolbar β)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Mode badge sits in the principal slot — clickable
        // chip showing "Private" or "Cloud" and the per-feature
        // detail. Tapping opens Settings → AI so the badge IS
        // the discovery hook for mode configuration.
        ToolbarItem(placement: .principal) {
            ModeBadge()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ocrEngineMenu
            languagesMenu
            outputsMenu
            if !store.jobs.isEmpty {
                Button {
                    openWindow(id: "queue")
                } label: {
                    Label("Show Queue", systemImage: "rectangle.split.3x1")
                }
                .help("Open the full-queue window")
                .accessibilityLabel("Show queue window")
            }
            // Pause / Resume is always visible — pre-emptive pause
            // before adding work is a valid intent, and the auto-
            // scanner can enqueue items even when the launcher's
            // queue is empty from the user's last view. Persisted
            // pause state plus the "Start paused on launch"
            // preference in Settings give the user control over
            // how the queue behaves between sessions.
            Button {
                if runner.isPaused {
                    runner.resume()
                } else {
                    runner.pause()
                }
            } label: {
                if runner.isPaused {
                    Label("Resume", systemImage: "play.fill")
                } else {
                    Label("Pause", systemImage: "pause.fill")
                }
            }
            .help(runner.isPaused ? "Resume the queue" : "Pause the queue")
            .accessibilityLabel(runner.isPaused ? "Resume queue" : "Pause queue")
            if store.hasPendingWork {
                Button(role: .destructive) {
                    runner.cancelAll()
                } label: {
                    Label("Cancel All", systemImage: "xmark.circle")
                }
                .help("Cancel every pending or running job")
                .accessibilityLabel("Cancel all queued jobs")
            }
        }
    }

    /// OCR Engine Picker, packaged as a toolbar Menu. Replaces
    /// the previous trio of mutually-exclusive Cloud-OCR toggles
    /// (Claude OCR / Early Print / Manuscript) plus the
    /// independent-but-redundant Surya OCR toggle. A single
    /// 5-way choice cleanly expresses "what reads this book?"
    /// without the user having to know which toggles to combine.
    @ViewBuilder
    private var ocrEngineMenu: some View {
        Menu {
            // Flat list, ordered by typical "first to reach for"
            // descending: cascade default → offline-only Surya →
            // budget cloud page-OCR (Gemini) → premium cloud
            // page-OCR (Claude) → specialized period / manuscript
            // modes. Gemini sits ahead of Claude Typeset because
            // the per-page cost is ~7-10× lower at comparable
            // quality on typeset prose; users who specifically want
            // Sonnet still reach it one row down.
            // Cloud-backed entries hide when their required API key
            // isn't configured. Pasting a key in Settings → AI flips
            // the gate the next time the launcher reappears (via
            // `refreshAPIKeyAvailability()` on `.onAppear`). The
            // `Auto` and `Surya` rows are always present — they don't
            // need cloud access.
            Picker("OCR Engine", selection: ocrEngineBinding) {
                Text("Auto (Vision + Tesseract cascade)")
                    .tag(LauncherOCREngine.auto)
                Text("Surya OCR (local, force)")
                    .tag(LauncherOCREngine.surya)
                if queue.hasGeminiKey {
                    Text("Gemini OCR — Typeset ($)")
                        .tag(LauncherOCREngine.geminiTypeset)
                }
                if queue.hasAnthropicKey {
                    Text("Claude OCR — Typeset ($$$)")
                        .tag(LauncherOCREngine.claudeTypeset)
                    Text("Claude OCR — Early Print ($$$)")
                        .tag(LauncherOCREngine.earlyPrint)
                    Text("Claude OCR — Manuscript ($$$$)")
                        .tag(LauncherOCREngine.manuscript)
                }
            }
            .pickerStyle(.inline)
            if ocrEngineBinding.wrappedValue == .earlyPrint {
                Divider()
                Picker("Typeface", selection: $queue.earlyPrintTypeface) {
                    ForEach(EarlyPrintTypeface.allCases, id: \.self) { face in
                        Text(face.displayName).tag(face)
                    }
                }
                .pickerStyle(.inline)
            }
            if ocrEngineBinding.wrappedValue == .manuscript {
                Divider()
                Picker("Hand", selection: $queue.manuscriptHand) {
                    ForEach(ManuscriptHand.allCases, id: \.self) { hand in
                        Text(hand.displayName).tag(hand)
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label(ocrEngineMenuLabel, systemImage: "text.viewfinder")
        }
        .help(ocrEngineHelp)
    }

    /// Languages Menu — same toggleable list the old launcher
    /// kept inline at the top of the options block. Each language
    /// is independently switchable. Tesseract install status
    /// surfaces as a contextual footer when the selection would
    /// benefit from it.
    @ViewBuilder
    private var languagesMenu: some View {
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
            if queue.willUseTesseract && !queue.tesseractAvailable {
                Divider()
                Button {
                    showingTesseractSetup = true
                } label: {
                    Label("Set up Tesseract for classical scripts…",
                          systemImage: "exclamationmark.triangle")
                }
            }
        } label: {
            Label(queue.languageButtonLabel, systemImage: "globe")
        }
        .help("Pick the languages this conversion should expect")
    }

    /// Outputs Menu — checkmark items for the four sibling-format
    /// toggles. Each is independent. Replaces the four checkbox
    /// row that previously sat in the options block.
    @ViewBuilder
    private var outputsMenu: some View {
        Menu {
            Toggle("Searchable PDF",
                   isOn: $queue.emitSearchablePDF)
            Toggle(".txt + .md",
                   isOn: $queue.emitSiblingTextOutputs)
            Toggle(".html + .docx",
                   isOn: $queue.emitSiblingDocuments)
            Divider()
            Toggle("Save debug log",
                   isOn: $queue.emitDebugLog)
        } label: {
            Label("Outputs", systemImage: "square.and.arrow.down.on.square")
        }
        .help("Choose which sibling files (.txt / .md / .html / .docx / searchable PDF / debug log) get written alongside the EPUB")
    }

    // MARK: - OCR Engine model

    /// Five-way mode the launcher's OCR Engine Picker exposes.
    /// Maps to the existing mutually-exclusive cluster of
    /// `useClaudePageOCR` / `useEarlyPrintMode` / `useManuscriptMode`
    /// / `useSuryaOCR` bools on QueueViewModel. Going through this
    /// enum guarantees the bools stay coherent — earlier launcher
    /// behavior allowed `useSuryaOCR` to combine with the Cloud
    /// modes (it had no effect when Claude OCR was on), which the
    /// β redesign cleans up: picking any Claude mode clears
    /// `useSuryaOCR` too.
    enum LauncherOCREngine: Hashable {
        case auto
        case surya
        case claudeTypeset
        /// Same mode as `.claudeTypeset` (whole-page OCR) but routes
        /// to Gemini 2.5 Flash via a per-conversion override on
        /// `queue.pageOCRProvider`. Manuscript and Early Print stay
        /// Claude-specific — Manuscript hard-pins Opus; Early Print
        /// has a Claude-tuned normalizing prompt that hasn't been
        /// validated against Gemini.
        case geminiTypeset
        case earlyPrint
        case manuscript
    }

    private var ocrEngineBinding: Binding<LauncherOCREngine> {
        Binding(
            get: {
                if queue.useManuscriptMode { return .manuscript }
                if queue.useEarlyPrintMode { return .earlyPrint }
                if queue.useClaudePageOCR {
                    return queue.pageOCRProvider == .gemini25Flash
                        ? .geminiTypeset
                        : .claudeTypeset
                }
                if queue.useSuryaOCR { return .surya }
                return .auto
            },
            set: { newValue in
                queue.useClaudePageOCR = false
                queue.useEarlyPrintMode = false
                queue.useManuscriptMode = false
                queue.useSuryaOCR = false
                queue.pageOCRProvider = nil
                switch newValue {
                case .auto: break
                case .surya: queue.useSuryaOCR = true
                case .claudeTypeset: queue.useClaudePageOCR = true
                case .geminiTypeset:
                    queue.useClaudePageOCR = true
                    queue.pageOCRProvider = .gemini25Flash
                case .earlyPrint: queue.useEarlyPrintMode = true
                case .manuscript: queue.useManuscriptMode = true
                }
            }
        )
    }

    /// Menu-label string showing the currently-selected engine
    /// (and the sub-pick when applicable) so the user reads
    /// their setting at a glance without opening the menu.
    private var ocrEngineMenuLabel: String {
        switch ocrEngineBinding.wrappedValue {
        case .auto: return "Auto OCR"
        case .surya: return "Surya OCR"
        case .claudeTypeset: return "Claude — Typeset"
        case .geminiTypeset: return "Gemini — Typeset"
        case .earlyPrint:
            return "Claude — Early Print (\(queue.earlyPrintTypeface.displayName))"
        case .manuscript:
            return "Claude — Manuscript (\(queue.manuscriptHand.displayName))"
        }
    }

    private var ocrEngineHelp: String {
        switch ocrEngineBinding.wrappedValue {
        case .auto:
            return "Standard cascade: Vision → Tesseract → optional Cloud Sonnet on hard regions (when Cloud features are enabled in Settings)."
        case .surya:
            return "Force Surya for every region. Local-only; works without an API key. Slower than the standard cascade — use when offline."
        case .claudeTypeset:
            return "Sonnet OCRs each page end-to-end. Best for modern printed material with hard scripts or dense academic prose. Requires Cloud mode + API key. ≈ $15–25 per book."
        case .geminiTypeset:
            return "Gemini 2.5 Flash OCRs each page end-to-end. Same XHTML output as Claude Typeset at ~7–10× lower cost (~$2 per book). Best on typeset prose; Sonnet still wins on dense academic layouts. Requires Cloud mode + a Google AI Studio key in Settings → AI."
        case .earlyPrint:
            return "Sonnet with a normalizing prompt tuned for 15th–18th c. printed material (long-s, u/v, i/j, ligatures). Pick a typeface inside the menu; \"Auto\" lets the model identify Roman vs Blackletter."
        case .manuscript:
            return "Opus 4.7 with hand-family-specific prompts for handwritten material. ≈ 5× more expensive than Claude — Typeset. Pick a hand inside the menu; \"Auto\" identifies the family from the page."
        }
    }

    // MARK: - Content pieces

    /// Primary CTA below the drop zone — explicit alternative to
    /// drag-drop for keyboard / accessibility users and for the
    /// "I have a file picked but won't drag" case.
    @ViewBuilder
    private var chooseFilesCTA: some View {
        HStack {
            Spacer()
            Button {
                queue.chooseFiles()
            } label: {
                Label("Choose Files or Folder…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: [.command, .shift])
            if store.jobs.contains(where: \.isFinished) {
                Button("Clear Done") { store.clearFinished() }
            }
            Spacer()
        }
    }

    /// Per-job overrides — the niche knobs most users never touch.
    /// Replaces the old "Advanced" disclosure plus the Force
    /// Private / Force OCR / Save log toggles that used to sit in
    /// the options block. Collapsed by default.
    @ViewBuilder
    private var perJobOverridesDisclosure: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Toggle("Force Private", isOn: $queue.privateMode)
                        .toggleStyle(.checkbox)
                        .help("""
                            Per-job override that disables every cloud feature \
                            regardless of your global Settings. Redundant when \
                            the toolbar's mode badge already shows "Private" — \
                            but harmless.
                            """)
                    Toggle("Force OCR", isOn: $queue.forceOCR)
                        .toggleStyle(.checkbox)
                        .help("Skip the PDF's embedded text layer and run OCR on every page.")
                    Toggle("Facing-page bilingual",
                           isOn: $queue.forceBilingualFacingPage)
                        .toggleStyle(.checkbox)
                        .help("""
                            Force the bilingual cross-link pass even when the \
                            auto-detector would have given up. Use for Loeb-style \
                            books whose alternation is broken by heavy footnotes, \
                            or for facing-page editions outside the classical \
                            language set (Greek / Latin / Hebrew).
                            """)
                    Toggle("Batch API",
                           isOn: $queue.useBatchAPI)
                        .toggleStyle(.checkbox)
                        .help("""
                            Submit all pages as one Anthropic batch — half the \
                            per-token cost in exchange for a 1–5 minute async \
                            wait with no live per-page progress. Seeded from \
                            Settings → AI → Throughput; per-session flip \
                            doesn't write back. Good for overnight bulk runs.
                            """)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text("Force OCR pages:")
                        .foregroundStyle(.secondary)
                    TextField("e.g. 1-20, 150-160",
                              text: $queue.forceOCRPageRangesString)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .help("""
                            Re-OCR these specific pages even when their \
                            embedded text would otherwise pass the trust \
                            scorer. 1-based, comma-separated, with N-M \
                            ranges (e.g. "1-20, 150-160").
                            """)
                    Text("Output suffix:")
                        .foregroundStyle(.secondary)
                    TextField("e.g. claude or local",
                              text: $queue.outputSuffix)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .help("""
                            Append this suffix to the output filenames so the \
                            same source PDF can produce multiple variants \
                            side-by-side. Empty keeps the default "<book>.epub".
                            """)
                    Spacer()
                }
            }
            .font(.callout)
            .padding(.top, 6)
        } label: {
            Text("Per-job overrides")
                .font(.callout)
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
    @Environment(JobStore.self) private var store
    @EnvironmentObject private var runner: JobRunner
    @EnvironmentObject private var queue: QueueViewModel
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
        if stats.pagesRefused > 0 {
            let pct = String(format: "%.1f%%", stats.refusalRate * 100)
            let providerLabel = stats.pageOCRProviderId.isEmpty
                ? "" : " (\(stats.pageOCRProviderId))"
            lines.append(
                "Refusal rate\(providerLabel) — \(stats.pagesRefused) of \(stats.pagesReOCRd) pages refused (\(pct))"
            )
            // Show the first handful of refused page numbers so the
            // user can jump to them. 1-based for human display.
            let preview = stats.refusedPageIndices.prefix(10)
                .map { String($0 + 1) }
                .joined(separator: ", ")
            if !preview.isEmpty {
                let more = stats.refusedPageIndices.count > 10
                    ? " (+ \(stats.refusedPageIndices.count - 10) more)" : ""
                lines.append("Refused pages — \(preview)\(more)")
            }
        }
        if stats.pagesEmpty > 0 {
            lines.append("Empty responses — \(stats.pagesEmpty) page\(stats.pagesEmpty == 1 ? "" : "s")")
        }
        if stats.pagesAPIError > 0 {
            lines.append("API errors — \(stats.pagesAPIError) page\(stats.pagesAPIError == 1 ? "" : "s")")
        }
        if stats.pagesUsingVisionFallback > 0 {
            let n = stats.pagesUsingVisionFallback
            lines.append(
                "Vision fallback — \(n) page\(n == 1 ? "" : "s") (provider failure; "
                + "Vision OCR'd them locally instead of leaving them blank)"
            )
        }
        lines.append("Elapsed: \(String(format: "%.1fs", stats.elapsed))")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            statusIcon
                .frame(width: 18)
                // Status icon is decorative — the adjacent
                // `statusLine` text describes the same state in
                // words. Hide from VoiceOver so it isn't read as
                // "circle dashed" / "exclamation triangle".
                .accessibilityHidden(true)
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
            if job.skippedReason != nil {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    /// True when this job's options are still mutable from the
    /// queue UI. Once a job has reached `.running` (or anything
    /// past it), per-job toggles have been baked into the pipeline
    /// dispatch and flipping them post-hoc would lie about what
    /// will actually run.
    private var optionsMutable: Bool {
        job.status == .queued || job.status == .profiling
    }

    /// Render one warning row. Most warnings are read-only Labels
    /// (the original posture); the two complex-layout cases that
    /// have a clear local fix (enable Page OCR / enable Surya)
    /// also surface an inline link button so the user can flip the
    /// per-job toggle directly from the queue row, without going
    /// back to Settings.
    ///
    /// MACUX: link-styled buttons are the unobtrusive convention
    /// for "do this thing" affordances embedded in informational
    /// rows; system colors only; `.help(…)` tooltip for
    /// discoverability.
    @ViewBuilder
    private func warningRow(_ warning: ProfileWarning) -> some View {
        switch warning {
        case .complexLayoutRecommendCloudPageOCR:
            actionableWarning(
                warning: warning,
                isOn: job.options.useClaudePageOCR,
                enableLabel: "Enable Page OCR for this job",
                disableLabel: "Page OCR enabled · Undo",
                helpText: """
                    Routes every page through Claude Sonnet or Gemini Flash \
                    (whichever provider you've configured). Best quality on \
                    scans and figure-rich layouts; costs ~$0.005–0.04/page. \
                    Per-job override — doesn't change your launcher defaults.
                    """,
                mutate: { newValue in
                    store.update(job.id) { mutable in
                        mutable.options.useClaudePageOCR = newValue
                    }
                    // Cost shape changes materially when Page OCR
                    // flips — refresh the displayed estimate.
                    queue.recomputeCostEstimate(forJobID: job.id)
                }
            )
        case .complexLayoutRecommendSurya:
            actionableWarning(
                warning: warning,
                isOn: job.options.useSuryaOCR,
                enableLabel: "Enable Surya OCR for this job",
                disableLabel: "Surya OCR enabled · Undo",
                helpText: """
                    Routes every page through Surya's layout-aware OCR \
                    (free, on-device). Better than Vision on scans and \
                    figure-rich layouts. Per-job override — doesn't change \
                    your launcher defaults.
                    """,
                mutate: { newValue in
                    store.update(job.id) { mutable in
                        mutable.options.useSuryaOCR = newValue
                    }
                    // Surya is free, so cost doesn't change —
                    // but recompute anyway for symmetry and so
                    // any future Surya-related estimate logic
                    // shows up here uniformly.
                    queue.recomputeCostEstimate(forJobID: job.id)
                }
            )
        default:
            Label(warning.headline, systemImage: warning.systemImage)
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    /// Shared body for the two actionable warning cases. When the
    /// per-job toggle is off, render the warning headline + the
    /// "Enable" link. When already on, swap to a confirmation row
    /// with "Undo" so the user can reverse course. The button
    /// disappears once the job leaves the mutable states.
    @ViewBuilder
    private func actionableWarning(
        warning: ProfileWarning,
        isOn: Bool,
        enableLabel: String,
        disableLabel: String,
        helpText: String,
        mutate: @escaping (Bool) -> Void
    ) -> some View {
        // `.firstTextBaseline` aligns the label's text baseline
        // with the bordered button's text baseline so the row
        // doesn't appear shifted vertically. Default HStack
        // alignment is `.center`, which the icon's larger glyph
        // height would otherwise push out of line with the
        // button text.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isOn {
                Label(disableLabel, systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if optionsMutable {
                    Button("Undo") { mutate(false) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption2)
                        .help(helpText)
                }
            } else {
                Label(warning.headline, systemImage: warning.systemImage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                if optionsMutable {
                    Button(enableLabel) { mutate(true) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption2)
                        .help(helpText)
                }
            }
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
                    warningRow(warning)
                }
            }
        case .running:
            if let p = job.progress, p.totalPages > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    switch p.phase {
                    case .batchWaiting:
                        // Anthropic Batch API submitted; we're
                        // polling for completion. Swap the linear
                        // bar for a small inline spinner so the
                        // user doesn't think the job is stuck.
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for batch (~1–5 min)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .processing:
                        Text("Page \(p.completedPages) of \(p.totalPages)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: p.fraction)
                    }
                }
            } else {
                Text("Starting…").font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            VStack(alignment: .leading, spacing: 2) {
                if let reason = job.skippedReason {
                    // R-Library-Dedupe pre-flight short-circuit.
                    // `outputURL` was redirected to the existing
                    // entry's EPUB so Open / Reveal in the action
                    // buttons still work — surface the reason here.
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(reason)
                } else {
                    Text("Done — \(job.outputURL.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let stats = job.stats {
                        // Surface Cloud-mode usage so the user knows
                        // whether Claude actually fired on this
                        // book. Stats persisted on the Job, not
                        // recomputed.
                        Text(stats.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(statsTooltip(stats))
                    }
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
                .accessibilityLabel("Remove from queue")
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
                .accessibilityLabel("Remove from queue")
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

/// Compact processing-mode badge for the launcher toolbar's
/// `.principal` slot (replacing the old in-content `ModeStrip`).
/// Click → opens Settings → AI so the badge IS the discovery
/// entry point for mode configuration. The badge tints orange
/// in Cloud mode when the user's setup is incomplete (no API
/// key, or every Cloud feature toggled off) so misconfigurations
/// stay surfaced without a separate detail line.
///
/// Refreshes itself off the AISettings store on appear and
/// whenever the Settings sheet might have closed (`scenePhase`
/// transitions). Keeps the badge honest without subscribing to
/// every UserDefaults change.
private struct ModeBadge: View {
    @State private var settings: AISettings = AISettings()
    @State private var hasAPIKey: Bool = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Button {
            // Land on the AI pane: the badge is the user's
            // entry point for "what mode am I in" — that
            // decision lives in AI Settings, not whatever tab
            // was last viewed.
            UserDefaults.standard.set(
                SettingsTab.ai.rawValue,
                forKey: SettingsTab.storageKey
            )
            openSettings()
        } label: {
            badgeLabel
        }
        .buttonStyle(.borderless)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, _ in refresh() }
    }

    @ViewBuilder
    private var badgeLabel: some View {
        switch settings.processingMode {
        case .privateLocal:
            Label("Private", systemImage: "lock.shield")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        case .cloud:
            if isCloudMisconfigured {
                Label("Cloud (setup needed)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
            } else {
                Label("Cloud", systemImage: "cloud")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
            }
        }
    }

    private var isCloudMisconfigured: Bool {
        guard settings.processingMode == .cloud else { return false }
        if !hasAPIKey { return true }
        return enabledFeatureCount(settings.cloudFeatures) == 0
    }

    private var helpText: String {
        switch settings.processingMode {
        case .privateLocal:
            return "Private mode — no data leaves this machine. Click to open AI Settings (⌘,)."
        case .cloud:
            if !hasAPIKey {
                return "Cloud mode but no API key set. Click to open AI Settings (⌘,)."
            }
            let active = enabledFeatureCount(settings.cloudFeatures)
            if active == 0 {
                return "Cloud mode but every Cloud feature is off. Click to open AI Settings (⌘,)."
            }
            return "Cloud mode — \(active) feature\(active == 1 ? "" : "s") enabled, cap \(settings.perBookCallCap) calls/book. Click to open AI Settings (⌘,)."
        }
    }

    private var accessibilityText: String {
        switch settings.processingMode {
        case .privateLocal: return "Processing mode: Private"
        case .cloud:
            return isCloudMisconfigured
                ? "Processing mode: Cloud, setup needed"
                : "Processing mode: Cloud"
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
        // VoiceOver hint — the visual cue is a dashed-border
        // rectangle which doesn't read meaningfully without a
        // label. Drag-drop isn't accessible via keyboard; the
        // bottom bar's "Choose Files or Folder…" button is the
        // keyboard-and-VO equivalent.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isTargeted
            ? "Release to add documents to the queue"
            : "Drop zone for documents")
        .accessibilityHint("Drag PDFs, DOCX, HTML, RTF, MD, or TXT files (or folders) here to add them to the conversion queue. Or use the Choose Files button below for keyboard access.")
    }
}
