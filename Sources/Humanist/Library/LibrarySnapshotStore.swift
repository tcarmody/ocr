import Foundation
import os

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

    /// Minimum interval between snapshots. A burst of rapid edits
    /// — say a user click-fest in the metadata editor or an
    /// automated bulk operation — would otherwise burn through
    /// the retention budget within seconds. With this throttle,
    /// the first edit in a session creates the rollback point and
    /// subsequent edits within the window are folded into the
    /// next-eligible snapshot.
    static let minIntervalBetweenSnapshots: TimeInterval = 60.0

    /// Logger for diagnostic visibility. The snapshot store used
    /// to swallow filesystem errors via `try?`, which made it
    /// hard to diagnose when iCloud Drive's coordinator semantics
    /// caused removeItem / copyItem to fail. With the logger,
    /// failures show up in Console.app under the Humanist app
    /// subsystem so the next regression is actionable.
    private static let log = Logger(
        subsystem: "com.tcarmody.Humanist",
        category: "LibrarySnapshotStore"
    )

    /// Copy the current on-disk catalog (if any) to a fresh
    /// timestamped snapshot, then prune older snapshots beyond
    /// the retention cap. Failures are logged rather than
    /// silently dropped — snapshots are a defensive convenience,
    /// not load-bearing (a failed snapshot must never block a
    /// real save), but a silent failure pattern made an iCloud-
    /// drive regression invisible until the user noticed the
    /// retention cap wasn't holding.
    func snapshotIfPresent() {
        // Nothing to snapshot if the catalog file doesn't exist
        // (first save on a fresh machine). The new save will
        // create it; subsequent saves will get history.
        guard FileManager.default.fileExists(atPath: catalogURL.path)
        else { return }

        // Throttle: skip when the most recent existing snapshot is
        // within the dedup window. A burst of rapid edits should
        // produce one rollback point (state-before-burst), not 30
        // mid-burst snapshots that share ~zero useful divergence.
        if let newest = list().first,
           Date().timeIntervalSince(newest.capturedAt)
              < Self.minIntervalBetweenSnapshots {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: snapshotsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            Self.log.error("snapshot dir create failed: \(error.localizedDescription)")
            return
        }

        let destination = snapshotsDirectory.appendingPathComponent(
            Self.filename(at: Date())
        )

        // Read-then-write rather than `copyItem`: iCloud Drive
        // sources have document-coordinator semantics that
        // sometimes fail FileManager.copyItem silently with no
        // surfaced error. Reading the bytes into memory and
        // writing them out atomically is more robust and barely
        // slower at our catalog size (~1 MB).
        do {
            let data = try Data(contentsOf: catalogURL)
            try data.write(to: destination, options: .atomic)
        } catch {
            Self.log.error(
                "snapshot write failed: \(error.localizedDescription)"
            )
            // Still attempt prune even on snapshot-write failure
            // — old snapshots accumulating is a separate problem
            // from the current write failing.
        }
        prune()
    }

    /// User-triggered snapshot: bypasses the throttle so the user
    /// can always create a fresh rollback point on demand. Used
    /// by the "Snapshot Now" button in the restore sheet.
    func forceSnapshotNow() {
        guard FileManager.default.fileExists(atPath: catalogURL.path)
        else { return }
        do {
            try FileManager.default.createDirectory(
                at: snapshotsDirectory,
                withIntermediateDirectories: true
            )
            let destination = snapshotsDirectory.appendingPathComponent(
                Self.filename(at: Date())
            )
            let data = try Data(contentsOf: catalogURL)
            try data.write(to: destination, options: .atomic)
        } catch {
            Self.log.error(
                "forced snapshot failed: \(error.localizedDescription)"
            )
        }
        prune()
    }

    /// Return the list of snapshots on disk, newest first. Each
    /// entry carries the URL plus a parsed Date — the restore
    /// sheet uses the date for display and the URL for the actual
    /// copy.
    func list() -> [Snapshot] {
        let fm = FileManager.default
        let dir = snapshotsDirectory
        let urls: [URL]
        do {
            // No `options: [.skipsHiddenFiles]`. The snapshots
            // dir lives under `.humanist/` (dot-prefixed parent),
            // and iCloud Drive sets `com.apple.macl` xattrs on
            // synced files; the combination causes
            // `.skipsHiddenFiles` to silently drop every entry,
            // yielding zero URLs from a populated directory. Our
            // filename filter (`library-…`) below catches anything
            // we don't want anyway, so opting in to "hidden file
            // skipping" buys nothing and breaks the iCloud case.
            urls = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            Self.log.error(
                "snapshot list failed at \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
        return urls.compactMap { url -> Snapshot? in
            let name = url.lastPathComponent
            guard name.hasPrefix(Self.filenamePrefix),
                  url.pathExtension == "json",
                  let date = Self.date(from: name)
            else { return nil }
            return Snapshot(url: url, capturedAt: date)
        }.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Replace the live catalog with the contents of `snapshot`.
    /// Takes one final snapshot of the current live catalog first
    /// so the restore itself is reversible — a misclick on the
    /// wrong snapshot doesn't compound the data loss.
    ///
    /// Read-then-write rather than `copyItem` for the same iCloud
    /// robustness reason as `snapshotIfPresent`. The destination
    /// write is atomic so a half-restored catalog can't leave the
    /// user wedged between two states.
    func restore(from snapshot: Snapshot) throws {
        // Force the pre-restore snapshot — user wants this point-
        // in-time saved even if a snapshot was just taken inside
        // the throttle window.
        forceSnapshotNow()
        let data = try Data(contentsOf: snapshot.url)
        try data.write(to: catalogURL, options: .atomic)
    }

    // MARK: - rotation

    private func prune() {
        let snapshots = list()
        guard snapshots.count > Self.retentionCount else { return }
        let toDelete = snapshots.suffix(snapshots.count - Self.retentionCount)
        var failed: [String] = []
        for entry in toDelete {
            do {
                try FileManager.default.removeItem(at: entry.url)
            } catch {
                failed.append(
                    "\(entry.url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        if !failed.isEmpty {
            // Log the first few failures so future regressions
            // surface in Console without spamming on long fail
            // lists. The full list is reconstructable from disk.
            let preview = failed.prefix(3).joined(separator: " | ")
            Self.log.error(
                "snapshot prune: \(failed.count) failed (first: \(preview))"
            )
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
