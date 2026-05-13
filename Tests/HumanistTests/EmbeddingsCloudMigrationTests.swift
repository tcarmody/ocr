import XCTest
import Foundation
@testable import Humanist

/// Coverage for `EmbeddingsCloudMigration.migrate`: the test seam
/// that does the actual move work on supplied directories. Uses
/// real temp directories rather than mocks because the migration's
/// whole job is filesystem manipulation — a mocked FileManager
/// would only validate that we *called* it correctly, not that the
/// resulting files land where they should.
@MainActor
final class EmbeddingsCloudMigrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    func test_no_cloud_dir_returns_nothing_scanned() {
        let local = tempDir.appendingPathComponent("Local")
        let result = EmbeddingsCloudMigration.migrate(
            from: nil, to: local
        )
        XCTAssertFalse(result.scannedICloudDir)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.skippedLocalExists, 0)
        XCTAssertEqual(result.failed, 0)
        // Local dir still gets created so subsequent writes work.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: local.path
        ))
    }

    func test_missing_cloud_dir_returns_nothing_scanned() {
        let cloud = tempDir.appendingPathComponent("CloudThatDoesNotExist")
        let local = tempDir.appendingPathComponent("Local")
        let result = EmbeddingsCloudMigration.migrate(
            from: cloud, to: local
        )
        XCTAssertFalse(result.scannedICloudDir)
        XCTAssertEqual(result.moved, 0)
    }

    func test_moves_uuid_keyed_sidecars_from_cloud_to_local() throws {
        let cloud = tempDir.appendingPathComponent("Cloud")
        let local = tempDir.appendingPathComponent("Local")
        try FileManager.default.createDirectory(
            at: cloud, withIntermediateDirectories: true
        )

        let id1 = UUID()
        let id2 = UUID()
        let payload = Data("{}".utf8)
        try payload.write(to: cloud.appendingPathComponent("\(id1.uuidString).json"))
        try payload.write(to: cloud.appendingPathComponent("\(id2.uuidString).json"))

        let result = EmbeddingsCloudMigration.migrate(
            from: cloud, to: local
        )
        XCTAssertTrue(result.scannedICloudDir)
        XCTAssertEqual(result.moved, 2)
        XCTAssertEqual(result.skippedLocalExists, 0)
        XCTAssertEqual(result.failed, 0)

        // Cloud dir is empty after the move.
        let cloudContents = try FileManager.default
            .contentsOfDirectory(atPath: cloud.path)
        XCTAssertEqual(cloudContents.count, 0)

        // Both files landed locally with the same names.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: local.appendingPathComponent("\(id1.uuidString).json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: local.appendingPathComponent("\(id2.uuidString).json").path
        ))
    }

    func test_skips_non_json_entries() throws {
        // Stray files in the iCloud Embeddings dir — .DS_Store,
        // .icloud dataless placeholders, in-flight tempfiles —
        // should be left alone so we don't accidentally move
        // them into the local sidecar store.
        let cloud = tempDir.appendingPathComponent("Cloud")
        let local = tempDir.appendingPathComponent("Local")
        try FileManager.default.createDirectory(
            at: cloud, withIntermediateDirectories: true
        )

        let id = UUID()
        try Data("{}".utf8).write(
            to: cloud.appendingPathComponent("\(id.uuidString).json")
        )
        try Data().write(
            to: cloud.appendingPathComponent(".DS_Store")
        )
        try Data().write(
            to: cloud.appendingPathComponent(".\(id.uuidString).json.icloud")
        )

        let result = EmbeddingsCloudMigration.migrate(
            from: cloud, to: local
        )
        XCTAssertEqual(result.moved, 1)
        // .DS_Store and the .icloud placeholder are still in the
        // cloud dir.
        let cloudContents = Set(try FileManager.default
            .contentsOfDirectory(atPath: cloud.path))
        XCTAssertTrue(cloudContents.contains(".DS_Store"))
        XCTAssertTrue(cloudContents.contains(".\(id.uuidString).json.icloud"))
    }

    func test_local_file_wins_over_cloud_duplicate() throws {
        // The user has been chatting since the iCloud version was
        // written (or a parallel migration on another Mac already
        // ran). The local file is by definition newer / authoritative
        // — we must not overwrite it with the iCloud copy. The
        // iCloud file is left in place so the user can delete it
        // manually if they want.
        let cloud = tempDir.appendingPathComponent("Cloud")
        let local = tempDir.appendingPathComponent("Local")
        try FileManager.default.createDirectory(
            at: cloud, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: local, withIntermediateDirectories: true
        )

        let id = UUID()
        let name = "\(id.uuidString).json"
        try Data("{\"local\":true}".utf8).write(
            to: local.appendingPathComponent(name)
        )
        try Data("{\"cloud\":true}".utf8).write(
            to: cloud.appendingPathComponent(name)
        )

        let result = EmbeddingsCloudMigration.migrate(
            from: cloud, to: local
        )
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.skippedLocalExists, 1)

        // Local file content is untouched.
        let localBytes = try Data(
            contentsOf: local.appendingPathComponent(name)
        )
        XCTAssertEqual(String(data: localBytes, encoding: .utf8), "{\"local\":true}")

        // iCloud file is still in place — not moved, not deleted.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cloud.appendingPathComponent(name).path
        ))
    }

    func test_idempotent_second_run_is_a_no_op() throws {
        // Run twice. The second call sees an empty cloud dir and
        // returns scannedICloudDir=true / moved=0 — same effect as
        // any user who's already migrated.
        let cloud = tempDir.appendingPathComponent("Cloud")
        let local = tempDir.appendingPathComponent("Local")
        try FileManager.default.createDirectory(
            at: cloud, withIntermediateDirectories: true
        )

        let id = UUID()
        try Data("{}".utf8).write(
            to: cloud.appendingPathComponent("\(id.uuidString).json")
        )

        let first = EmbeddingsCloudMigration.migrate(
            from: cloud, to: local
        )
        XCTAssertEqual(first.moved, 1)

        let second = EmbeddingsCloudMigration.migrate(
            from: cloud, to: local
        )
        XCTAssertTrue(second.scannedICloudDir)
        XCTAssertEqual(second.moved, 0)
        XCTAssertEqual(second.skippedLocalExists, 0)
    }
}
