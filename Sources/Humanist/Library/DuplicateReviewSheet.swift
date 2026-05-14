import SwiftUI

/// Library window's duplicate-review sheet. Three states:
///
///   1. **Detecting**: shows a progress bar while the
///      `DuplicateDetector` walks the catalog (heaviest step is
///      the EPUB-hash pass for tier-1 detection).
///   2. **Reviewing**: shows every duplicate group; each group
///      has a "Keep" radio selecting the canonical entry and a
///      "Skip" toggle to leave the group untouched.
///   3. **Applying**: shows progress while the apply path trashes
///      EPUBs, removes entries, reassigns collection memberships,
///      and stamps source hashes into the rejected set. All wrapped
///      in a single bulk window so the catalog save fires once.
///
/// Closes when the apply completes or the user cancels. Throws
/// errors aggregated into `applyErrors` for the post-apply
/// summary line.
@MainActor
final class DuplicateReviewModel: ObservableObject {

    enum Phase: Equatable {
        case detecting(completed: Int, total: Int)
        case reviewing
        case applying(completed: Int, total: Int)
        case empty   // detection finished, no groups found
    }

    @Published var phase: Phase = .detecting(completed: 0, total: 0)
    @Published var groups: [DuplicateDetector.Group] = []
    /// Per-group: the entry the user has picked as canonical.
    /// Seeded from the detector's heuristic; user can override.
    @Published var canonicalByGroup: [UUID: UUID] = [:]
    /// Per-group: when true, the group is skipped at Apply time.
    /// Used by the user to defer / mark a false positive.
    @Published var skippedGroups: Set<UUID> = []
    /// Per-row: when true, this non-canonical entry is also kept
    /// (counted as "false positive in the group"). Default false.
    @Published var keepBothPerEntry: Set<UUID> = []
    /// Per-entry trash flag — defaults true. False means
    /// "remove from library but leave the EPUB on disk".
    @Published var trashFileByEntry: [UUID: Bool] = [:]
    /// Applies in flight to the user — surfaced in the post-
    /// apply alert.
    @Published var applyErrors: [String] = []

    /// Catalog snapshot — captured at detection start so the model
    /// can re-render previews even while the live LibraryStore
    /// mutates (post-apply).
    @Published private(set) var entriesByID: [UUID: LibraryEntry] = [:]

    /// Kick off detection. The library snapshot stays in
    /// `entriesByID` for later rendering.
    func startDetection(entries: [LibraryEntry]) async {
        entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        phase = .detecting(completed: 0, total: entries.count)
        let groups = await DuplicateDetector.detect(
            in: entries,
            progress: { [weak self] completed, total in
                await MainActor.run {
                    self?.phase = .detecting(completed: completed, total: total)
                }
            }
        )
        self.groups = groups
        canonicalByGroup = Dictionary(uniqueKeysWithValues:
            groups.map { ($0.id, $0.suggestedCanonicalID) }
        )
        // Pre-seed trash defaults: yes for non-canonical, no for
        // canonical (which won't be removed anyway). Set keeps
        // its default of "trash" implicitly through dictionary
        // miss → true semantics in the apply path; just stamp
        // canonical IDs as false to be explicit.
        for group in groups {
            for entry in group.entries {
                trashFileByEntry[entry.id] = entry.id != canonicalByGroup[group.id]
            }
        }
        phase = groups.isEmpty ? .empty : .reviewing
    }

    /// Counts surfaced in the Apply button label.
    func actionSummary() -> (trash: Int, remove: Int) {
        var trash = 0
        var remove = 0
        for group in groups where !skippedGroups.contains(group.id) {
            guard let canonical = canonicalByGroup[group.id] else { continue }
            for entry in group.entries where entry.id != canonical {
                if keepBothPerEntry.contains(entry.id) { continue }
                remove += 1
                if trashFileByEntry[entry.id] ?? true { trash += 1 }
            }
        }
        return (trash, remove)
    }

