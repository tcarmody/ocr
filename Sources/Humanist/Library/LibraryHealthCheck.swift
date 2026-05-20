import Foundation
import EPUB

/// One catalog entry that failed the health check, with the
/// reason it failed so the review sheet can display a precise
/// label. `entry` is a snapshot taken at scan time — the
/// LibraryStore could mutate between scan and apply, so the
/// review sheet looks up the live entry by id at remove time.
struct BrokenLibraryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let entry: LibraryEntry
    let reason: Reason

    enum Reason: Equatable, Sendable {
        /// The `.epub` file is not at its recorded path. Common
        /// causes: the user deleted / renamed / moved the file
        /// outside Humanist, or the catalog points at a removable
        /// volume that isn't mounted right now.
        case missing
        /// The file exists but EPUBPackage.open threw — corrupt
        /// ZIP, missing META-INF/container.xml, broken OPF, etc.
        /// The error message is included so power users can tell
        /// "I should re-import this" from "this is genuinely
        /// damaged".
        case unopenable(String)

        var label: String {
            switch self {
            case .missing:           return "Missing"
            case .unopenable:        return "Won't open"
            }
        }
    }
}

/// Library health check — walks every catalog entry, flags the
/// ones whose `.epub` is either missing on disk or unreadable as
/// an EPUB package. Designed for the manual "Find Missing
/// Files…" sheet (not the launch-time silent prune in
/// `LibraryStore.load`, which only checks fileExists and skips
/// the open-as-EPUB step).
///
/// The unopenable check uses `EPUBPackage.open` rather than the
/// fuller `EPUBBook.open`: package open parses OPF + walks the
/// file tree, which is enough to catch the realistic failure
/// modes (corrupt ZIP, missing OPF, broken manifest) without the
/// per-chapter load that EPUBBook does. EPUBPackage's own deinit
/// cleans up the unpacked working directory, so a scan over a
/// large library doesn't leak temp storage.
enum LibraryHealthCheck {

    /// Scan `entries` and return the broken ones. Runs each
    /// check on a detached background task so the main actor
    /// stays free; the optional `progress` callback fires with
    /// `(completed, total)` after each entry. Cancellable via
    /// the surrounding Task — the scan checks for cancellation
    /// between entries.
    static func scan(
        entries: [LibraryEntry],
        progress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async -> [BrokenLibraryEntry] {
        let total = entries.count
        var broken: [BrokenLibraryEntry] = []
        for (idx, entry) in entries.enumerated() {
            if Task.isCancelled { break }
            let result = await Task.detached(priority: .utility) {
                checkOne(entry: entry)
            }.value
            if let result {
                broken.append(result)
            }
            await progress?(idx + 1, total)
        }
        return broken
    }

    /// Run both checks (fileExists, then EPUBPackage.open) on a
    /// single entry. Returns nil for healthy entries. Pure +
    /// nonisolated so it runs cleanly on a detached task.
    private static func checkOne(entry: LibraryEntry) -> BrokenLibraryEntry? {
        let url = entry.epubURL.canonicalForFile
        if !FileManager.default.fileExists(atPath: url.path) {
            return BrokenLibraryEntry(
                id: entry.id, entry: entry, reason: .missing
            )
        }
        do {
            // EPUBPackage's deinit removes the unpacked working
            // directory; nothing else needed for cleanup.
            _ = try EPUBPackage.open(epubURL: url)
            return nil
        } catch {
            return BrokenLibraryEntry(
                id: entry.id,
                entry: entry,
                reason: .unopenable(error.localizedDescription)
            )
        }
    }
}
