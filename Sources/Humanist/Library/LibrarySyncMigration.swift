import Foundation
import EPUB

/// R-Library-Sync Phase A migration. When the user flips
/// "Share library across machines" on, move the catalog from
/// `~/Library/Application Support/Humanist/library.json` into
/// `<outputRoot>/.humanist/library.json` so cloud-folder sync can
/// carry it to a second Mac.
///
/// Idempotent: re-running when the in-root catalog already
/// exists is a no-op. Defensive: leaves the Application Support
/// copy in place as a backup until the next successful launch
/// confirms the in-root copy loaded correctly.
///
/// Out of scope for Phase A: sidecar (embedding / chat / alias)
/// migration. Those keys still use path-SHA-256 today; the user
/// re-runs bulk-index on the second machine to materialize them.
/// Phase B is the planned rekey to UUID-keyed sidecars.
enum LibrarySyncMigration {

    enum Result: Equatable {
        /// First-time activation: catalog file moved from
        /// Application Support to the output root.
        case moved
        /// Re-activation: the in-root catalog already exists,
        /// nothing to do.
        case alreadyMigrated
        /// No Application Support catalog to migrate (fresh
        /// install, or user has never run a conversion). The
        /// store will simply start fresh in the in-root location.
        case nothingToMigrate
        /// Output root isn't configured. Caller surfaces this so
        /// the user knows to pick a folder first.
        case rootMissing
        /// Filesystem error (permission denied, iCloud not
        /// downloaded, etc.). Caller surfaces the message.
        case failed(String)
    }

    /// Run the migration. Returns a result the caller can surface
    /// in a one-time activation sheet.
    static func run() -> Result {
        guard let root = ConversionOutputResolver.currentRoot() else {
            return .rootMissing
        }
        let inRootDir = root.appendingPathComponent(
            ".humanist", isDirectory: true
        )
        let inRootURL = inRootDir.appendingPathComponent("library.json")
        do {
            try FileManager.default.createDirectory(
                at: inRootDir, withIntermediateDirectories: true
            )
        } catch {
            return .failed("Couldn't create \(inRootDir.path): \(error.localizedDescription)")
        }

        // If the in-root file already exists, the migration ran
        // before (or the user is sharing from another machine
        // that already put it there). Don't clobber it.
        if FileManager.default.fileExists(atPath: inRootURL.path) {
            return .alreadyMigrated
        }

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let supportURL = support
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: supportURL.path) else {
            return .nothingToMigrate
        }

        // Copy (not move) the file so the Application Support
        // version stays in place as a backup. The next clean
        // launch under sync mode will read from the in-root
        // location; if anything goes wrong the user can flip the
        // toggle off and the Application Support copy is still
        // intact.
        do {
            try FileManager.default.copyItem(at: supportURL, to: inRootURL)
        } catch {
            return .failed("Couldn't copy library.json to \(inRootURL.path): \(error.localizedDescription)")
        }
        return .moved
    }
}
