import Foundation

/// R-Library-Migrate. Move the library's user-state files between
/// `~/Library/Application Support/Humanist/` (local mode) and
/// `<outputRoot>/.humanist/` (cloud-folder mode). Or between two
/// different cloud roots — the schema is the same on both sides.
///
/// Scope of "library state" for migration purposes:
///
///   * `library.json` — the catalog
///   * `aliases.json` — alias dictionary for entity retrieval. Lives
///     in `Aliases/aliases.json` subdirectory in local mode, but at
///     the .humanist root in cloud mode (existing R-Library-Sync
///     asymmetry; we normalize both into the destination's expected
///     shape).
///   * `snapshots/` — rolling pre-save catalog snapshots
///   * `Covers/` — per-entry cover overrides
///
/// Embeddings are deliberately out of scope, matching
/// `LibrarySyncMigration`'s posture: at library scale (tens of GB
/// of small JSON files) iCloud Drive's metadata-coordinated reads
/// make every federated-index rebuild a multi-minute stall.
/// Each Mac builds its own embedding sidecars from the shared
/// catalog. The wizard's post-flight verification surfaces this so
/// the user isn't surprised when chat retrieval feels slow after a
/// migration — first library-chat send rebuilds the federated
/// index from local sidecars on each machine.
///
/// Operational posture:
///   * `copy(...)` writes to the destination but does NOT touch
///     UserDefaults. Cancellation before `commit(...)` leaves the
///     toggle pointing at the source so the old location stays
///     authoritative even after a partial copy.
///   * `commit(...)` flips `shareLibraryAcrossMachines` + (when
///     destination is cloud) `outputFolderPath`. After this the
///     next launch reads from the new location.
///   * Post-commit, the source files stay in place as a backup
///     until the user explicitly deletes them via the wizard's
///     final "Clean up old location" step (deferred — v1 keeps
///     the source as belt-and-suspenders).
public enum LibraryMigrationService {

    // MARK: - Location

    /// Resolved storage location for the library's user-state files.
    /// Two cases mirror the existing R-Library-Sync mode split.
    public enum Location: Equatable, Sendable, Hashable {
        /// Local mode — files live under
        /// `~/Library/Application Support/Humanist/`.
        case applicationSupport
        /// Cloud mode — files live under `<root>/.humanist/`.
        case cloudFolder(root: URL)

        /// Human-readable rendering for the wizard UI.
        public var displayPath: String {
            switch self {
            case .applicationSupport:
                return "~/Library/Application Support/Humanist"
            case .cloudFolder(let root):
                return root.appendingPathComponent(".humanist").path
            }
        }

        /// Top-level directory containing the catalog + siblings.
        public var rootDirectory: URL {
            switch self {
            case .applicationSupport:
                let support = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first ?? FileManager.default.temporaryDirectory
                return support.appendingPathComponent(
                    "Humanist", isDirectory: true
                )
            case .cloudFolder(let root):
                return root.appendingPathComponent(
                    ".humanist", isDirectory: true
                )
            }
        }

        public var catalogURL: URL {
            rootDirectory.appendingPathComponent("library.json")
        }

        /// Aliases path. The two modes use different sub-paths
        /// historically: local mode lives under `Aliases/aliases.json`
        /// (matches `AliasDictionaryStore.applicationSupportStoreURL`),
        /// cloud mode lives at the `.humanist` root directly
        /// (matches `AliasDictionaryStore.resolveStoreURL` cloud
        /// branch). The wizard normalizes both into the destination's
        /// expected shape on copy.
        public var aliasesURL: URL {
            switch self {
            case .applicationSupport:
                return rootDirectory
                    .appendingPathComponent("Aliases", isDirectory: true)
                    .appendingPathComponent("aliases.json")
            case .cloudFolder:
                return rootDirectory.appendingPathComponent("aliases.json")
            }
        }

        public var snapshotsURL: URL {
            rootDirectory.appendingPathComponent(
                "snapshots", isDirectory: true
            )
        }

        public var coversURL: URL {
            rootDirectory.appendingPathComponent(
                "Covers", isDirectory: true
            )
        }
    }

    /// The library's current location, derived from UserDefaults.
    /// The wizard prefills its "source" slot from this.
    @MainActor
    public static func current() -> Location {
        let sharing = UserDefaults.standard.bool(
            forKey: ConversionSettingsKeys.shareLibraryAcrossMachines
        )
        if sharing, let root = ConversionOutputResolver.currentRoot() {
            return .cloudFolder(root: root)
        }
        return .applicationSupport
    }

    // MARK: - Pre-flight

