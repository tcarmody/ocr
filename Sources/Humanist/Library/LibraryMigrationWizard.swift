import SwiftUI
import AppKit

/// R-Library-Migrate wizard. Multi-step Settings sheet that walks
/// the user through moving the library's user-state files between
/// `Application Support` (local mode) and `<outputRoot>/.humanist/`
/// (cloud mode), or between two different cloud roots.
///
/// Steps:
///   1. **Welcome** — shows current location, prompts destination
///      choice (Local / Cloud folder picker).
///   2. **Pre-flight** — runs `LibraryMigrationService.preflight`;
///      surfaces blocking issues + advisory notes.
///   3. **Copying** — drains `copy(...)` AsyncStream into a progress
///      view; Cancel terminates the copy without flipping any
///      toggles.
///   4. **Verification** — runs `verify(...)` at the destination,
///      reports catalog entry count + sample file presence + any
///      blocking issues. User confirms with "Switch over now" or
///      aborts.
///   5. **Done** — relaunch prompt; the toggle + output folder
///      have already been flipped by step 4's commit.
///
/// State machine: the enum below carries the step + any data the
/// step needs. Transitions are deliberate (button-driven, no
/// auto-advance past Pre-flight) so the user can back out at any
/// point before commit.
struct LibraryMigrationWizard: View {
    let onDismiss: () -> Void

    @State private var step: Step = .welcome
    @State private var destination: LibraryMigrationService.Location?
    @State private var preflight: LibraryMigrationService.Preflight?
    @State private var copyEvents: [LibraryMigrationService.CopyEvent] = []
    @State private var copyTask: Task<Void, Never>?
    @State private var verification: LibraryMigrationService.Verification?
    @State private var commitDone: Bool = false

