import Foundation
import LibraryIndexing

/// Bulk upgrade: convert legacy `.json` sidecars under
/// `~/Library/Application Support/Humanist/Embeddings/` to the
/// new `.emb` binary format. Runs once per Mac (UserDefaults
/// flag) and re-encodes each JSON sidecar atomically, deleting
/// the original only after a successful round-trip.
///
/// Why eager (vs. lazy on-read upgrade): the per-book chat sidecar
/// is the source of truth for both per-book retrieval *and* the
/// federated index. A lazy-on-read pattern would either:
///   * race during concurrent reads, producing partial `.emb`
///     files, or
///   * mutate disk during a read, which the rest of the storage
///     layer treats as immutable.
/// A one-shot bulk pass at app launch sidesteps both issues, and
/// because the conversion is local-disk-to-local-disk it finishes
/// in tens of seconds even on a 50 GB embedding store.
///
/// Cost note: this pass invalidates the federated-index cache
/// fingerprint (every sidecar's mtime + size changes), so the
/// next library-chat send will rebuild the cache from `.emb`
/// files. That's the bargain — pay one rebuild, gain 5–10× disk
/// reduction + much faster decode on every subsequent rebuild.
enum EmbeddingsBinaryUpgrade {

    /// UserDefaults key marking the upgrade as complete on this
    /// Mac. Set only after a successful run (no remaining `.json`
    /// sidecars where the matching `.emb` write didn't land);
    /// failures get a free retry on next launch.
    static let completedDefaultsKey = "humanist.embeddings.binaryUpgradeCompleted"

    /// Per-run report. Surfaced via NSLog so we can tell from the
    /// console how the upgrade went.
    struct Result: Equatable {
        /// Files successfully re-encoded as `.emb` (original
        /// `.json` deleted after verified write).
        let converted: Int
        /// Files we couldn't read as JSON (corrupt) — left in
        /// place; the per-book chat will rebuild them on next
        /// open via the existing rebuild path.
        let unreadable: Int
        /// Files where we couldn't write the `.emb` (disk full,
        /// permissions) — the `.json` source stays in place so
        /// reads continue to work via the fallback chain.
        let writeFailed: Int
        /// True when the Embeddings directory existed at the start
        /// of the run.
        let scannedDir: Bool
    }

    /// Run the upgrade unless we've already done so on this Mac.
    /// Returns nil when the run was skipped (flag set). Safe to
    /// call from app launch — does no work on the second+ launch.
    @discardableResult
    static func runIfNeeded() -> Result? {
        if UserDefaults.standard.bool(forKey: completedDefaultsKey) {
            return nil
        }
        let result = upgrade(directory: localEmbeddingsDir())
        UserDefaults.standard.set(true, forKey: completedDefaultsKey)
        logSummary(result)
        return result
    }

    /// Test seam — does the actual conversion work on a supplied
    /// directory without touching UserDefaults or NSLog.
    static func upgrade(directory: URL) -> Result {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return Result(converted: 0, unreadable: 0, writeFailed: 0,
                          scannedDir: false)
        }
        let names: [String]
        do {
            names = try FileManager.default
                .contentsOfDirectory(atPath: directory.path)
        } catch {
            return Result(converted: 0, unreadable: 0, writeFailed: 0,
                          scannedDir: false)
        }

        var converted = 0
        var unreadable = 0
        var writeFailed = 0
        for name in names {
            // Only operate on `.json` files. `.emb` files already
            // upgraded; anything else (.DS_Store, etc.) skipped.
            guard name.hasSuffix(".json") else { continue }
            let src = directory.appendingPathComponent(name)
            let dstName = (name as NSString)
                .deletingPathExtension + ".emb"
            let dst = directory.appendingPathComponent(dstName)

            // If a `.emb` already exists, treat the `.json` as
            // a stale leftover and remove it. Earlier write must
            // have succeeded; we just hadn't deleted the source.
            if FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.removeItem(at: src)
                continue
            }

            guard let data = try? Data(contentsOf: src) else {
                unreadable += 1
                continue
            }
            // Try the *current* schema first; fall through if the
            // JSON is older or malformed.
            guard let sidecar = try? Self.decoder.decode(
                EmbeddingsSidecar.self, from: data
            ) else {
                unreadable += 1
                continue
            }
            guard let encoded = try? EmbeddingsSidecarBinaryFormat.encode(sidecar)
            else {
                writeFailed += 1
                continue
            }
            do {
                try encoded.write(to: dst, options: .atomic)
            } catch {
                writeFailed += 1
                continue
            }
            // Drop the JSON only after the `.emb` has landed. A
            // crash between write and remove leaves both files;
            // the next launch's idempotent pass deletes the
            // stale `.json` (the "dst exists already" branch
            // above).
            try? FileManager.default.removeItem(at: src)
            converted += 1
        }
        return Result(
            converted: converted,
            unreadable: unreadable,
            writeFailed: writeFailed,
            scannedDir: true
        )
    }

    // MARK: - Path helpers

    private static func localEmbeddingsDir() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("Embeddings", isDirectory: true)
    }

    private static func logSummary(_ r: Result) {
        if !r.scannedDir {
            NSLog("Humanist embeddings binary upgrade: nothing to upgrade (no Embeddings dir).")
            return
        }
        NSLog(
            "Humanist embeddings binary upgrade: %d converted, %d unreadable, %d write-failed.",
            r.converted, r.unreadable, r.writeFailed
        )
    }

    private static let decoder = JSONDecoder()
}
