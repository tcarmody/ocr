import Foundation
import EPUB

/// R-Library-Sync migration. When the user flips
/// "Share library across machines" on, copy catalog + aliases
/// from `~/Library/Application Support/Humanist/` into
/// `<outputRoot>/.humanist/` so cloud-folder sync can carry them
/// between Macs.
///
/// Each piece is idempotent + defensive:
///   * The catalog `library.json` copies (not moves) so the
///     Application Support copy stays as a backup until the next
///     clean launch confirms the in-root copy loaded correctly.
///   * The aliases dictionary copies single-file if present.
///
/// Embedding sidecars are intentionally excluded: thousands of JSON
/// files totaling tens of GB through iCloud Drive's metadata-coordinated
/// reads make every federated-index rebuild a multi-minute stall.
/// Embeddings stay local; the share toggle only covers state small
/// enough for iCloud to handle gracefully.
enum LibrarySyncMigration {

    enum CatalogResult: Equatable {
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

    /// Return shape for `runFull` — composite of catalog status
    /// + a flag for the aliases dictionary. `sidecarsCopied` used
    /// to live here; embeddings no longer participate in the share
    /// migration, so its absence is intentional.
    struct PhaseBResult: Equatable {
        /// Whether the catalog file itself moved / was already in
        /// place / failed.
        let catalog: CatalogResult
        /// True when the aliases dictionary was copied this run.
        let aliasesCopied: Bool
    }

    // MARK: - Phase A

    /// Phase A entry point — catalog only. Kept for backward-
    /// compat with the Phase A tests + callers; new callers
    /// should prefer `runFull(library:)` which also moves aliases.
    static func run() -> CatalogResult {
        return moveCatalog()
    }

    // MARK: - Phase B

    /// Full migration: catalog + aliases. Each piece reports its
    /// status independently — if the catalog already moved but
    /// the aliases hadn't, the second run copies just the aliases.
    /// `library` is unused (sidecars are no longer migrated) but
    /// kept on the signature so the Settings call site doesn't
    /// need to change every time the migration scope narrows.
    @MainActor
    static func runFull(library: LibraryStore) -> PhaseBResult {
        let catalogResult = moveCatalog()
        let aliases = migrateAliases()
        _ = library
        return PhaseBResult(
            catalog: catalogResult,
            aliasesCopied: aliases
        )
    }

    // MARK: - Steps

    private static func moveCatalog() -> CatalogResult {
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

        do {
            try FileManager.default.copyItem(at: supportURL, to: inRootURL)
        } catch {
            return .failed("Couldn't copy library.json to \(inRootURL.path): \(error.localizedDescription)")
        }
        return .moved
    }

    private static func migrateAliases() -> Bool {
        guard let root = ConversionOutputResolver.currentRoot() else { return false }
        let destURL = root
            .appendingPathComponent(".humanist", isDirectory: true)
            .appendingPathComponent("aliases.json")
        try? FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destURL.path) {
            return false
        }
        let source = AliasDictionaryStore.applicationSupportStoreURL()
        guard FileManager.default.fileExists(atPath: source.path)
        else { return false }
        do {
            try FileManager.default.copyItem(at: source, to: destURL)
            return true
        } catch {
            return false
        }
    }

}
