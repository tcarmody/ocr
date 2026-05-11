import SwiftUI
import AppKit

/// Conversion preferences pane. Holds the output-folder setting that
/// determines where the launcher / queue routes converter artifacts
/// (EPUBs, plain-text + markdown sibling outputs, debug logs).
struct ConversionSettingsView: View {
    /// Needed by the library-sync activation flow so the
    /// migration helper can walk catalog entries when copying
    /// sidecars to the shared root. Optional because the
    /// preferences scene may host the view without environment
    /// plumbing during early app launch.
    @EnvironmentObject private var library: LibraryStore

    @AppStorage(ConversionSettingsKeys.outputFolderPath)
    private var outputFolderPath: String = ""

    @AppStorage(ConversionSettingsKeys.autoScanInputFolder)
    private var autoScanInputFolder: Bool = false

    @AppStorage(ConversionSettingsKeys.skipIndexingOnImport)
    private var skipIndexingOnImport: Bool = false

    @AppStorage(ConversionSettingsKeys.shareLibraryAcrossMachines)
    private var shareLibraryAcrossMachines: Bool = false

    @AppStorage(ConversionSettingsKeys.autoAuthorThreshold)
    private var autoAuthorThreshold: Int = 0  // resolves to default 3 when 0

    /// Set by `runShareMigration()` so the activation sheet
    /// surfaces the outcome (moved / already-migrated / failed /
    /// root missing). Nil = no activation in flight.
    @State private var shareMigrationMessage: String?

    // Conversion defaults — read by `QueueViewModel.init` on launch
    // to seed the launcher's per-conversion toggles. Same UserDefaults
    // domain is read by `Scripts/auto-scan-input.sh` to pass
    // equivalent flags to `humanist-cli` in headless / cron runs.
    @AppStorage(ConversionSettingsKeys.defaultUseSuryaOCR)
    private var defaultUseSuryaOCR: Bool = false
    @AppStorage(ConversionSettingsKeys.defaultUseClaudePageOCR)
    private var defaultUseClaudePageOCR: Bool = false
    @AppStorage(ConversionSettingsKeys.defaultForceOCR)
    private var defaultForceOCR: Bool = false
    @AppStorage(ConversionSettingsKeys.defaultPrivateMode)
    private var defaultPrivateMode: Bool = false
    @AppStorage(ConversionSettingsKeys.defaultEmitDebugLog)
    private var defaultEmitDebugLog: Bool = false
    @AppStorage(ConversionSettingsKeys.defaultEmitSiblingTextOutputs)
    private var defaultEmitSiblingTextOutputs: Bool = true
    @AppStorage(ConversionSettingsKeys.defaultEmitSiblingDocuments)
    private var defaultEmitSiblingDocuments: Bool = false
    @AppStorage(ConversionSettingsKeys.defaultEmitSearchablePDF)
    private var defaultEmitSearchablePDF: Bool = false