    enum Step: Equatable {
        case welcome
        case preflight
        case copying
        case verification
        case done
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(24) }
            Divider()
            footer
        }
        .frame(width: 620, height: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.title2)
                .foregroundStyle(HumanistTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Migrate Library")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stepIndicator
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        switch step {
        case .welcome:      return "Choose where the library should live."
        case .preflight:    return "Reviewing the move before any files are copied."
        case .copying:      return "Copying files — don't quit Humanist until this finishes."
        case .verification: return "Double-checking what arrived at the destination."
        case .done:         return "Ready to relaunch into the migrated library."
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 4) {
            ForEach(stepOrder, id: \.self) { s in
                Circle()
                    .fill(stepFill(for: s))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private let stepOrder: [Step] = [.welcome, .preflight, .copying, .verification, .done]

    private func stepFill(for s: Step) -> Color {
        let idx = stepOrder.firstIndex(of: s) ?? 0
        let current = stepOrder.firstIndex(of: step) ?? 0
        if idx < current { return HumanistTheme.accent }
        if idx == current { return HumanistTheme.accent.opacity(0.85) }
        return Color.secondary.opacity(0.25)
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:      welcomeView
        case .preflight:    preflightView
        case .copying:      copyingView
        case .verification: verificationView
        case .done:         doneView
        }
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        let current = LibraryMigrationService.current()
        return VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Currently")
            HStack(spacing: 10) {
                Image(systemName: locationSymbol(for: current))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(locationLabel(for: current))
                        .font(.callout.weight(.medium))
                    Text(current.displayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Divider().padding(.vertical, 2)
            sectionTitle("Move to")
            destinationPicker(currentlyAt: current)
            footnote("""
                What moves: library.json, the alias dictionary, rolling snapshots, cover overrides.

                What stays put: embedding sidecars (per-Mac on purpose — at library scale, iCloud Drive's metadata reads turn every federated-index rebuild into a multi-minute stall). After the migration, this Mac's federated index rebuilds locally on the next library-chat send.
                """)
        }
    }

    private func destinationPicker(
        currentlyAt: LibraryMigrationService.Location
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // "Application Support" option — disabled when already there.
            HStack(spacing: 10) {
                radioButton(selected: destination == .applicationSupport) {
                    destination = .applicationSupport
                }
                .disabled(currentlyAt == .applicationSupport)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Local — Application Support folder")
                        .font(.callout)
                        .foregroundStyle(currentlyAt == .applicationSupport ? .secondary : .primary)
                    Text("Single-machine. No cloud sync overhead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            // Custom local folder — single-Mac, but user-picked
            // location (external SSD, ~/Documents/My Library/, etc.).
            HStack(alignment: .top, spacing: 10) {
                radioButton(selected: destinationIsCustomLocal) {
                    if case .customLocal = destination { return }
                    pickFolder(forCloud: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom folder (this Mac only)")
                        .font(.callout)
                    Text(customLocalDestinationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Button("Choose folder…") { pickFolder(forCloud: false) }
                        .controlSize(.small)
                }
                Spacer()
            }
            .padding(.top, 4)
            // Cloud-synced folder — multi-Mac.
            HStack(alignment: .top, spacing: 10) {
                radioButton(selected: destinationIsCloud) {
                    if case .cloudFolder = destination { return }
                    pickFolder(forCloud: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cloud-synced folder")
                        .font(.callout)
                    Text(cloudDestinationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Button("Choose folder…") { pickFolder(forCloud: true) }
                        .controlSize(.small)
                }
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private var destinationIsCloud: Bool {
        if case .cloudFolder = destination { return true }
        return false
    }

    private var destinationIsCustomLocal: Bool {
        if case .customLocal = destination { return true }
        return false
    }

    private var cloudDestinationLabel: String {
        if case .cloudFolder(let root) = destination {
            return root.appendingPathComponent(".humanist").path
        }
        return "Pick a folder you sync via iCloud Drive, Dropbox, or SyncThing."
    }

    private var customLocalDestinationLabel: String {
        if case .customLocal(let root) = destination {
            return root.appendingPathComponent(".humanist").path
        }
        return "Pick a local folder — external SSD, ~/Documents/My Library/, etc."
    }

    private func pickFolder(forCloud: Bool) {
        let panel = NSOpenPanel()
        panel.title = forCloud
            ? "Choose the cloud-synced folder"
            : "Choose a local folder"
        panel.message = forCloud
            ? "Humanist will write library.json + siblings under <chosen folder>/.humanist/. The catalog stays in sync with other Macs that share this folder."
            : "Humanist will write library.json + siblings under <chosen folder>/.humanist/. Single-machine — no cross-Mac sync."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = forCloud
            ? .cloudFolder(root: url)
            : .customLocal(root: url)
    }

    // MARK: - Pre-flight

    private var preflightView: some View {
        Group {
            if let preflight {
                preflightContent(preflight)
            } else {
                ProgressView("Running pre-flight checks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func preflightContent(
        _ p: LibraryMigrationService.Preflight
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("From")
            locationRow(p.source)
            sectionTitle("To")
            locationRow(p.destination)
            Divider()
            sectionTitle("Pre-flight")
            VStack(alignment: .leading, spacing: 6) {
                statusRow(
                    ok: p.sourceCatalogExists,
                    advisory: !p.sourceCatalogExists,
                    label: "Source catalog present (\(max(p.sourceCatalogEntryCount, 0)) entries)"
                )
                statusRow(
                    ok: p.destinationWritable,
                    label: "Destination is writable"
                )
                statusRow(
                    ok: !p.destinationHasExistingCatalog,
                    label: p.destinationHasExistingCatalog
                        ? "Destination already has a library.json (won't overwrite)"
                        : "Destination has no existing catalog"
                )
                if let needed = p.bytesNeeded, let available = p.bytesAvailable {
                    let fmt = ByteCountFormatter()
                    statusRow(
                        ok: needed < available,
                        label: "Free space: \(fmt.string(fromByteCount: available)) (need \(fmt.string(fromByteCount: needed)))"
                    )
                } else if let needed = p.bytesNeeded {
                    let fmt = ByteCountFormatter()
                    statusRow(
                        ok: true, advisory: true,
                        label: "Free space at destination unknown (will need \(fmt.string(fromByteCount: needed)))"
                    )
                }
            }
            if !p.advisoryNotes.isEmpty {
                Divider()
                ForEach(p.advisoryNotes, id: \.self) { note in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !p.blockingIssues.isEmpty {
                Divider()
                ForEach(p.blockingIssues, id: \.self) { msg in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(msg)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func locationRow(_ loc: LibraryMigrationService.Location) -> some View {
        HStack(spacing: 10) {
            Image(systemName: locationSymbol(for: loc))
                .foregroundStyle(.secondary)
            Text(loc.displayPath)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Copying

    private var copyingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Copying")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(copyPhaseRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Image(systemName: row.symbol)
                            .foregroundStyle(row.color)
                            .frame(width: 16)
                        Text(row.label)
                            .font(.callout)
                            .foregroundStyle(row.isPending ? .secondary : .primary)
                        Spacer()
                        if let progress = row.progress {
                            Text(progress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            if let failure = copyFailureMessage {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private struct CopyPhaseRow {
        let symbol: String
        let label: String
        let progress: String?
        let isPending: Bool
        let color: Color
    }

    /// Derive the four phase rows by inspecting `copyEvents`. Each
    /// phase is one of: pending (gray circle), in-progress (orange
    /// arrow), done (green check). Order is fixed; events stream in
    /// the same order.
    private var copyPhaseRows: [CopyPhaseRow] {
        let started: Set<String> = Set(copyEvents.compactMap { event in
            switch event {
            case .startedCatalog:    return "catalog"
            case .startedAliases:    return "aliases"
            case .startedSnapshots:  return "snapshots"
            case .startedCovers:     return "covers"
            default: return nil
            }
        })
        let finished: Set<String> = Set(copyEvents.compactMap { event in
            switch event {
            case .finishedCatalog:    return "catalog"
            case .finishedAliases:    return "aliases"
            case .finishedSnapshots:  return "snapshots"
            case .finishedCovers:     return "covers"
            default: return nil
            }
        })
        let snapshotProgress = copyEvents.reversed().compactMap { event -> String? in
            if case let .progressedSnapshots(done, total) = event {
                return "\(done) / \(total)"
            }
            return nil
        }.first
        let coverProgress = copyEvents.reversed().compactMap { event -> String? in
            if case let .progressedCovers(done, total) = event {
                return "\(done) / \(total)"
            }
            return nil
        }.first

        func row(key: String, label: String, progress: String? = nil) -> CopyPhaseRow {
            if finished.contains(key) {
                return CopyPhaseRow(
                    symbol: "checkmark.circle.fill",
                    label: label,
                    progress: progress,
                    isPending: false,
                    color: .green
                )
            }
            if started.contains(key) {
                return CopyPhaseRow(
                    symbol: "arrow.right.circle.fill",
                    label: label,
                    progress: progress,
                    isPending: false,
                    color: HumanistTheme.accent
                )
            }
            return CopyPhaseRow(
                symbol: "circle",
                label: label,
                progress: nil,
                isPending: true,
                color: .secondary
            )
        }

        return [
            row(key: "catalog",   label: "Catalog (library.json)"),
            row(key: "aliases",   label: "Alias dictionary"),
            row(key: "snapshots", label: "Snapshots", progress: snapshotProgress),
            row(key: "covers",    label: "Cover overrides", progress: coverProgress),
        ]
    }

    private var copyFailureMessage: String? {
        for event in copyEvents.reversed() {
            if case .failed(let msg) = event { return msg }
        }
        return nil
    }

    private var copyCompleted: Bool {
        copyEvents.contains(.completed)
    }

    // MARK: - Verification

    private var verificationView: some View {
        Group {
            if let v = verification {
                verificationContent(v)
            } else {
                ProgressView("Verifying destination…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func verificationContent(
        _ v: LibraryMigrationService.Verification
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Destination check")
            VStack(alignment: .leading, spacing: 6) {
                statusRow(
                    ok: v.catalogReadable,
                    label: v.catalogReadable
                        ? "Catalog parses cleanly (\(v.catalogEntryCount) entries)"
                        : "Catalog at destination doesn't parse — DON'T commit"
                )
                statusRow(
                    ok: v.aliasesReadable,
                    label: "Alias dictionary readable"
                )
                statusRow(
                    ok: true, advisory: true,
                    label: "Snapshots copied: \(v.snapshotFilesPresent)"
                )
                statusRow(
                    ok: true, advisory: true,
                    label: "Cover overrides copied: \(v.coverFilesPresent)"
                )
            }
            if !v.allOK {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Verification found problems. The source files are untouched; cancel out and try again or pick a different destination.")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Divider()
                footnote("""
                    Source files at \(preflight?.source.displayPath ?? "the old location") are left in place as a backup until you delete them manually.
                    """)
            }
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                Text("Migration complete")
                    .font(.title3.weight(.semibold))
            }
            footnote("""
                The library now lives at:

                \(destination?.displayPath ?? "(unknown)")

                Settings have been updated to read from this location on the next launch. Quit and reopen Humanist to start using the migrated library. Existing windows still hold references to the old location — they'll show stale state until relaunch.
                """)
        }
    }

    // MARK: - Footer (per-step buttons)

    @ViewBuilder
    private var footer: some View {
        HStack {
            if step == .welcome || step == .preflight {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            } else if step == .copying {
                Button("Cancel") { cancelCopy() }
                    .disabled(copyCompleted)
            } else if step == .verification {
                Button("Back") { rollback() }
            } else if step == .done {
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            primaryActionButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch step {
        case .welcome:
            Button("Continue") { advanceFromWelcome() }
                .buttonStyle(.borderedProminent)
                .disabled(destination == nil)
        case .preflight:
            Button("Start Copy") { advanceFromPreflight() }
                .buttonStyle(.borderedProminent)
                .disabled((preflight?.canProceed ?? false) == false)
        case .copying:
            if copyCompleted {
                Button("Continue") { advanceFromCopying() }
                    .buttonStyle(.borderedProminent)
            } else {
                EmptyView()
            }
        case .verification:
            Button("Switch Over Now") { commit() }
                .buttonStyle(.borderedProminent)
                .disabled(!(verification?.allOK ?? false))
        case .done:
            Button("Quit Humanist") { quitForRelaunch() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Transitions

    private func advanceFromWelcome() {
        guard let destination else { return }
        let source = LibraryMigrationService.current()
        step = .preflight
        Task { @MainActor in
            preflight = LibraryMigrationService.preflight(
                source: source, destination: destination
            )
        }
    }

    private func advanceFromPreflight() {
        guard let p = preflight, p.canProceed else { return }
        step = .copying
        copyEvents = []
        let task = Task { @MainActor in
            for await event in LibraryMigrationService.copy(
                source: p.source, destination: p.destination
            ) {
                copyEvents.append(event)
            }
        }
        copyTask = task
    }

    private func cancelCopy() {
        copyTask?.cancel()
        copyTask = nil
        onDismiss()
    }

    private func advanceFromCopying() {
        guard let destination else { return }
        step = .verification
        Task { @MainActor in
            verification = LibraryMigrationService.verify(at: destination)
        }
    }

    private func rollback() {
        // Pre-commit rollback: just close the wizard. No
        // UserDefaults state was touched yet; the source remains
        // authoritative.
        onDismiss()
    }

    private func commit() {
        guard let destination else { return }
        LibraryMigrationService.commit(to: destination)
        commitDone = true
        step = .done
    }

    private func quitForRelaunch() {
        // Honest "quit and reopen" — the migration changes are read
        // at launch time (LibraryStore.resolveStoreURL et al.), and
        // already-open windows hold stale state. Sending NSApp's
        // terminate is the cleanest signal.
        NSApp.terminate(nil)
    }

    // MARK: - Small UI helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private func footnote(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusRow(
        ok: Bool, advisory: Bool = false, label: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol(ok: ok, advisory: advisory))
                .foregroundStyle(statusColor(ok: ok, advisory: advisory))
                .frame(width: 16)
            Text(label)
                .font(.callout)
            Spacer()
        }
    }

    private func statusSymbol(ok: Bool, advisory: Bool) -> String {
        if advisory { return "info.circle" }
        return ok ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }

    private func statusColor(ok: Bool, advisory: Bool) -> Color {
        if advisory { return .secondary }
        return ok ? .green : .orange
    }

    private func locationSymbol(
        for loc: LibraryMigrationService.Location
    ) -> String {
        switch loc {
        case .applicationSupport: return "internaldrive"
        case .customLocal:        return "folder"
        case .cloudFolder:        return "icloud"
        }
    }

    private func locationLabel(
        for loc: LibraryMigrationService.Location
    ) -> String {
        switch loc {
        case .applicationSupport: return "Local — Application Support"
        case .customLocal:        return "Local — custom folder"
        case .cloudFolder:        return "Cloud — shared folder"
        }
    }

    private func radioButton(
        selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? HumanistTheme.accent : .secondary)
                .imageScale(.large)
        }
        .buttonStyle(.plain)
    }
}
