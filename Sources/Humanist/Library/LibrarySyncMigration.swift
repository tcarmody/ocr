import Foundation
import CryptoKit  // SHA-256 for the legacy sidecar key lookup
import EPUB

/// R-Library-Sync migration. When the user flips
/// "Share library across machines" on, move catalog + sidecars +
/// aliases from `~/Library/Application Support/Humanist/` into
/// `<outputRoot>/.humanist/` so cloud-folder sync can carry them
/// between Macs.
///
/// Each piece is idempotent + defensive:
///   * The catalog `library.json` copies (not moves) so the
///     Application Support copy stays as a backup until the next
///     clean launch confirms the in-root copy loaded correctly.
///   * Per-book embedding sidecars walk the current `LibraryStore`
///     entries; for each entry, the legacy SHA-keyed sidecar (if
///     any) copies to the new UUID-keyed location under the
///     output root.
///   * The aliases dictionary copies single-file if present.
///
/// Phase A shipped catalog-only. Phase B adds sidecars + aliases.
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

    /// Phase B return shape — composite of catalog status +
    /// counts for the sidecar / aliases walks.
    struct PhaseBResult: Equatable {
        /// Whether the catalog file itself moved / was already in
        /// place / failed.
        let catalog: CatalogResult
        /// Number of book sidecars copied from Application
        /// Support → output root. Zero is normal on a fresh
        /// install or an already-migrated library.
        let sidecarsCopied: Int
        /// True when the aliases dictionary was copied this run.
        let aliasesCopied: Bool
    }

    // MARK: - Phase A

    /// Phase A entry point — catalog only. Kept for backward-
    /// compat with the Phase A tests + callers; new callers
    /// should prefer `runFull(library:)` which also moves
    /// sidecars + aliases.
    static func run() -> CatalogResult {
        return moveCatalog()
    }

    // MARK: - Phase B

    /// Full migration: catalog + sidecars + aliases. Caller
    /// passes a snapshot of `LibraryStore.entries` so the sidecar
    /// walk knows which UUIDs to look up. Each piece reports its
    /// status independently — if the catalog already moved but
    /// the sidecars hadn't, the second run copies just the
    /// sidecars.
    @MainActor
    static func runFull(library: LibraryStore) -> PhaseBResult {
        let catalogResult = moveCatalog()
        let sidecars = migrateSidecars(entries: library.entries)
        let aliases = migrateAliases()
        return PhaseBResult(
            catalog: catalogResult,
            sidecarsCopied: sidecars,
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

    /// Walk every entry; for each, look up the legacy SHA-keyed
    /// sidecar in Application Support and copy to the new
    /// UUID-keyed location under `<outputRoot>/.humanist/Embeddings/`.
    /// Returns the count of copies actually made. Idempotent —
    /// re-runs are no-ops once the UUID-keyed copy exists.
    private static func migrateSidecars(
        entries: [LibraryEntry]
    ) -> Int {
        guard let root = ConversionOutputResolver.currentRoot() else { return 0 }
        let destDir = root
            .appendingPathComponent(".humanist", isDirectory: true)
            .appendingPathComponent("Embeddings", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: destDir, withIntermediateDirectories: true
        )

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let supportSidecarDir = support
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("Embeddings", isDirectory: true)

        var copied = 0
        for entry in entries {
            // Compute the legacy SHA-keyed filename the same way
            // EmbeddingsSidecarStore.legacySHAFileURL does.
            let canonical = entry.epubURL
                .canonicalForFile.standardizedFileURL.path
            let legacySHA = sha256Hex(of: canonical)
            let legacyURL = supportSidecarDir
                .appendingPathComponent("\(legacySHA).json")
            let destURL = destDir
                .appendingPathComponent("\(entry.id.uuidString).json")
            guard FileManager.default.fileExists(atPath: legacyURL.path)
            else { continue }
            if FileManager.default.fileExists(atPath: destURL.path) {
                continue  // already migrated
            }
            do {
                try FileManager.default.copyItem(at: legacyURL, to: destURL)
                copied += 1
            } catch {
                // Best-effort — one bad sidecar shouldn't abort
                // the rest of the walk. The legacy SHA-keyed
                // copy stays as a fallback that the store's
                // read chain still finds.
                continue
            }
        }
        return copied
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

    /// SHA-256 hex of a string. Mirrors the keying logic in
    /// `EmbeddingsSidecarStore.legacySHAFileURL` so the migration
    /// looks up the same filename the store used to write.
    private static func sha256Hex(of string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
