import XCTest
import Foundation
@testable import Humanist

/// Coverage for `EmbeddingsBinaryUpgrade.upgrade(directory:)` —
/// the test seam that does the JSON → `.emb` conversion without
/// touching UserDefaults or NSLog.
@MainActor
final class EmbeddingsBinaryUpgradeTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddingsUpgradeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    func test_missing_directory_reports_not_scanned() {
        let absent = tempDir.appendingPathComponent("Nope")
        let result = EmbeddingsBinaryUpgrade.upgrade(directory: absent)
        XCTAssertFalse(result.scannedDir)
        XCTAssertEqual(result.converted, 0)
        XCTAssertEqual(result.unreadable, 0)
        XCTAssertEqual(result.writeFailed, 0)
    }

    func test_empty_directory_returns_zero_with_scanned_true() throws {
        let dir = tempDir.appendingPathComponent("Embeddings")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let result = EmbeddingsBinaryUpgrade.upgrade(directory: dir)
        XCTAssertTrue(result.scannedDir)
        XCTAssertEqual(result.converted, 0)
    }

    func test_converts_json_sidecar_to_emb_and_round_trips() throws {
        let dir = tempDir.appendingPathComponent("Embeddings")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )

        let id = UUID()
        let original = EmbeddingsSidecar(
            schemaVersion: EmbeddingsSidecar.currentSchemaVersion,
            backendIdentifier: "test-backend",
            dimension: 4,
            paragraphs: [
                EmbeddingsSidecar.Entry(
                    chapterIdx: 2, paragraphIdx: 5, textHash: "abc",
                    vector: [0.1, 0.2, 0.3, 0.4], text: "hello"
                )
            ],
            hierarchy: nil, entities: nil
        )
        let jsonURL = dir.appendingPathComponent("\(id.uuidString).json")
        try JSONEncoder().encode(original).write(to: jsonURL)

        let result = EmbeddingsBinaryUpgrade.upgrade(directory: dir)
        XCTAssertEqual(result.converted, 1)
        XCTAssertEqual(result.unreadable, 0)
        XCTAssertEqual(result.writeFailed, 0)

        // JSON is gone, .emb is in its place.
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path))
        let embURL = dir.appendingPathComponent("\(id.uuidString).emb")
        XCTAssertTrue(FileManager.default.fileExists(atPath: embURL.path))

        // The .emb decodes back to the same sidecar.
        let data = try Data(contentsOf: embURL)
        let restored = try EmbeddingsSidecarBinaryFormat.decode(data)
        XCTAssertEqual(restored.backendIdentifier, "test-backend")
        XCTAssertEqual(restored.dimension, 4)
        XCTAssertEqual(restored.paragraphs.count, 1)
        XCTAssertEqual(restored.paragraphs[0].vector,
                       [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(restored.paragraphs[0].text, "hello")
    }

    func test_unreadable_json_left_in_place_and_counted() throws {
        let dir = tempDir.appendingPathComponent("Embeddings")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let id = UUID()
        let jsonURL = dir.appendingPathComponent("\(id.uuidString).json")
        try Data("garbage not json".utf8).write(to: jsonURL)

        let result = EmbeddingsBinaryUpgrade.upgrade(directory: dir)
        XCTAssertEqual(result.converted, 0)
        XCTAssertEqual(result.unreadable, 1)
        // Source is untouched — the per-book chat path will rebuild
        // it on next open through the existing fallback.
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
    }

    func test_resumes_after_crash_between_write_and_delete() throws {
        // Simulate: a prior run wrote the `.emb` successfully but
        // crashed before deleting the `.json`. The next run should
        // see the `.emb`, treat the `.json` as stale, and delete it
        // without re-encoding (which would waste work and could
        // disagree with the already-written `.emb` if the format
        // ever drifted).
        let dir = tempDir.appendingPathComponent("Embeddings")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let id = UUID()
        let sidecar = EmbeddingsSidecar(
            schemaVersion: EmbeddingsSidecar.currentSchemaVersion,
            backendIdentifier: "x", dimension: 2,
            paragraphs: [
                EmbeddingsSidecar.Entry(
                    chapterIdx: 0, paragraphIdx: 0, textHash: "h",
                    vector: [1, 2], text: nil
                )
            ],
            hierarchy: nil, entities: nil
        )
        // Plant both:
        let jsonURL = dir.appendingPathComponent("\(id.uuidString).json")
        let embURL = dir.appendingPathComponent("\(id.uuidString).emb")
        try JSONEncoder().encode(sidecar).write(to: jsonURL)
        try EmbeddingsSidecarBinaryFormat.encode(sidecar).write(to: embURL)

        let embBefore = try Data(contentsOf: embURL)

        let result = EmbeddingsBinaryUpgrade.upgrade(directory: dir)
        XCTAssertEqual(result.converted, 0,
            "an already-converted file should not count toward converted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path),
            "stale .json must be deleted")
        let embAfter = try Data(contentsOf: embURL)
        XCTAssertEqual(embBefore, embAfter,
            "existing .emb must be left untouched")
    }

    func test_skips_non_json_entries() throws {
        let dir = tempDir.appendingPathComponent("Embeddings")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        try Data().write(to: dir.appendingPathComponent("README.txt"))
        try Data().write(to: dir.appendingPathComponent("alreadyemb.emb"))

        let result = EmbeddingsBinaryUpgrade.upgrade(directory: dir)
        XCTAssertEqual(result.converted, 0)
        XCTAssertEqual(result.unreadable, 0)
        // Untouched.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(".DS_Store").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("README.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("alreadyemb.emb").path))
    }
}
