import XCTest
import Foundation
@testable import Humanist

/// R-Library-Migrate service tests. Covers the path-resolution
/// asymmetry between local and cloud modes (aliases.json lives in
/// `Aliases/` subdir locally but at the .humanist root in cloud
/// mode), pre-flight check truthiness, copy round-trip, and
/// verification. The wizard view itself isn't unit-tested — the
/// service is the layer that owns the FS effects.
@MainActor
final class LibraryMigrationServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryMigrationServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Location paths

    func test_cloudLocation_paths_route_under_dot_humanist() {
        let loc = LibraryMigrationService.Location.cloudFolder(root: tempDir)
        XCTAssertEqual(
            loc.rootDirectory.lastPathComponent, ".humanist",
            "cloud root should be <root>/.humanist"
        )
        XCTAssertEqual(
            loc.catalogURL.lastPathComponent, "library.json"
        )
        // Cloud mode: aliases sit at the .humanist root, NOT under
        // an Aliases/ subdir. This asymmetry is what
        // `AliasDictionaryStore.resolveStoreURL` does today.
        XCTAssertEqual(
            loc.aliasesURL.deletingLastPathComponent().lastPathComponent,
            ".humanist"
        )
        XCTAssertEqual(loc.aliasesURL.lastPathComponent, "aliases.json")
        XCTAssertEqual(loc.snapshotsURL.lastPathComponent, "snapshots")
        XCTAssertEqual(loc.coversURL.lastPathComponent, "Covers")
    }

    func test_customLocal_paths_match_cloudFolder_layout() {
        // customLocal and cloudFolder share an on-disk layout —
        // both root at <picked>/.humanist/ with flat aliases.json,
        // snapshots/, Covers/ inside. Only the UserDefaults state
        // differs (shareAcrossMachines flag). Verify the URL
        // accessors confirm the shared layout.
        let custom = LibraryMigrationService.Location.customLocal(root: tempDir)
        let cloud  = LibraryMigrationService.Location.cloudFolder(root: tempDir)
        XCTAssertEqual(custom.rootDirectory, cloud.rootDirectory)
        XCTAssertEqual(custom.catalogURL, cloud.catalogURL)
        XCTAssertEqual(custom.aliasesURL, cloud.aliasesURL)
        XCTAssertEqual(custom.snapshotsURL, cloud.snapshotsURL)
        XCTAssertEqual(custom.coversURL, cloud.coversURL)
    }

    func test_customLocal_displayPath_mentions_dot_humanist() {
        let loc = LibraryMigrationService.Location.customLocal(root: tempDir)
        XCTAssertTrue(loc.displayPath.contains(".humanist"))
    }

    func test_customLocal_distinct_from_cloudFolder_in_equality() {
        // The two cases hash and compare separately even at the same
        // root — current() relies on the share toggle to disambiguate
        // them, but Location values themselves stay distinct so the
        // wizard renders the right destination row in the status
        // strip.
        let root = tempDir!
        let custom = LibraryMigrationService.Location.customLocal(root: root)
        let cloud  = LibraryMigrationService.Location.cloudFolder(root: root)
        XCTAssertNotEqual(custom, cloud)
    }

    func test_applicationSupport_aliases_path_uses_Aliases_subdir() {
        // Local mode: aliases live at
        // ~/Library/Application Support/Humanist/Aliases/aliases.json
        // The path resolution is what we're testing — not whether
        // the file is on disk.
        let loc = LibraryMigrationService.Location.applicationSupport
        XCTAssertEqual(loc.aliasesURL.lastPathComponent, "aliases.json")
        XCTAssertEqual(
            loc.aliasesURL.deletingLastPathComponent().lastPathComponent,
            "Aliases",
            "local-mode aliases should sit under an Aliases/ subdir"
        )
    }

    // MARK: - Pre-flight

    func test_preflight_blocks_when_source_equals_destination() {
        let loc = LibraryMigrationService.Location.cloudFolder(root: tempDir)
        let p = LibraryMigrationService.preflight(source: loc, destination: loc)
        XCTAssertFalse(p.canProceed)
        XCTAssertTrue(
            p.blockingIssues.contains { $0.contains("same location") },
            "same-location should be listed as a blocker"
        )
    }

    func test_preflight_blocks_when_destination_has_existing_catalog() throws {
        let source = LibraryMigrationService.Location.cloudFolder(
            root: tempDir.appendingPathComponent("src", isDirectory: true)
        )
        let destination = LibraryMigrationService.Location.cloudFolder(
            root: tempDir.appendingPathComponent("dst", isDirectory: true)
        )
        // Seed an existing catalog at the destination.
        try FileManager.default.createDirectory(
            at: destination.rootDirectory,
            withIntermediateDirectories: true
        )
        try Data("{\"entries\":[]}".utf8).write(to: destination.catalogURL)

        let p = LibraryMigrationService.preflight(
            source: source, destination: destination
        )
        XCTAssertFalse(p.canProceed)
        XCTAssertTrue(
            p.blockingIssues.contains { $0.contains("already has a library.json") }
        )
    }

    func test_preflight_succeeds_for_empty_source_and_writable_destination() {
        let source = LibraryMigrationService.Location.cloudFolder(
            root: tempDir.appendingPathComponent("src", isDirectory: true)
        )
        let destination = LibraryMigrationService.Location.cloudFolder(
            root: tempDir.appendingPathComponent("dst", isDirectory: true)
        )
        let p = LibraryMigrationService.preflight(
            source: source, destination: destination
        )
        XCTAssertTrue(p.canProceed,
            "writable dst + missing src catalog should proceed (dst starts empty)")
        XCTAssertFalse(p.sourceCatalogExists)
        XCTAssertEqual(p.sourceCatalogEntryCount, 0)
        XCTAssertTrue(p.destinationWritable)
        XCTAssertFalse(p.destinationHasExistingCatalog)
        XCTAssertTrue(p.advisoryNotes.contains { $0.contains("Embedding sidecars stay") })
    }

    func test_preflight_counts_source_entries() throws {
        let source = LibraryMigrationService.Location.cloudFolder(
            root: tempDir.appendingPathComponent("src", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: source.rootDirectory,
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "entries": [
                ["id": "00000000-0000-0000-0000-000000000001", "title": "A"],
                ["id": "00000000-0000-0000-0000-000000000002", "title": "B"],
                ["id": "00000000-0000-0000-0000-000000000003", "title": "C"],
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: source.catalogURL)

        let destination = LibraryMigrationService.Location.cloudFolder(
            root: tempDir.appendingPathComponent("dst", isDirectory: true)
        )
        let p = LibraryMigrationService.preflight(
            source: source, destination: destination
        )
        XCTAssertEqual(p.sourceCatalogEntryCount, 3)
        XCTAssertTrue(p.sourceCatalogExists)
        XCTAssertTrue(p.canProceed)
    }

    // MARK: - Copy round-trip

    func test_copy_round_trip_moves_catalog_aliases_snapshots_covers() async throws {
        let source = LibraryMigrationService.Location.cloudFolder(
            root: tempDir.appendingPathComponent("src", isDirectory: true)
        )
        let destination = LibraryMigrationService.Location.cloudFolder(
            root: tempDir.appendingPathComponent("dst", isDirectory: true)
        )
        // Seed the source: catalog + aliases + 2 snapshots + 2 covers.
        try FileManager.default.createDirectory(
            at: source.rootDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.snapshotsURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.coversURL,
            withIntermediateDirectories: true
        )
        try Data("{\"entries\":[{\"id\":\"a\"}]}".utf8).write(to: source.catalogURL)
        try Data("{}".utf8).write(to: source.aliasesURL)
        try Data("snap1".utf8).write(
            to: source.snapshotsURL.appendingPathComponent("snap1.json")
        )
        try Data("snap2".utf8).write(
            to: source.snapshotsURL.appendingPathComponent("snap2.json")
        )
        try Data("cover1".utf8).write(
            to: source.coversURL.appendingPathComponent("00000000-0000-0000-0000-000000000001.jpg")
        )
        try Data("cover2".utf8).write(
            to: source.coversURL.appendingPathComponent("00000000-0000-0000-0000-000000000002.jpg")
        )

        var events: [LibraryMigrationService.CopyEvent] = []
        for await event in LibraryMigrationService.copy(
            source: source, destination: destination
        ) {
            events.append(event)
        }
        XCTAssertTrue(events.contains(.completed), "copy should complete")
        XCTAssertFalse(events.contains { event in
            if case .failed = event { return true }
            return false
        }, "no failure events expected")

        // Destination should have all four pieces.
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: destination.catalogURL.path))
        XCTAssertTrue(fm.fileExists(atPath: destination.aliasesURL.path))
        XCTAssertTrue(fm.fileExists(atPath:
            destination.snapshotsURL.appendingPathComponent("snap1.json").path))
        XCTAssertTrue(fm.fileExists(atPath:
            destination.snapshotsURL.appendingPathComponent("snap2.json").path))
        XCTAssertTrue(fm.fileExists(atPath:
            destination.coversURL.appendingPathComponent("00000000-0000-0000-0000-000000000001.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath:
            destination.coversURL.appendingPathComponent("00000000-0000-0000-0000-000000000002.jpg").path))

        // Source should still be present (backup posture).
        XCTAssertTrue(fm.fileExists(atPath: source.catalogURL.path),
            "source must remain as backup until user explicitly cleans up")
    }

    func test_copy_handles_missing_source_aliases_without_failing() async throws {
        let source = LibraryMigrationService.Location.cloudFolder(
            root: tempDir.appendingPathComponent("src", isDirectory: true)
        )
        let destination = LibraryMigrationService.Location.cloudFolder(
            root: tempDir.appendingPathComponent("dst", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: source.rootDirectory,
            withIntermediateDirectories: true
        )
        try Data("{\"entries\":[]}".utf8).write(to: source.catalogURL)
        // No aliases file written.

        var events: [LibraryMigrationService.CopyEvent] = []
        for await event in LibraryMigrationService.copy(
            source: source, destination: destination
        ) {
            events.append(event)
        }
        XCTAssertTrue(events.contains(.completed))
        XCTAssertTrue(
            events.contains(.finishedAliases(copied: false)),
            "missing aliases file should be reported as copied=false, not failure"
        )
    }

    // MARK: - Commit

    /// `commit(to:)` writes UserDefaults to make the destination
    /// authoritative on the next launch. The test sets a known
    /// pre-state, commits, asserts the written keys, then restores
    /// the pre-state so other tests + the running app aren't
    /// disturbed.
    func test_commit_to_applicationSupport_clears_share_and_localRoot_keys() throws {
        let defaults = UserDefaults.standard
        let shareKey = ConversionSettingsKeys.shareLibraryAcrossMachines
        let localKey = ConversionSettingsKeys.localLibraryRootPath
        let savedShare = defaults.bool(forKey: shareKey)
        let savedLocal = defaults.string(forKey: localKey)
        defer {
            defaults.set(savedShare, forKey: shareKey)
            if let savedLocal { defaults.set(savedLocal, forKey: localKey) }
            else { defaults.removeObject(forKey: localKey) }
        }

        // Pre-state: customLocal set, sharing on.
        defaults.set(true, forKey: shareKey)
        defaults.set("/Volumes/example", forKey: localKey)

        LibraryMigrationService.commit(to: .applicationSupport)
        XCTAssertFalse(defaults.bool(forKey: shareKey),
            "applicationSupport commit should turn share toggle off")
        XCTAssertNil(defaults.string(forKey: localKey),
            "applicationSupport commit should clear local root override")
    }

    func test_commit_to_customLocal_writes_local_root_and_clears_share_toggle() throws {
        let defaults = UserDefaults.standard
        let shareKey = ConversionSettingsKeys.shareLibraryAcrossMachines
        let localKey = ConversionSettingsKeys.localLibraryRootPath
        let savedShare = defaults.bool(forKey: shareKey)
        let savedLocal = defaults.string(forKey: localKey)
        defer {
            defaults.set(savedShare, forKey: shareKey)
            if let savedLocal { defaults.set(savedLocal, forKey: localKey) }
            else { defaults.removeObject(forKey: localKey) }
        }

        defaults.set(true, forKey: shareKey)

        let pick = tempDir.appendingPathComponent("mylibrary", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pick, withIntermediateDirectories: true
        )
        LibraryMigrationService.commit(to: .customLocal(root: pick))
        XCTAssertFalse(defaults.bool(forKey: shareKey),
            "customLocal commit should turn share toggle off (single-Mac state)")
        XCTAssertEqual(defaults.string(forKey: localKey), pick.path)
    }

    func test_commit_to_cloudFolder_sets_share_toggle_and_clears_local_root() throws {
        let defaults = UserDefaults.standard
        let shareKey = ConversionSettingsKeys.shareLibraryAcrossMachines
        let outputKey = ConversionSettingsKeys.outputFolderPath
        let localKey = ConversionSettingsKeys.localLibraryRootPath
        let savedShare = defaults.bool(forKey: shareKey)
        let savedOutput = defaults.string(forKey: outputKey)
        let savedLocal = defaults.string(forKey: localKey)
        defer {
            defaults.set(savedShare, forKey: shareKey)
            if let savedOutput { defaults.set(savedOutput, forKey: outputKey) }
            else { defaults.removeObject(forKey: outputKey) }
            if let savedLocal { defaults.set(savedLocal, forKey: localKey) }
            else { defaults.removeObject(forKey: localKey) }
        }

        defaults.set("/Volumes/old-custom", forKey: localKey)

        let cloud = tempDir.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cloud, withIntermediateDirectories: true
        )
        LibraryMigrationService.commit(to: .cloudFolder(root: cloud))
        XCTAssertTrue(defaults.bool(forKey: shareKey))
        XCTAssertEqual(defaults.string(forKey: outputKey), cloud.path)
        XCTAssertNil(defaults.string(forKey: localKey),
            "cloud commit should clear any prior customLocal override")
    }

    // MARK: - Verification

    func test_verify_reports_catalog_entry_count_and_aliases_readability() throws {
        let loc = LibraryMigrationService.Location.cloudFolder(
            root: tempDir.appendingPathComponent("dst", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: loc.rootDirectory,
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "entries": [
                ["id": "00000000-0000-0000-0000-000000000001"],
                ["id": "00000000-0000-0000-0000-000000000002"],
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: loc.catalogURL)
        try Data("{}".utf8).write(to: loc.aliasesURL)

        let v = LibraryMigrationService.verify(at: loc)
        XCTAssertTrue(v.catalogReadable)
        XCTAssertEqual(v.catalogEntryCount, 2)
        XCTAssertTrue(v.aliasesReadable)
        XCTAssertTrue(v.allOK)
    }

    func test_verify_flags_unreadable_catalog() throws {
        let loc = LibraryMigrationService.Location.cloudFolder(
            root: tempDir.appendingPathComponent("dst", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: loc.rootDirectory,
            withIntermediateDirectories: true
        )
        try Data("not valid json {".utf8).write(to: loc.catalogURL)
        let v = LibraryMigrationService.verify(at: loc)
        XCTAssertFalse(v.catalogReadable)
        XCTAssertFalse(v.allOK)
    }
}