    var body: some View {
        Form {
            Section("Output folder") {
                outputFolderRow
                helpText(explanation)
                if !outputFolderPath.isEmpty {
                    layoutPreview
                }
            }
            conversionDefaultsSection
            if !outputFolderPath.isEmpty {
                Section("Auto-scan") {
                    Toggle(
                        "Automatically scan Input folder for new PDFs",
                        isOn: $autoScanInputFolder
                    )
                    helpText("""
                        When on, the launcher watches `Input/` under the output folder. \
                        Drop PDFs in and they get converted automatically with the launcher's current settings — output lands in `Books/`, `Searchable PDFs/`, `Text Files/`, etc. just like a drag-drop conversion. A PDF is skipped once its output EPUB exists; delete the EPUB to re-run.
                        """)
                }
            }
            Section("EPUB import") {
                Toggle(
                    "Skip embedding index build on import",
                    isOn: $skipIndexingOnImport
                )
                helpText("""
                    Useful for bulk imports (hundreds or thousands of books): the importer still injects paragraph anchors, runs on-device metadata + chapter classification, and catalogs each book — but skips the per-book embedding sidecar build that library chat needs for retrieval. Run *Build Missing Indexes* from the Library window (Refresh menu) once the import finishes to fill the sidecars in overnight.
                    """)
            }
            Section("Auto-generated collections") {
                HStack {
                    Text("Author threshold:")
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: {
                                autoAuthorThreshold > 0
                                    ? autoAuthorThreshold
                                    : LibraryAutoCollections.defaultAuthorThreshold
                            },
                            set: { autoAuthorThreshold = $0 }
                        ),
                        in: 2...20
                    ) {
                        Text("\(autoAuthorThreshold > 0 ? autoAuthorThreshold : LibraryAutoCollections.defaultAuthorThreshold)")
                            .monospacedDigit()
                            .frame(minWidth: 24, alignment: .trailing)
                    }
                }
                helpText("Minimum number of books by the same author before an auto-author collection is generated. A larger library wants a higher threshold; default 3.")
            }
            if !outputFolderPath.isEmpty {
                libraryShareSection
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
        .frame(width: 520)
        .frame(minHeight: 460)
    }