    /// Pre-flight inspection of a planned migration. Cheap (stat-
    /// only); safe to call before the user commits to the wizard's
    /// next step. The wizard renders `blockingIssues` to the user
    /// and disables the Continue button when `canProceed == false`.
    public struct Preflight: Sendable, Equatable {
        public let source: Location
        public let destination: Location
        /// Whether the source's catalog file exists. nil-but-no-
        /// issue when the user is migrating from an empty state.
        public let sourceCatalogExists: Bool
        /// Entry count parsed from the source catalog. -1 when the
        /// catalog is missing or unparseable.
        public let sourceCatalogEntryCount: Int
        /// Whether the destination root directory is writable
        /// (testable via `FileManager.isWritableFile`).
        public let destinationWritable: Bool
        /// True when the destination already has a catalog. Wizard
        /// surfaces this prominently — overwriting would silently
        /// drop the destination's books.
        public let destinationHasExistingCatalog: Bool
        /// Pre-flight size estimate (catalog + snapshots + covers +
        /// aliases). nil when the source root is unreadable.
        public let bytesNeeded: Int64?
        /// Free-space on the destination volume. nil when stat fails
        /// or the destination is .applicationSupport (no per-volume
        /// stat needed at that scale).
        public let bytesAvailable: Int64?

        public var canProceed: Bool {
            destinationWritable
            && !destinationHasExistingCatalog
            && (bytesAvailable.map { needed in
                bytesNeeded.map { $0 < needed } ?? true
            } ?? true)
            && source != destination
        }

        public var blockingIssues: [String] {
            var issues: [String] = []
            if source == destination {
                issues.append("Source and destination are the same location.")
            }
            if !destinationWritable {
                issues.append("Can't write to \(destination.displayPath). Check folder permissions or pick a different location.")
            }
            if destinationHasExistingCatalog {
                issues.append("\(destination.displayPath) already has a library.json. Move or delete it first — the wizard won't overwrite an existing catalog.")
            }
            if let needed = bytesNeeded, let available = bytesAvailable,
               needed > available {
                let fmt = ByteCountFormatter()
                issues.append("Not enough free space at the destination (\(fmt.string(fromByteCount: needed)) needed, \(fmt.string(fromByteCount: available)) free).")
            }
            return issues
        }

        public var advisoryNotes: [String] {
            var notes: [String] = []
            if !sourceCatalogExists {
                notes.append("No existing catalog at the source — the destination will start empty.")
            }
            switch destination {
            case .cloudFolder:
                notes.append("Embedding sidecars stay machine-local. After the migration, this Mac's federated index rebuilds from local sidecars on the next library-chat send; other Macs sharing the destination will build their own indexes.")
            case .applicationSupport:
                notes.append("Embedding sidecars stay where they are. Switching back to local mode doesn't reshape the per-book sidecar storage.")
            }
            return notes
        }
    }

