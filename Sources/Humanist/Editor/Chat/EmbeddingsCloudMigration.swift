import Foundation

/// One-shot migration that pulls embedding sidecars out of the
/// iCloud-synced output root (`<root>/.humanist/Embeddings/`) and
/// into the local Application Support directory
/// (`~/Library/Application Support/Humanist/Embeddings/`).
///
/// Why: an earlier release stored UUID-keyed sidecars in iCloud
/// when the share-library-across-machines toggle was on, on the
/// theory that a second Mac shouldn't have to re-embed the same
/// books. In practice the embedding cache grows to tens of GB and
/// thousands of files; iCloud Drive's metadata-coordinated reads
/// turn every federated-index rebuild into a multi-minute stall
/// (each `Data(contentsOf:)` hits the iCloud daemon, evicted
/// files block-fault on download). Embeddings are now local-only;
/// the share toggle still covers `library.json` and aliases, but
/// embeddings get rebuilt per-Mac instead.
///
/// Semantics:
///   * Idempotent. A UserDefaults flag tracks completion so the
///     migration runs once per Mac; subsequent launches no-op.
///   * Move (not copy). Frees the iCloud space on the same pass.
///     Local-already-exists wins — we never overwrite a local
///     sidecar with a stale iCloud one (the local file is by
///     definition newer if the user has been chatting since the
///     iCloud version was written).
///   * Best-effort per file. One failed move doesn't abort the
///     rest; we count failures and surface them in the return
///     value for logging.
enum EmbeddingsCloudMigration {

    /// User-defaults key marking the migration as complete on this
    /// Mac. Set after a successful run regardless of how many
    /// files actually moved — "no files to move" still counts as
    /// done.
    static let completedDefaultsKey = "humanist.embeddings.iCloudMigrationCompleted"

    /// Per-run report. Surfaced in NSLog so we can tell from the
    /// console whether the launch-time migration found anything.
    struct Result: Equatable {
        /// Files successfully moved iCloud → local.
        let moved: Int
        /// Files that already had a local copy — left in iCloud
        /// for the user to delete via Finder. Defensive: a
        /// background iCloud-daemon write can race the launch
        /// migration, so we prefer leaving a duplicate over
        /// losing a fresh local write.
        let skippedLocalExists: Int
        /// Files we couldn't move (permissions, iCloud not
        /// downloaded, etc.). Best-effort: failures don't abort
        /// the walk.
        let failed: Int
        /// True when the iCloud Embeddings directory existed and
        /// had files at the start of the run. Useful for log copy
        /// ("nothing to migrate" vs. "moved N").
        let scannedICloudDir: Bool
    }

    /// Run the migration unless we've already done so on this Mac.
    /// Returns nil when the run was skipped (flag set, or the
    /// iCloud output root isn't configured). Safe to call from
    /// app launch — does no work on the second+ launch.
    @discardableResult
    static func runIfNeeded() -> Result? {
        if UserDefaults.standard.bool(forKey: completedDefaultsKey) {
            return nil
        }
        // Resolve the iCloud-side directory by hand rather than
        // through ConversionOutputResolver — the resolver's
        // currentRoot() rejects a missing folder, but we still
        // want to record "nothing to migrate" + set the flag on a
        // user who's never enabled sharing.
        let cloudDir = iCloudEmbeddingsDir()
        let localDir = localEmbeddingsDir()

        let result = migrate(from: cloudDir, to: localDir)
        UserDefaults.standard.set(true, forKey: completedDefaultsKey)
        logSummary(result)
        return result
    }

    /// Test seam — does the actual move work without touching
    /// UserDefaults or NSLog. Exposed `internal` so unit tests can
    /// exercise it on temp directories.
    static func migrate(from cloudDir: URL?, to localDir: URL) -> Result {
        try? FileManager.default.createDirectory(
            at: localDir, withIntermediateDirectories: true
        )
        guard let cloudDir,
              FileManager.default.fileExists(atPath: cloudDir.path) else {
            return Result(moved: 0, skippedLocalExists: 0, failed: 0,
                          scannedICloudDir: false)
        }
        let names: [String]
        do {
            names = try FileManager.default
                .contentsOfDirectory(atPath: cloudDir.path)
        } catch {
            return Result(moved: 0, skippedLocalExists: 0, failed: 0,
                          scannedICloudDir: false)
        }
        var moved = 0
        var skipped = 0
        var failed = 0
        for name in names {
            // Only touch `.json` sidecars. Anything else under the
            // dir (stray `.DS_Store`, `.icloud` placeholders for
            // dataless files, in-flight tempfiles) is left alone.
            guard name.hasSuffix(".json") else { continue }
            let src = cloudDir.appendingPathComponent(name)
            let dst = localDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dst.path) {
                skipped += 1
                continue
            }
            do {
                try FileManager.default.moveItem(at: src, to: dst)
                moved += 1
            } catch {
                failed += 1
            }
        }
        return Result(moved: moved,
                      skippedLocalExists: skipped,
                      failed: failed,
                      scannedICloudDir: true)
    }

    // MARK: - Path helpers

    private static func iCloudEmbeddingsDir() -> URL? {
        guard let root = ConversionOutputResolver.currentRoot()
        else { return nil }
        return root
            .appendingPathComponent(".humanist", isDirectory: true)
            .appendingPathComponent("Embeddings", isDirectory: true)
    }

    private static func localEmbeddingsDir() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("Embeddings", isDirectory: true)
    }

    private static func logSummary(_ r: Result) {
        if !r.scannedICloudDir {
            NSLog("Humanist embeddings migration: nothing to migrate (no iCloud Embeddings dir).")
            return
        }
        NSLog(
            "Humanist embeddings migration: moved %d, skipped %d (local existed), failed %d.",
            r.moved, r.skippedLocalExists, r.failed
        )
    }
}