    /// Standard subdued help-text styling used throughout the
    /// Settings panes. Single helper so the callout font /
    /// secondary foreground / vertical-fixed-size combo isn't
    /// repeated at every site.
    @ViewBuilder
    private func helpText(_ s: String) -> some View {
        Text(s)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Conversion defaults section. Each toggle seeds the matching
    /// launcher toggle on next launch; per-session overrides made
    /// in the launcher UI don't persist back. The shell companion
    /// reads the same keys and passes equivalent flags to
    /// humanist-cli.
    @ViewBuilder
    private var conversionDefaultsSection: some View {
        Section("Conversion defaults") {
            helpText("These set the initial values of the launcher's toggles each session. Per-conversion changes don't write back here.")
            Toggle("Surya OCR", isOn: $defaultUseSuryaOCR)
            Toggle("Claude OCR ($$$)", isOn: $defaultUseClaudePageOCR)
            Toggle("Force OCR (ignore embedded PDF text)", isOn: $defaultForceOCR)
            Toggle("Private mode (disable every Cloud feature)", isOn: $defaultPrivateMode)
            Toggle("Save log (keep debug staging directory)", isOn: $defaultEmitDebugLog)
        }
        Section("Sibling outputs") {
            Toggle("`.txt` + `.md` siblings", isOn: $defaultEmitSiblingTextOutputs)
            Toggle("`.html` + `.docx` siblings", isOn: $defaultEmitSiblingDocuments)
            Toggle("Searchable PDF (overlay)", isOn: $defaultEmitSearchablePDF)
            HStack {
                Spacer()
                Button("Reset to factory defaults", action: resetConversionDefaults)
                    .controlSize(.small)
            }
        }
    }

    /// R-Library-Sync. Toggle that flips
    /// `shareLibraryAcrossMachines`; first activation runs
    /// `LibrarySyncMigration.runFull(library:)` (catalog +
    /// sidecars + aliases) and prompts a relaunch.
    @ViewBuilder
    private var libraryShareSection: some View {
        Section("Library sync") {
            Toggle(
                "Share library across machines",
                isOn: Binding(
                    get: { shareLibraryAcrossMachines },
                    set: { newValue in
                        shareLibraryAcrossMachines = newValue
                        if newValue {
                            runShareMigration()
                        }
                    }
                )
            )
            helpText("""
                When on, `library.json`, the embedding / hierarchy / entity sidecars, and the alias dictionary all live under `<output folder>/.humanist/` instead of `~/Library/Application Support/`. The same catalog resolves correctly on a second Mac sharing the folder via iCloud / Dropbox / SyncThing. Per-book chat history, the conversion queue, and per-app preferences stay machine-local.

                Toggling this requires an app relaunch to take effect.
                """)
            if let msg = shareMigrationMessage {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runShareMigration() {
        let result = LibrarySyncMigration.runFull(library: library)
        let suffix = sidecarsAliasesSummary(result)
        switch result.catalog {
        case .moved:
            shareMigrationMessage = "Catalog moved to your output folder.\(suffix) Quit and reopen Humanist to start using the shared library."
        case .alreadyMigrated:
            shareMigrationMessage = "Shared catalog already in place.\(suffix) Quit and reopen Humanist if this is a fresh activation."
        case .nothingToMigrate:
            shareMigrationMessage = "No existing library to migrate.\(suffix) Future conversions will write into the shared location after relaunch."
        case .rootMissing:
            shareMigrationMessage = "Pick an output folder above first — the shared library lives under it."
        case .failed(let message):
            shareMigrationMessage = "Migration failed: \(message)"
        }
    }

    private func sidecarsAliasesSummary(
        _ result: LibrarySyncMigration.PhaseBResult
    ) -> String {
        var parts: [String] = []
        if result.sidecarsCopied > 0 {
            let n = result.sidecarsCopied
            parts.append("\(n) embedding sidecar\(n == 1 ? "" : "s") copied")
        }
        if result.aliasesCopied {
            parts.append("alias dictionary copied")
        }
        guard !parts.isEmpty else { return "" }
        return " " + parts.joined(separator: " · ") + "."
    }

    private func resetConversionDefaults() {
        let f = ConversionDefaults.factory
        defaultUseSuryaOCR = f.useSuryaOCR
        defaultUseClaudePageOCR = f.useClaudePageOCR
        defaultForceOCR = f.forceOCR
        defaultPrivateMode = f.privateMode
        defaultEmitDebugLog = f.emitDebugLog
        defaultEmitSiblingTextOutputs = f.emitSiblingTextOutputs
        defaultEmitSiblingDocuments = f.emitSiblingDocuments
        defaultEmitSearchablePDF = f.emitSearchablePDF
    }

    private var explanation: String {
        if outputFolderPath.isEmpty {
            return "When unset, conversions write the EPUB and any sibling text outputs next to the source PDF — the existing behavior. Pick an output folder to centralize new conversions into per-format subfolders."
        } else {
            return "New conversions write into per-format subfolders here. Existing books in their original locations are unaffected."
        }
    }

    @ViewBuilder
    private var outputFolderRow: some View {
        HStack {
            Text("Folder:")
            if outputFolderPath.isEmpty {
                Text("(not set — using source-PDF location)")
                    .foregroundStyle(.secondary)
            } else {
                Text(displayPath(outputFolderPath))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose…") { pickFolder() }
            if !outputFolderPath.isEmpty {
                Button("Reset") { outputFolderPath = "" }
            }
        }
    }

    @ViewBuilder
    private var layoutPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Layout under this folder:")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                folderLine("📥 \(ConversionOutputSubfolder.input)/", "Drop zone — auto-scanned when the toggle below is on")
                folderLine("📚 \(ConversionOutputSubfolder.books)/", "EPUBs — your reading library")
                folderLine("🔎 \(ConversionOutputSubfolder.searchablePDFs)/", "Source PDFs with an invisible OCR text overlay")
                folderLine("📝 \(ConversionOutputSubfolder.textFiles)/", "Plain-text sibling outputs")
                folderLine("📄 \(ConversionOutputSubfolder.markdown)/", "Markdown sibling outputs")
                folderLine("🌐 \(ConversionOutputSubfolder.html)/", "Self-contained HTML sibling outputs")
                folderLine("🪵 \(ConversionOutputSubfolder.logs)/", "Conversion debug staging (when “Emit debug log” is on)")
            }
            .font(.callout.monospaced())
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func folderLine(_ name: String, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .frame(width: 140, alignment: .leading)
            Text(description)
                .foregroundStyle(.secondary)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick a root folder for converted EPUBs, sibling text outputs, and logs."
        if !outputFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: outputFolderPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            outputFolderPath = url.path
        }
    }

    /// Replace the home directory prefix with `~` for compactness.
    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