    /// Apply path. Runs inside `library.beginBulkUpdate /
    /// endBulkUpdate` so the catalog saves once. For each group:
    ///   * Gather the collections each non-canonical entry
    ///     belongs to.
    ///   * Trash the EPUB (when the per-entry flag is on).
    ///   * Remove the entry from the catalog.
    ///   * Add the canonical entry's id to every collection the
    ///     trashed entries were members of (preserves curation).
    ///   * Stamp the non-canonical entries' `sourceContentHashes`
    ///     into `rejectedSourceHashes` so the auto-scanner won't
    ///     re-pick-up their source PDFs.
    func apply(
        library: LibraryStore,
        coverCache: CoverImageCache
    ) async {
        // Build the work list before starting so we can drive a
        // useful progress bar.
        struct Action {
            let entryID: UUID
            let epubURL: URL
            let trashFile: Bool
            let sourceHashes: [String]
            let collectionMemberships: [UUID]
            let canonicalID: UUID
        }
        var actions: [Action] = []
        let collectionsSnapshot = library.collections
        for group in groups where !skippedGroups.contains(group.id) {
            guard let canonical = canonicalByGroup[group.id] else { continue }
            for entry in group.entries where entry.id != canonical {
                if keepBothPerEntry.contains(entry.id) { continue }
                let memberships = collectionsSnapshot
                    .filter { $0.bookIDs.contains(entry.id) }
                    .map(\.id)
                actions.append(Action(
                    entryID: entry.id,
                    epubURL: entry.epubURL,
                    trashFile: trashFileByEntry[entry.id] ?? true,
                    sourceHashes: entry.sourceContentHashes,
                    collectionMemberships: memberships,
                    canonicalID: canonical
                ))
            }
        }
        phase = .applying(completed: 0, total: actions.count)

        library.beginBulkUpdate()
        defer { library.endBulkUpdate() }

        // Accumulate the canonical → collections set so we can
        // batch the addToCollection calls per canonical (avoids
        // adding the same canonical to the same collection N
        // times when N non-canonical members all belonged).
        var reassignTargets: [UUID: Set<UUID>] = [:]   // canonical → collection ids
        var rejectedHashes: [String] = []

        for (i, action) in actions.enumerated() {
            coverCache.invalidate(action.epubURL)
            if action.trashFile {
                do {
                    try FileManager.default.trashItem(
                        at: action.epubURL, resultingItemURL: nil
                    )
                } catch {
                    applyErrors.append(
                        "\(action.epubURL.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
            library.remove(action.entryID)
            for cid in action.collectionMemberships {
                reassignTargets[action.canonicalID, default: []].insert(cid)
            }
            rejectedHashes.append(contentsOf: action.sourceHashes)
            phase = .applying(completed: i + 1, total: actions.count)
        }

        // Reassign collection memberships in one pass per
        // canonical (skipped silently if the canonical was
        // already a member of the collection — addToCollection
        // filters duplicates).
        for (canonical, collections) in reassignTargets {
            for collectionID in collections {
                library.addToCollection(collectionID, bookIDs: [canonical])
            }
        }
        if !rejectedHashes.isEmpty {
            library.markSourcesRejected(rejectedHashes)
        }
    }
}

/// SwiftUI sheet for reviewing + applying duplicate-group actions.
struct DuplicateReviewSheet: View {
    @ObservedObject var model: DuplicateReviewModel
    let library: LibraryStore
    let coverCache: CoverImageCache
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var header: some View {
        HStack {
            Image(systemName: "doc.on.doc.fill")
                .foregroundStyle(.secondary)
            Text("Detect Duplicates")
                .font(.headline)
            Spacer()
            switch model.phase {
            case .detecting(let c, let t):
                Text("Scanning \(c) of \(t)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case .reviewing:
                Text("\(model.groups.count) group\(model.groups.count == 1 ? "" : "s") found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .applying(let c, let t):
                Text("Applying \(c) of \(t)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case .empty:
                Text("No duplicates found")
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
        case .detecting(let c, let t):
            VStack(spacing: 12) {
                Spacer()
                ProgressView(value: t > 0 ? Double(c) / Double(t) : 0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)
                Text("Hashing EPUBs — this can take a minute on a large library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .applying(let c, let t):
            VStack(spacing: 12) {
                Spacer()
                ProgressView(value: t > 0 ? Double(c) / Double(t) : 0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)
                Text("Trashing duplicates and updating the catalog.")
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
                Text("Library is clean.")
                    .font(.headline)
                Text("No duplicate groups detected across any of the four checks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .reviewing:
            ScrollView {
                LazyVStack(spacing: 16, pinnedViews: []) {
                    ForEach(model.groups) { group in
                        groupCard(group)
                    }
                }
                .padding()
            }
        }
    }

    private func groupCard(_ group: DuplicateDetector.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.tier.displayLabel)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(tierColor(group.tier).opacity(0.18))
                    .clipShape(Capsule())
                Text("\(group.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Skip", isOn: Binding(
                    get: { model.skippedGroups.contains(group.id) },
                    set: { isOn in
                        if isOn { model.skippedGroups.insert(group.id) }
                        else { model.skippedGroups.remove(group.id) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            ForEach(group.entries) { entry in
                entryRow(group: group, entry: entry)
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(model.skippedGroups.contains(group.id) ? 0.5 : 1)
    }

    private func entryRow(
        group: DuplicateDetector.Group,
        entry: LibraryEntry
    ) -> some View {
        let isCanonical = model.canonicalByGroup[group.id] == entry.id
        let keepBoth = model.keepBothPerEntry.contains(entry.id)
        return HStack(alignment: .top, spacing: 10) {
            Button {
                model.canonicalByGroup[group.id] = entry.id
                // Update per-entry trash defaults to match the
                // new canonical (canonical never trashed).
                for member in group.entries {
                    model.trashFileByEntry[member.id] = member.id != entry.id
                }
            } label: {
                Image(systemName: isCanonical
                      ? "largecircle.fill.circle"
                      : "circle")
                    .foregroundStyle(isCanonical ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.body.weight(isCanonical ? .semibold : .regular))
                Text(entry.epubURL.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                metaLine(entry)
            }
            Spacer()
            if !isCanonical {
                VStack(alignment: .trailing, spacing: 4) {
                    Toggle("Keep both", isOn: Binding(
                        get: { keepBoth },
                        set: { isOn in
                            if isOn { model.keepBothPerEntry.insert(entry.id) }
                            else { model.keepBothPerEntry.remove(entry.id) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    if !keepBoth {
                        Toggle("Trash file", isOn: Binding(
                            get: { model.trashFileByEntry[entry.id] ?? true },
                            set: { model.trashFileByEntry[entry.id] = $0 }
                        ))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    }
                }
                .frame(width: 110, alignment: .trailing)
            }
        }
        .padding(8)
        .background(isCanonical
            ? Color.accentColor.opacity(0.06)
            : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func metaLine(_ entry: LibraryEntry) -> some View {
        let parts: [String] = [
            entry.author.map { "by \($0)" } ?? "",
            "added \(formattedDate(entry.addedAt))",
            entry.lastOpened.map { "opened \(formattedDate($0))" } ?? "",
            sizeString(for: entry.epubURL)
        ].filter { !$0.isEmpty }
        Text(parts.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func tierColor(_ tier: DuplicateDetector.Tier) -> Color {
        switch tier {
        case .identicalEPUBs:        return .red
        case .sharedSourceHash:      return .orange
        case .identicalTitleAuthor:  return .yellow
        case .fuzzyTitleMatch:       return .blue
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Spacer()
            switch model.phase {
            case .reviewing:
                let summary = model.actionSummary()
                Text(summaryString(trash: summary.trash, remove: summary.remove))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(applyButtonLabel(trash: summary.trash, remove: summary.remove)) {
                    Task {
                        await model.apply(library: library, coverCache: coverCache)
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(summary.remove == 0)
                .keyboardShortcut(.defaultAction)
            case .empty:
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .detecting, .applying:
                EmptyView()
            }
        }
        .padding()
    }

    private func summaryString(trash: Int, remove: Int) -> String {
        if remove == 0 { return "No actions selected" }
        let trashPart = trash > 0
            ? "trash \(trash) file\(trash == 1 ? "" : "s")"
            : "leave EPUB files"
        return "Will remove \(remove) entr\(remove == 1 ? "y" : "ies") + \(trashPart)"
    }

    private func applyButtonLabel(trash: Int, remove: Int) -> String {
        if remove == 0 { return "Apply" }
        return "Apply (\(remove))"
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }

    private func sizeString(for url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ), let size = (attrs[.size] as? NSNumber)?.intValue
        else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}
