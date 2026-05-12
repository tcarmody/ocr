import SwiftUI

/// Sheet for selecting + restoring a previous catalog snapshot.
/// Driven from the Library window's "Restore Library Catalog…"
/// affordance. Lists snapshots newest-first with a per-row preview
/// (entry count + how many have author + how many have genre +
/// how many are non-`.digital`) so the user can choose between a
/// recent backup and an older one with more metadata intact.
///
/// Restoring is reversible: the snapshot store snapshots the
/// live catalog one more time before swapping, so a misclick is
/// undoable via the same sheet on a second pass.
struct SnapshotRestoreSheet: View {
    let store: LibrarySnapshotStore
    let onRestore: (Snapshot) -> Void
    let onCancel: () -> Void

    @State private var snapshots: [Snapshot] = []
    @State private var statsByID: [Snapshot.ID: SnapshotStats] = [:]
    @State private var selection: Snapshot.ID?
    @State private var confirming: Snapshot?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
        .onAppear(perform: reload)
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirming
        ) { target in
            Button("Restore", role: .destructive) {
                onRestore(target)
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { _ in
            Text("Your current catalog will be snapshotted first, so this is reversible.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.tint)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore Library Catalog")
                    .font(.headline)
                Text("Pick a previous catalog to restore. Snapshots are taken automatically before every catalog write.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if snapshots.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("No snapshots yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Snapshots accumulate automatically as you edit metadata, run Refresh, classify genres, or import books — at most one per minute so a burst of edits doesn't burn through history. Click Snapshot Now below to create one on demand before a risky operation.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            List(selection: $selection) {
                ForEach(snapshots) { snapshot in
                    snapshotRow(snapshot)
                        .tag(Snapshot.ID?.some(snapshot.id))
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func snapshotRow(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(snapshot.capturedAt, format: .dateTime
                    .month(.abbreviated)
                    .day().year()
                    .hour().minute())
                    .font(.callout.weight(.medium))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(snapshot.capturedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let stats = statsByID[snapshot.id] {
                statsLine(stats)
            } else {
                Text("Reading…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            if statsByID[snapshot.id] == nil {
                hydrateStats(for: snapshot)
            }
        }
    }

    @ViewBuilder
    private func statsLine(_ stats: SnapshotStats) -> some View {
        HStack(spacing: 8) {
            statsBadge(
                "\(stats.totalEntries) book\(stats.totalEntries == 1 ? "" : "s")",
                systemImage: "books.vertical")
            statsBadge(
                "\(stats.entriesWithAuthor) author\(stats.entriesWithAuthor == 1 ? "" : "s")",
                systemImage: "person",
                emphasizeMissing: stats.entriesWithAuthor == 0)
            statsBadge(
                "\(stats.entriesWithGenre) genre\(stats.entriesWithGenre == 1 ? "" : "s")",
                systemImage: "tag",
                emphasizeMissing: stats.entriesWithGenre == 0)
            statsBadge(
                "\(stats.entriesNonDigital) non-digital",
                systemImage: "doc.text")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func statsBadge(
        _ text: String,
        systemImage: String,
        emphasizeMissing: Bool = false
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
        }
        .foregroundStyle(emphasizeMissing ? .orange : .secondary)
    }

    private var footer: some View {
        HStack {
            // "Done" rather than "Cancel" because the sheet is a
            // viewer with two side-actions (Snapshot Now /
            // Restore Selected) — leaving via the dismiss button
            // doesn't undo anything. Both Snapshot Now and
            // Restore commit on their own button press. Escape
            // still dismisses via the cancellation shortcut.
            Button("Done", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Snapshot Now") {
                store.forceSnapshotNow()
                reload()
            }
            .help("Capture the current catalog state as a new rollback point. Bypasses the auto-snapshot throttle so you always have a fresh restore target before risky operations.")
            Spacer()
            if let selectedID = selection,
               let target = snapshots.first(where: { $0.id == selectedID }) {
                Button("Restore Selected") {
                    confirming = target
                }
                .keyboardShortcut(.defaultAction)
                .disabled(snapshots.isEmpty)
            } else {
                Button("Restore Selected") { }
                    .disabled(true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var confirmationTitle: String {
        guard let target = confirming else { return "" }
        return "Restore catalog from \(target.capturedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))?"
    }

    private func reload() {
        snapshots = store.list()
        statsByID.removeAll(keepingCapacity: true)
    }

    private func hydrateStats(for snapshot: Snapshot) {
        let url = snapshot.url
        let id = snapshot.id
        Task.detached(priority: .userInitiated) {
            let stats = SnapshotStats.read(from: url)
            await MainActor.run {
                if let stats { statsByID[id] = stats }
            }
        }
    }
}
