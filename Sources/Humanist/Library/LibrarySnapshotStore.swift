import Foundation

/// Rolling snapshot of `library.json`. Every successful save in
/// `LibraryStore` first copies the previous on-disk catalog into a
/// timestamped sibling file under `<storeDir>/snapshots/`, so a
/// buggy save, an iCloud sync conflict, or a `load()` prune doesn't
/// silently destroy hand-edited metadata. The user recovers via the
/// Library window's Restore Catalog sheet.
///
/// Disk cost: snapshots are full copies of `library.json` (~1 MB
/// for a 2k-book catalog). With a 20-snapshot cap, worst case is
/// ~20 MB of history — cheap insurance against losing hours of
/// metadata work. Older snapshots are pruned on every save.
///
/// Non-actor-isolated so the helper can be called from save()
/// without an `await`. All operations are FileManager calls
/// against per-user paths; no cross-thread state.
struct LibrarySnapshotStore {
    let catalogURL: URL

    /// Directory holding the rolling snapshots. Sibling to the
    /// `library.json` file itself, named `snapshots/` — discoverable
    /// in Finder when the user reveals the iCloud Humanist folder.
    var snapshotsDirectory: URL {
        catalogURL.deletingLastPathComponent()
            .appendingPathComponent("snapshots", isDirectory: true)
    }

    /// Cap on the number of snapshots kept. Saves are typically
    /// rare (one per user edit + one per bulk operation), so 20
    /// snapshots covers days of activity even for heavy use.
    static let retentionCount: Int = 20

    /// Copy the current on-disk catalog (if any) to a fresh
    /// timestamped snapshot, then prune older snapshots beyond
    /// the retention cap. Silent on failure: snapshots are a
    /// defensive convenience, not load-bearing — a failed snapshot
    /// must NEVER block a real save.
    func snapshotIfPresent() {
        // Nothing to snapshot if the catalog file doesn't exist
        // (first save on a fresh machine). The new save will
        // create it; subsequent saves will get history.
        guard FileManager.default.fileExists(atPath: catalogURL.path)
        else { return }
        try? FileManager.default.createDirectory(
            at: snapshotsDirectory,
            withIntermediateDirectories: true
        )
        let destination = snapshotsDirectory.appendingPathComponent(
            Self.filename(at: Date())
        )
        // Use copyItem so the source library.json stays in place
        // while save() writes the new content over it. If a
        // snapshot with this exact timestamp already exists
        // (rapid back-to-back saves within the same second),
        // overwrite — the older one is already on disk and
        // valuable as a same-second snapshot would be noise.
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: catalogURL, to: destination)
        prune()
    }

    /// Return the list of snapshots on disk, newest first. Each
    /// entry carries the URL plus a parsed Date — the restore
    /// sheet uses the date for display and the URL for the actual
    /// copy.
    func list() -> [Snapshot] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: snapshotsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url -> Snapshot? in
            guard url.lastPathComponent.hasPrefix(Self.filenamePrefix),
                  url.pathExtension == "json",
                  let date = Self.date(from: url.lastPathComponent)
            else { return nil }
            return Snapshot(url: url, capturedAt: date)
        }.sorted { $0.capturedAt > $1.capturedAt }  // newest first
    }

    /// Replace the live catalog with the contents of `snapshot`.
    /// Takes one final snapshot of the current live catalog first
    /// so the restore itself is reversible — a misclick on the
    /// wrong snapshot doesn't compound the data loss.
    func restore(from snapshot: Snapshot) throws {
        snapshotIfPresent()  // archive the about-to-be-replaced state
        let fm = FileManager.default
        try? fm.removeItem(at: catalogURL)
        try fm.copyItem(at: snapshot.url, to: catalogURL)
    }

    // MARK: - rotation

    private func prune() {
        let snapshots = list()
        guard snapshots.count > Self.retentionCount else { return }
        let toDelete = snapshots.suffix(snapshots.count - Self.retentionCount)
        for entry in toDelete {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    // MARK: - filename encoding

    private static let filenamePrefix = "library-"

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        // Sort-friendly: lexicographic order matches chronological
        // order. Hyphen-separated for readability in Finder.
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static func filename(at date: Date) -> String {
        "\(filenamePrefix)\(filenameFormatter.string(from: date)).json"
    }

    private static func date(from filename: String) -> Date? {
        guard filename.hasPrefix(filenamePrefix),
              filename.hasSuffix(".json")
        else { return nil }
        let inner = filename
            .dropFirst(filenamePrefix.count)
            .dropLast(".json".count)
        return filenameFormatter.date(from: String(inner))
    }
}

/// One snapshot entry. The catalog stats (entries/author/genre
/// counts) are computed lazily by the restore sheet; carrying just
/// the URL + date here keeps the list cheap to enumerate.
struct Snapshot: Identifiable, Hashable, Sendable {
    let url: URL
    let capturedAt: Date

    var id: URL { url }
}

/// Stats peeked from a snapshot JSON file — used in the restore
/// sheet's per-row preview so the user can pick the right snapshot
/// without restoring blindly. Decoded once per row on demand; the
/// catalog format here mirrors `LibraryStore.StoredPayload` but
/// only carries the fields we display.
struct SnapshotStats: Sendable {
    let totalEntries: Int
    let entriesWithAuthor: Int
    let entriesWithGenre: Int
    let entriesNonDigital: Int

    static func read(from url: URL) -> SnapshotStats? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        struct PeekEntry: Decodable {
            let author: String?
            let genre: String?
            let conversionType: String?
        }
        struct PeekPayload: Decodable {
            let entries: [PeekEntry]
        }
        guard let payload = try? JSONDecoder().decode(
            PeekPayload.self, from: data
        ) else { return nil }
        var withAuthor = 0
        var withGenre = 0
        var nonDigital = 0
        for entry in payload.entries {
            if let a = entry.author, !a.isEmpty { withAuthor += 1 }
            if let g = entry.genre, !g.isEmpty { withGenre += 1 }
            if let t = entry.conversionType, t != "digital" {
                nonDigital += 1
            }
        }
        return SnapshotStats(
            totalEntries: payload.entries.count,
            entriesWithAuthor: withAuthor,
            entriesWithGenre: withGenre,
            entriesNonDigital: nonDigital
        )
    }
}
