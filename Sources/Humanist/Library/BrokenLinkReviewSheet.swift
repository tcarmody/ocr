import SwiftUI

/// Library window's broken-link / missing-file review sheet.
/// Companion to the silent launch-time prune in
/// `LibraryStore.load`; surfaces the same kind of trouble (the
/// `.epub` isn't openable any more) but with a manual review
/// step so users on external volumes can keep their entries
/// when the drive is just unmounted.
///
/// Three phases:
///   1. **Scanning**: progress bar while `LibraryHealthCheck`
///      walks the catalog. Two checks per entry — fileExists
///      first, then EPUBPackage.open if the file is there.
///   2. **Reviewing**: every broken entry shown with a checkbox
///      (defaults to checked), reason label, last-opened
///      relative date, and full path. The user can uncheck
///      anything they want to keep (e.g. files on a USB drive
///      they'll re-mount, or iCloud-evicted items).
///   3. **Empty**: scan finished and the catalog is clean.
///
/// Removal uses the existing `LibraryStore.remove(_:)` per
/// entry, wrapped in a single bulk-update window so the catalog
/// saves once and collection memberships get cleaned up the
/// same way they would for any other delete.
@MainActor
final class BrokenLinkReviewModel: ObservableObject {

    enum Phase: Equatable {
        case scanning(completed: Int, total: Int)
        case reviewing
        case empty
        case applying(completed: Int, total: Int)
    }

    @Published var phase: Phase = .scanning(completed: 0, total: 0)
    @Published var broken: [BrokenLibraryEntry] = []
    /// Per-entry selection — true = "remove this on Apply".
    /// Defaults to true for every detected entry; the user can
    /// uncheck to keep specific ones.
    @Published var selectedToRemove: Set<UUID> = []
    /// Backing task for the scan, so the Cancel button can stop
    /// a long scan mid-flight without leaving the model wedged
    /// in `.scanning`.
    private var scanTask: Task<Void, Never>?

    /// Snapshot the catalog and kick off the scan. The model
    /// holds the result list and progress state; the view just
    /// renders the current phase.
    func startScan(entries: [LibraryEntry]) {
        phase = .scanning(completed: 0, total: entries.count)
        selectedToRemove = []
        broken = []
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let results = await LibraryHealthCheck.scan(
                entries: entries,
                progress: { [weak self] completed, total in
                    await MainActor.run {
                        self?.phase = .scanning(
                            completed: completed, total: total
                        )
                    }
                }
            )
            await MainActor.run {
                guard let self else { return }
                self.broken = results
                self.selectedToRemove = Set(results.map(\.id))
                self.phase = results.isEmpty ? .empty : .reviewing
            }
        }
    }

    /// User cancelled mid-scan. Stops the in-flight scan; the
    /// caller dismisses the sheet right after.
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// Apply path — remove every entry the user left checked.
    /// One bulk-update window so the catalog save fires once
    /// and collection-membership cleanup happens per-entry via
    /// `LibraryStore.remove`.
    func apply(library: LibraryStore) async {
        let targets = broken.filter { selectedToRemove.contains($0.id) }
        guard !targets.isEmpty else { return }
        phase = .applying(completed: 0, total: targets.count)
        library.beginBulkUpdate()
        defer { library.endBulkUpdate() }
        for (i, item) in targets.enumerated() {
            library.remove(item.id)
            phase = .applying(completed: i + 1, total: targets.count)
        }
    }

    /// Used by the Apply button label so it reads "Remove 3
    /// Entries" rather than "Remove Entries" / "Remove 0".
    var selectedCount: Int { selectedToRemove.count }
}

struct BrokenLinkReviewSheet: View {
    @ObservedObject var model: BrokenLinkReviewModel
    let library: LibraryStore
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var header: some View {
        HStack {
            Image(systemName: "questionmark.folder")
                .foregroundStyle(.secondary)
            Text("Find Missing Files")
                .font(.headline)
            Spacer()
            switch model.phase {
            case .scanning(let c, let t):
                Text("Checking \(c) of \(t)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case .reviewing:
                Text("\(model.broken.count) broken")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .applying(let c, let t):
                Text("Removing \(c) of \(t)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case .empty:
                Text("All clear")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .scanning(let c, let t):
            VStack(spacing: 12) {
                Spacer()
                ProgressView(value: t > 0 ? Double(c) / Double(t) : 0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)
                Text("Verifying that every book in the library opens — large libraries take a minute.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
            }
        case .applying(let c, let t):
            VStack(spacing: 12) {
                Spacer()
                ProgressView(value: t > 0 ? Double(c) / Double(t) : 0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)
                Text("Removing selected entries from the catalog.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .empty:
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No broken entries.")
                    .font(.headline)
                Text("Every book in the library is present and opens cleanly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .reviewing:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    introBanner
                    ForEach(model.broken) { item in
                        brokenRow(item)
                    }
                }
                .padding()
            }
        }
    }

    /// One-time explainer banner above the list. Tells the
    /// user what they're looking at + reminds them they can
    /// uncheck rows to keep entries on temporarily-offline
    /// volumes.
    private var introBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("These entries point to files that are missing or won't open.")
                    .font(.callout)
                Text("Uncheck any you want to keep — for example, books on an external drive that isn't connected right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 6)
    }

    private func brokenRow(_ item: BrokenLibraryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(
                get: { model.selectedToRemove.contains(item.id) },
                set: { isOn in
                    if isOn {
                        model.selectedToRemove.insert(item.id)
                    } else {
                        model.selectedToRemove.remove(item.id)
                    }
                }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.entry.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    reasonBadge(item.reason)
                    Spacer()
                    Text(lastOpenedLabel(item.entry))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(item.entry.epubURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .unopenable(let msg) = item.reason, !msg.isEmpty {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func reasonBadge(_ reason: BrokenLibraryEntry.Reason) -> some View {
        let color: Color = {
            switch reason {
            case .missing: return .red
            case .unopenable: return .orange
            }
        }()
        return Text(reason.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func lastOpenedLabel(_ entry: LibraryEntry) -> String {
        guard let last = entry.lastOpened else { return "—" }
        return Self.relativeFormatter.localizedString(
            for: last, relativeTo: Date()
        )
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch model.phase {
            case .scanning:
                Button("Cancel") {
                    model.cancelScan()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
            case .reviewing:
                Button("Select All") {
                    model.selectedToRemove = Set(model.broken.map(\.id))
                }
                .disabled(model.selectedToRemove.count == model.broken.count)
                Button("Select None") {
                    model.selectedToRemove = []
                }
                .disabled(model.selectedToRemove.isEmpty)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(applyButtonLabel) {
                    Task {
                        await model.apply(library: library)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedCount == 0)
            case .empty:
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            case .applying:
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding()
    }

    private var applyButtonLabel: String {
        let n = model.selectedCount
        if n == 1 { return "Remove 1 Entry" }
        return "Remove \(n) Entries"
    }
}
