import Foundation

/// Shared catalog-location resolver for CLI commands. The CLI is a
/// separate process from the app, so `UserDefaults.standard` here
/// reads the CLI's own domain — NOT the app's. To find the
/// configuration the user actually set up via Settings, we have to
/// reach into `com.tcarmody.Humanist`'s defaults explicitly.
///
/// Mirrors `LibraryStore.resolveStoreURL`'s three-way precedence so
/// the CLI lands on the same catalog the running app would:
///   1. `shareAcrossMachines = true` + `outputFolderPath` set →
///      `<root>/.humanist/library.json` (cloud sync).
///   2. `localLibraryRootPath` set + exists →
///      `<localRoot>/.humanist/library.json` (R-Library-Migrate
///      customLocal mode).
///   3. Otherwise → `~/Library/Application Support/Humanist/library.json`
///      (historical default).
///
/// Without this resolver the CLI defaulted to Application Support
/// regardless of the user's actual library state — a user on cloud
/// sync would see the CLI silently process a stale 2026-05-12
/// snapshot of their catalog instead of the live cloud one.
enum CLILibraryLocation {
    static let appBundleID = "com.tcarmody.Humanist"

    /// Return the catalog URL when one exists on disk via the
    /// precedence chain above. Returns nil when no resolution
    /// finds a file — the caller surfaces a "pass --catalog
    /// explicitly" error in that case.
    static func defaultCatalogURL() -> URL? {
        let defaults = UserDefaults(suiteName: appBundleID) ?? .standard
        let fm = FileManager.default

        // Tier 1: cloud sync.
        let shareEnabled = defaults.bool(
            forKey: "humanist.library.shareAcrossMachines"
        )
        if shareEnabled,
           let raw = defaults.string(forKey: "humanist.conversion.outputFolderPath"),
           !raw.isEmpty {
            let candidate = URL(fileURLWithPath: raw)
                .appendingPathComponent(".humanist", isDirectory: true)
                .appendingPathComponent("library.json")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Tier 2: customLocal (R-Library-Migrate non-default path).
        if let raw = defaults.string(forKey: "humanist.library.localRootPath"),
           !raw.isEmpty {
            var isDir: ObjCBool = false
            let root = URL(fileURLWithPath: raw)
            if fm.fileExists(atPath: root.path, isDirectory: &isDir),
               isDir.boolValue {
                let candidate = root
                    .appendingPathComponent(".humanist", isDirectory: true)
                    .appendingPathComponent("library.json")
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        // Tier 3: Application Support.
        let support = fm.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? fm.temporaryDirectory
        let candidate = support
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("library.json")
        if fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }
}