    @MainActor
    public static func preflight(
        source: Location, destination: Location
    ) -> Preflight {
        let catalogPath = source.catalogURL.path
        let sourceCatalogExists = FileManager.default.fileExists(atPath: catalogPath)
        let entryCount = sourceCatalogExists ? readEntryCount(at: source.catalogURL) : 0
        let bytesNeeded = sourceCatalogExists ? estimateBytes(at: source) : 0

        // Test destination writability by creating + removing a probe
        // file. `isWritableFile` lies for some iCloud states; the
        // probe is more reliable.
        let destDir = destination.rootDirectory
        try? FileManager.default.createDirectory(
            at: destDir, withIntermediateDirectories: true
        )
        let probe = destDir.appendingPathComponent(".migrate-probe-\(UUID().uuidString)")
        let writable: Bool
        do {
            try Data("probe".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            writable = true
        } catch {
            writable = false
        }

        let destinationHasCatalog = FileManager.default.fileExists(
            atPath: destination.catalogURL.path
        )

        let available = volumeAvailableBytes(at: destDir)

        return Preflight(
            source: source,
            destination: destination,
            sourceCatalogExists: sourceCatalogExists,
            sourceCatalogEntryCount: entryCount,
            destinationWritable: writable,
            destinationHasExistingCatalog: destinationHasCatalog,
            bytesNeeded: bytesNeeded,
            bytesAvailable: available
        )
    }

    // MARK: - Copy

    /// Phase the copy is currently in. Drives the wizard's progress
    /// row labels + per-phase progress bars.
    public enum CopyEvent: Sendable, Equatable {
        case startedCatalog
        case finishedCatalog
        case startedAliases
        case finishedAliases(copied: Bool)
        case startedSnapshots(total: Int)
        case progressedSnapshots(done: Int, total: Int)
        case finishedSnapshots
        case startedCovers(total: Int)
        case progressedCovers(done: Int, total: Int)
        case finishedCovers
        case completed
        case failed(String)
    }

    /// Run the copy. Returns an AsyncStream so the wizard can drive
    /// a progress view off the events; the underlying work runs
    /// inside the AsyncStream's task so cancellation propagates
    /// naturally.
    ///
    /// **Does not touch UserDefaults.** Callers run `commit(...)`
    /// after the user confirms the post-flight verification.
    public static func copy(
        source: Location, destination: Location
    ) -> AsyncStream<CopyEvent> {
        AsyncStream { continuation in
            let task = Task.detached {
                do {
                    try await runCopy(
                        source: source,
                        destination: destination,
                        emit: { event in continuation.yield(event) }
                    )
                    continuation.yield(.completed)
                } catch is CancellationError {
                    // No event — the AsyncStream's onTermination
                    // hook is the cancel signal.
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func runCopy(
        source: Location,
        destination: Location,
        emit: @Sendable (CopyEvent) async -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.rootDirectory,
            withIntermediateDirectories: true
        )

        // Catalog.
        await emit(.startedCatalog)
        if fm.fileExists(atPath: source.catalogURL.path) {
            try fm.copyItem(at: source.catalogURL, to: destination.catalogURL)
        }
        await emit(.finishedCatalog)
        try Task.checkCancellation()

        // Aliases. The two location modes use different sub-paths;
        // we read from source.aliasesURL and write to
        // destination.aliasesURL so the asymmetry is handled in one
        // place.
        await emit(.startedAliases)
        var aliasesCopied = false
        if fm.fileExists(atPath: source.aliasesURL.path) {
            try fm.createDirectory(
                at: destination.aliasesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.copyItem(at: source.aliasesURL, to: destination.aliasesURL)
            aliasesCopied = true
        }
        await emit(.finishedAliases(copied: aliasesCopied))
        try Task.checkCancellation()

        // Snapshots — many small JSON files. Walk + count first so
        // the wizard can render meaningful progress.
        let snapshotFiles = listFiles(in: source.snapshotsURL)
        await emit(.startedSnapshots(total: snapshotFiles.count))
        if !snapshotFiles.isEmpty {
            try fm.createDirectory(
                at: destination.snapshotsURL,
                withIntermediateDirectories: true
            )
            for (idx, file) in snapshotFiles.enumerated() {
                try Task.checkCancellation()
                let dest = destination.snapshotsURL.appendingPathComponent(
                    file.lastPathComponent
                )
                try fm.copyItem(at: file, to: dest)
                await emit(.progressedSnapshots(done: idx + 1, total: snapshotFiles.count))
            }
        }
        await emit(.finishedSnapshots)
        try Task.checkCancellation()

        // Covers — per-entry override JPEGs.
        let coverFiles = listFiles(in: source.coversURL)
        await emit(.startedCovers(total: coverFiles.count))
        if !coverFiles.isEmpty {
            try fm.createDirectory(
                at: destination.coversURL,
                withIntermediateDirectories: true
            )
            for (idx, file) in coverFiles.enumerated() {
                try Task.checkCancellation()
                let dest = destination.coversURL.appendingPathComponent(
                    file.lastPathComponent
                )
                try fm.copyItem(at: file, to: dest)
                await emit(.progressedCovers(done: idx + 1, total: coverFiles.count))
            }
        }
        await emit(.finishedCovers)
    }

    // MARK: - Commit

    /// Flip the user-defaults state so the next launch reads from
    /// `destination`. Called by the wizard after the user confirms
    /// the post-flight verification.
    @MainActor
    public static func commit(to destination: Location) {
        switch destination {
        case .applicationSupport:
            UserDefaults.standard.set(
                false, forKey: ConversionSettingsKeys.shareLibraryAcrossMachines
            )
        case .cloudFolder(let root):
            UserDefaults.standard.set(
                true, forKey: ConversionSettingsKeys.shareLibraryAcrossMachines
            )
            UserDefaults.standard.set(
                root.path, forKey: ConversionSettingsKeys.outputFolderPath
            )
        }
    }

    // MARK: - Verification

    /// Post-flight verification. Re-read the destination's catalog
    /// + aliases and report what's there. The wizard surfaces the
    /// numbers so the user can confirm before committing.
    public struct Verification: Sendable, Equatable {
        public let catalogReadable: Bool
        public let catalogEntryCount: Int
        public let aliasesReadable: Bool
        public let snapshotFilesPresent: Int
        public let coverFilesPresent: Int

        public var allOK: Bool {
            catalogReadable && aliasesReadable
        }
    }

    public static func verify(at location: Location) -> Verification {
        let entryCount = readEntryCount(at: location.catalogURL)
        let catalogOK = entryCount >= 0
        let aliasesOK = !FileManager.default.fileExists(
            atPath: location.aliasesURL.path
        ) || isReadableJSON(at: location.aliasesURL)
        return Verification(
            catalogReadable: catalogOK,
            catalogEntryCount: max(entryCount, 0),
            aliasesReadable: aliasesOK,
            snapshotFilesPresent: listFiles(in: location.snapshotsURL).count,
            coverFilesPresent: listFiles(in: location.coversURL).count
        )
    }

    // MARK: - Helpers

    /// Parse the JSON catalog enough to count entries. Returns -1
    /// on any failure so callers can distinguish "missing" from
    /// "present but zero entries."
    static func readEntryCount(at url: URL) -> Int {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [Any]
        else { return -1 }
        return entries.count
    }

    private static func isReadableJSON(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func listFiles(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return contents.filter { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDir
            )
            return !isDir.boolValue
        }
    }

    private static func estimateBytes(at location: Location) -> Int64 {
        var total: Int64 = 0
        for url in [location.catalogURL, location.aliasesURL] {
            total += fileSize(at: url)
        }
        for dir in [location.snapshotsURL, location.coversURL] {
            for file in listFiles(in: dir) {
                total += fileSize(at: file)
            }
        }
        return total
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64
        else { return 0 }
        return size
    }

    private static func volumeAvailableBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ),
        let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return capacity
    }
}
