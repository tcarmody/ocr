import Foundation

/// One-shot backfill for the `sourceContentHashes` field on
/// `LibraryEntry`s that pre-date the R-Library-Dedupe feature.
///
/// Why: before R-Library-Dedupe, neither conversions nor EPUB imports
/// stamped a content hash onto the catalog entry.
/// `InputFolderScanner.runHashedScan`, `JobRunner.runDedupeShortCircuit`,
/// and `EPUBImporter`'s pre-flight all consult that hash to decide
/// whether to skip a re-dropped source — so legacy books are
/// invisible to dedupe, and the user pays the OCR / import cost again
/// every time the same bytes show up.
///
/// Strategy — two probe paths per entry, both writing into the same
/// `sourceContentHashes` array:
///   1. **Source PDF** (preferred for converted books): try
///      `LibraryStore.locateSourcePDF`. When it returns a URL, hash
///      that file. Stamps the *source* hash, which is what the
///      auto-scanner compares against when a re-drop lands in
///      `Input/`.
///   2. **Catalog EPUB** (preferred for imports + fallback for
///      conversions whose PDF source is gone): hash the entry's own
///      `epubURL`. For imports the EPUB *is* the source — byte-for-
///      byte identical to the file the user dragged in. For
///      converted books with a missing PDF source, the EPUB hash
///      doesn't help the auto-scanner but does catch re-imports of
///      the converted EPUB onto a peer Mac.
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
        /// Entries we tried to hash but the read failed (permission
        /// denied, file got moved mid-flight, EPUB on dataless
        /// iCloud path). Empty hashes; retry next launch.
        var hashFailed: Int
        /// Entries successfully hashed via their *source PDF*. Best
        /// case for converted books: the resulting hash matches what
        /// the auto-scanner sees when the same PDF re-lands in
        /// `Input/`.
        var stampedFromPDF: Int
        /// Entries successfully hashed via the *catalog EPUB* (no
        /// source PDF located, or the entry was an import to begin
        /// with). Catches re-imports of byte-identical EPUBs across
        /// Macs sharing the catalog.
        var stampedFromEPUB: Int
        /// Sum of the two stamping paths — common log statistic.
        var stamped: Int { stampedFromPDF + stampedFromEPUB }
    }

    /// Which file an entry's hash came from. Tracked per-candidate
    /// so the result counters can split PDF-stamped from EPUB-
    /// stamped, and the NSLog summary tells the user where the
    /// hashes came from.
    private enum Provenance: Sendable {
        case pdf
        case epub
    }

    /// Run the backfill against `library`. Returns the per-run
    /// report. Callable from a detached Task; library mutations
    /// are routed through MainActor by the LibraryStore's
    /// @MainActor isolation.
    @discardableResult
    static func runIfNeeded(library: LibraryStore) async -> Result {
        // Snapshot the work set on MainActor so the hashing loop
        // doesn't keep re-touching the published `entries` array
        // while we read it. For each entry without a hash, prefer
        // the source PDF (when locatable) over the catalog EPUB.
        // Imported books and conversions with a missing source
        // both fall through to the EPUB path — every entry that
        // survives load() has an EPUB on disk, so this fallback
        // always has something to hash.
        let candidates: [(id: UUID, url: URL, provenance: Provenance)] =
            await MainActor.run {
                library.entries.compactMap { entry in
                    guard entry.sourceContentHashes.isEmpty else { return nil }
                    if let pdf = LibraryStore.locateSourcePDF(for: entry.epubURL) {
                        return (entry.id, pdf, .pdf)
                    }
                    return (entry.id, entry.epubURL, .epub)
                }
            }

        let alreadyStamped = await MainActor.run {
            library.entries.filter { !$0.sourceContentHashes.isEmpty }.count
        }

        guard !candidates.isEmpty else {
            let result = Result(
                alreadyStamped: alreadyStamped,
                hashFailed: 0,
                stampedFromPDF: 0,
                stampedFromEPUB: 0
            )
            logSummary(result)
            return result
        }

        // Hash with bounded concurrency via TaskGroup. Each
        // hashing task runs on a background priority queue
        // (`Task.detached`) so the launcher stays responsive
        // through the multi-minute backfill on large libraries.
        let hashes = await withTaskGroup(
            of: (UUID, String?, Provenance).self,
            returning: [(UUID, String?, Provenance)].self
        ) { group in
            var iterator = candidates.makeIterator()
            // Prime the pump with up to maxConcurrentHashes tasks,
            // then refill as each completes — keeps the IO depth
            // constant without buffering the entire input set.
            func enqueueNext() -> Bool {
                guard let next = iterator.next() else { return false }
                let id = next.id
                let url = next.url
                let provenance = next.provenance
                group.addTask(priority: .utility) {
                    let h = try? ContentHash.sha256(of: url)
                    return (id, h, provenance)
                }
                return true
            }
            for _ in 0..<maxConcurrentHashes {
                if !enqueueNext() { break }
            }
            var results: [(UUID, String?, Provenance)] = []
            while let r = await group.next() {
                results.append(r)
                _ = enqueueNext()
            }
            return results
        }

        var stampedFromPDF = 0
        var stampedFromEPUB = 0
        var stampedPairs: [(UUID, String)] = []
        for (id, hash, provenance) in hashes {
            guard let hash else { continue }
            stampedPairs.append((id, hash))
            switch provenance {
            case .pdf:  stampedFromPDF += 1
            case .epub: stampedFromEPUB += 1
            }
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
            hashFailed: hashFailed,
            stampedFromPDF: stampedFromPDF,
            stampedFromEPUB: stampedFromEPUB
        )
        logSummary(result)
        return result
    }

    private static func logSummary(_ r: Result) {
        if r.stamped == 0, r.hashFailed == 0 {
            // Quiet path — no work happened. Worth a single line
            // for ops diagnostics but no need to shout.
            NSLog(
                "Humanist source-hash backfill: nothing to do (already stamped %d).",
                r.alreadyStamped
            )
            return
        }
        NSLog(
            "Humanist source-hash backfill: stamped %d (PDF: %d, EPUB: %d), hash-failed %d, already-stamped %d.",
            r.stamped, r.stampedFromPDF, r.stampedFromEPUB,
            r.hashFailed, r.alreadyStamped
        )
    }
}
