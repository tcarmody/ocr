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
