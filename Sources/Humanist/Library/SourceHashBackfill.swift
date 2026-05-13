import Foundation

/// One-shot backfill for the `sourceContentHashes` field on
/// `LibraryEntry`s that pre-date the R-Library-Dedupe feature.
///
/// Why: before R-Library-Dedupe, conversions didn't stamp the source
/// PDF's SHA-256 onto the catalog entry. `InputFolderScanner.runHashedScan`
/// and `JobRunner.runDedupeShortCircuit` both consult that hash to
/// decide whether to skip a re-dropped PDF — so books converted before
/// the feature are invisible to the dedupe path, and the user re-OCRs
/// them every time the auto-scanner picks the source up from Input/.
///
/// Strategy: walk catalog entries with empty `sourceContentHashes`,
/// locate the source PDF via `LibraryStore.locateSourcePDF` (same
/// probe sites the conversion-type backfill already uses), hash the
/// file via `ContentHash.sha256`, and stamp the result onto the entry.
///
/// Semantics:
///   * **No global flag**. State lives on each entry: empty hashes
///     means "still try"; populated means "done." Self-correcting if
///     the user reattaches a drive of source PDFs that weren't
///     available on a previous run.
///   * **Best-effort per entry**. A missing source PDF, a permission
///     glitch, a hashing failure — all leave the entry's hashes
///     empty; subsequent launches will retry.
///   * **Bounded concurrency**. SHA-256 over hundreds of multi-megabyte
///     PDFs is dominated by disk IO; 4 concurrent streams saturate
///     the typical NVMe SSD without thrashing.
///   * **Single bulk save at the end**. 2000 entries × per-mutation
///     save would be ~20s of unnecessary disk write; the bulk-update
///     window collapses to one publish + one save.
///
/// Detached at launch from `HumanistApp.init`. Failure modes are
/// silent (NSLog summary only) — the dedupe path keeps working with
/// whatever subset succeeded.
@MainActor
enum SourceHashBackfill {

    /// Maximum number of concurrent SHA-256 streams. 4 saturates a
    /// typical NVMe SSD without thrashing the CPU on the small-file
    /// case. Tuned conservatively — book-sized PDFs (10-200 MB) are
    /// large enough that the IO depth matters more than CPU
    /// parallelism.
    static let maxConcurrentHashes = 4

    /// Per-run report. Surfaced via NSLog so the launch console
    /// shows how the backfill went; the catalog itself reflects
    /// the success cases by having entries' hashes populated.
    struct Result: Equatable {
        /// Entries already carrying a hash — skipped without IO.
        var alreadyStamped: Int
        /// Entries whose source PDF we couldn't locate — typically
        /// because the user converted from a path that's now gone
        /// (downloads folder, external drive, etc.). Hashes stay
        /// empty; subsequent launches retry.
        var sourceMissing: Int
        /// Entries we tried to hash but the read failed (permission
        /// denied, file got moved mid-flight). Empty hashes; retry
        /// next launch.
        var hashFailed: Int
        /// Entries successfully hashed + stamped.
        var stamped: Int
    }

    /// Run the backfill against `library`. Returns the per-run
    /// report. Callable from a detached Task; library mutations
    /// are routed through MainActor by the LibraryStore's
    /// @MainActor isolation.
    @discardableResult
    static func runIfNeeded(library: LibraryStore) async -> Result {
        // Snapshot the work set on MainActor so the hashing loop
        // doesn't keep re-touching the published `entries` array
        // while we read it.
        let candidates: [(id: UUID, pdf: URL)] = await MainActor.run {
            library.entries.compactMap { entry in
                guard entry.sourceContentHashes.isEmpty else { return nil }
                guard let pdf = LibraryStore.locateSourcePDF(for: entry.epubURL)
                else { return nil }
                return (entry.id, pdf)
            }
        }

        let alreadyStamped = await MainActor.run {
            library.entries.filter { !$0.sourceContentHashes.isEmpty }.count
        }
        let sourceMissing = await MainActor.run {
            library.entries.filter { entry in
                entry.sourceContentHashes.isEmpty
                    && LibraryStore.locateSourcePDF(for: entry.epubURL) == nil
            }.count
        }

        guard !candidates.isEmpty else {
            let result = Result(
                alreadyStamped: alreadyStamped,
                sourceMissing: sourceMissing,
                hashFailed: 0,
                stamped: 0
            )
            logSummary(result)
            return result
        }

        // Hash with bounded concurrency via TaskGroup. Each
        // hashing task runs on a background priority queue
        // (`Task.detached`) so the launcher stays responsive
        // through the multi-minute backfill on large libraries.
        let hashes = await withTaskGroup(
            of: (UUID, String?).self,
            returning: [(UUID, String?)].self
        ) { group in
            var enqueued = 0
            var iterator = candidates.makeIterator()
            // Prime the pump with up to maxConcurrentHashes tasks,
            // then refill as each completes — keeps the IO depth
            // constant without buffering the entire input set.
            func enqueueNext() -> Bool {
                guard let next = iterator.next() else { return false }
                let id = next.id
                let pdf = next.pdf
                group.addTask(priority: .utility) {
                    let h = try? ContentHash.sha256(of: pdf)
                    return (id, h)
                }
                enqueued += 1
                return true
            }
            for _ in 0..<maxConcurrentHashes {
                if !enqueueNext() { break }
            }
            var results: [(UUID, String?)] = []
            while let r = await group.next() {
                results.append(r)
                _ = enqueueNext()
            }
            return results
        }

        let stampedPairs = hashes.compactMap { (id, hash) -> (UUID, String)? in
            guard let hash else { return nil }
            return (id, hash)
        }
        let hashFailed = hashes.count - stampedPairs.count

        // Persist all stamps in one bulk window. 2k entries × per-
        // mutation save() would be ~10s of extra disk-write
        // latency for nothing; bulk mode collapses to one publish
        // + one snapshot + one atomic write.
        await MainActor.run {
            library.beginBulkUpdate()
            for (id, hash) in stampedPairs {
                library.recordSourceHash(hash, on: id)
            }
            library.endBulkUpdate()
        }

        let result = Result(
            alreadyStamped: alreadyStamped,
            sourceMissing: sourceMissing,
            hashFailed: hashFailed,
            stamped: stampedPairs.count
        )
        logSummary(result)
        return result
    }

    private static func logSummary(_ r: Result) {
        if r.stamped == 0, r.hashFailed == 0 {
            // Quiet path — no work happened. Worth a single line
            // for ops diagnostics but no need to shout.
            NSLog(
                "Humanist source-hash backfill: nothing to do (already stamped %d, source missing %d).",
                r.alreadyStamped, r.sourceMissing
            )
            return
        }
        NSLog(
            "Humanist source-hash backfill: stamped %d, hash-failed %d, source-missing %d, already-stamped %d.",
            r.stamped, r.hashFailed, r.sourceMissing, r.alreadyStamped
        )
    }
}
