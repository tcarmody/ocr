import XCTest
import Foundation
import CryptoKit
import EPUB
@testable import Humanist

/// R-Library-Sync Phase B coverage for `EmbeddingsSidecarStore`'s
/// dual keying scheme. The store routes by libraryID + sharing
/// mode + output root:
///
///   * `libraryID + sharing on + root configured` →
///     `<root>/.humanist/Embeddings/<uuid>.json`
///   * `libraryID` (sharing off) → `<appSupport>/<uuid>.json`
///   * no `libraryID` (uncataloged book) → legacy SHA-keyed at
///     `<appSupport>/<sha256>.json`
///
/// Reads walk the candidate chain so existing SHA-keyed sidecars
/// stay usable during the migration window; writes go to the
/// preferred location for the current call.
@MainActor
final class EmbeddingsSidecarStoreKeyingTests: XCTestCase {

    private var tempDir: URL!
    private var savedOutputRoot: String?
    private var savedShareToggle: Bool?

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarKeyingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        savedOutputRoot = UserDefaults.standard.string(
            forKey: ConversionSettingsKeys.outputFolderPath
        )
        savedShareToggle = UserDefaults.standard.bool(
            forKey: ConversionSettingsKeys.shareLibraryAcrossMachines
        )
        // Reset to a clean baseline so test ordering doesn't bite.
        UserDefaults.standard.removeObject(
            forKey: ConversionSettingsKeys.outputFolderPath
        )
        UserDefaults.standard.set(false,
            forKey: ConversionSettingsKeys.shareLibraryAcrossMachines)
    }

    override func tearDown() async throws {
        if let saved = savedOutputRoot {
            UserDefaults.standard.set(saved,
                forKey: ConversionSettingsKeys.outputFolderPath)
        } else {
            UserDefaults.standard.removeObject(
                forKey: ConversionSettingsKeys.outputFolderPath
            )
        }
        if let saved = savedShareToggle {
            UserDefaults.standard.set(saved,
                forKey: ConversionSettingsKeys.shareLibraryAcrossMachines)
        } else {
            UserDefaults.standard.removeObject(
                forKey: ConversionSettingsKeys.shareLibraryAcrossMachines
            )
        }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    private func makeStore() -> EmbeddingsSidecarStore {
        EmbeddingsSidecarStore(
            baseDirectory: tempDir.appendingPathComponent("AppSupport")
        )
    }

    // MARK: - writeURL routing

    func test_writeURL_with_libraryID_and_sharing_off_uses_appsupport_uuid() {
        let store = makeStore()
        let id = UUID()
        let url = store.writeURL(for: anyEpubURL(), libraryID: id)
        XCTAssertEqual(url.lastPathComponent, "\(id.uuidString).json")
        XCTAssertTrue(url.path.contains("AppSupport"))
    }

    func test_writeURL_with_libraryID_and_sharing_on_uses_root_uuid() {
        let root = tempDir.appendingPathComponent("Library")
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(root.path,
            forKey: ConversionSettingsKeys.outputFolderPath)
        UserDefaults.standard.set(true,
            forKey: ConversionSettingsKeys.shareLibraryAcrossMachines)

        let store = makeStore()
        let id = UUID()
        let url = store.writeURL(for: anyEpubURL(), libraryID: id)
        XCTAssertEqual(url.lastPathComponent, "\(id.uuidString).json")
        XCTAssertTrue(url.path.contains(".humanist/Embeddings"))
        XCTAssertTrue(url.path.hasPrefix(root.path))
    }

    func test_writeURL_without_libraryID_uses_legacy_SHA_keyed_path() {
        let store = makeStore()
        let epub = anyEpubURL()
        let url = store.writeURL(for: epub, libraryID: nil)
        let canonical = epub.canonicalForFile.standardizedFileURL.path
        let expectedSHA = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(url.lastPathComponent, "\(expectedSHA).json")
    }

    // MARK: - read fallback chain

    func test_read_prefers_UUID_at_root_over_appsupport_under_sharing() {
        let root = tempDir.appendingPathComponent("Library")
        let appSupport = tempDir.appendingPathComponent("AppSupport")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        UserDefaults.standard.set(root.path,
            forKey: ConversionSettingsKeys.outputFolderPath)
        UserDefaults.standard.set(true,
            forKey: ConversionSettingsKeys.shareLibraryAcrossMachines)

        let store = EmbeddingsSidecarStore(baseDirectory: appSupport)
        let id = UUID()
        let epub = anyEpubURL()

        // Plant a sidecar at the in-root location (preferred) and
        // a different one at AppSupport. Reader must return the
        // in-root one.
        let rootSidecar = EmbeddingsSidecar.empty(
            backend: "root-backend", dimension: 4
        )
        let appSidecar = EmbeddingsSidecar.empty(
            backend: "app-backend", dimension: 8
        )
        let rootDir = root
            .appendingPathComponent(".humanist/Embeddings")
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try! JSONEncoder().encode(rootSidecar).write(
            to: rootDir.appendingPathComponent("\(id.uuidString).json")
        )
        try! JSONEncoder().encode(appSidecar).write(
            to: appSupport.appendingPathComponent("\(id.uuidString).json")
        )

        let found = store.read(for: epub, libraryID: id)
        XCTAssertEqual(found?.backendIdentifier, "root-backend",
            "root location should win when both exist")
    }

    func test_read_falls_back_to_appsupport_UUID_when_root_missing() {
        // Sharing-on but the root location hasn't been written
        // yet (typical pre-migration state). The AppSupport
        // UUID-keyed file should still be readable.
        let root = tempDir.appendingPathComponent("Library")
        let appSupport = tempDir.appendingPathComponent("AppSupport")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        UserDefaults.standard.set(root.path,
            forKey: ConversionSettingsKeys.outputFolderPath)
        UserDefaults.standard.set(true,
            forKey: ConversionSettingsKeys.shareLibraryAcrossMachines)

        let store = EmbeddingsSidecarStore(baseDirectory: appSupport)
        let id = UUID()
        let sidecar = EmbeddingsSidecar.empty(
            backend: "app-backend", dimension: 16
        )
        try! JSONEncoder().encode(sidecar).write(
            to: appSupport.appendingPathComponent("\(id.uuidString).json")
        )
        let found = store.read(for: anyEpubURL(), libraryID: id)
        XCTAssertEqual(found?.backendIdentifier, "app-backend")
    }

    func test_read_falls_back_to_SHA_when_no_UUID_keyed_file_exists() {
        // Pure migration-window case: a pre-Phase-B book that has
        // a SHA-keyed sidecar in AppSupport. Reads with a
        // libraryID should still find it via the SHA fallback in
        // the candidate chain.
        let store = makeStore()
        let epub = anyEpubURL()
        let canonical = epub.canonicalForFile.standardizedFileURL.path
        let sha = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let appSupport = tempDir.appendingPathComponent("AppSupport")
        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        let sidecar = EmbeddingsSidecar.empty(
            backend: "legacy-sha", dimension: 32
        )
        try! JSONEncoder().encode(sidecar).write(
            to: appSupport.appendingPathComponent("\(sha).json")
        )
        let found = store.read(for: epub, libraryID: UUID())
        XCTAssertEqual(found?.backendIdentifier, "legacy-sha",
            "SHA-keyed fallback should win when no UUID file exists")
    }

    // MARK: - write+read round-trip

    func test_write_then_read_round_trips_under_UUID_keying() {
        let store = makeStore()
        let id = UUID()
        let original = EmbeddingsSidecar.empty(
            backend: "round-trip", dimension: 64
        )
        store.write(original, for: anyEpubURL(), libraryID: id)
        let restored = store.read(for: anyEpubURL(), libraryID: id)
        XCTAssertEqual(restored?.backendIdentifier, "round-trip")
        XCTAssertEqual(restored?.dimension, 64)
    }

    func test_write_then_read_legacy_path_round_trips_too() {
        // Without libraryID, both write + read go to the legacy
        // SHA-keyed path. The existing chat sites that don't yet
        // have catalog access (uncataloged books) still work.
        let store = makeStore()
        let epub = anyEpubURL()
        let original = EmbeddingsSidecar.empty(
            backend: "legacy-round-trip", dimension: 16
        )
        store.write(original, for: epub, libraryID: nil)
        let restored = store.read(for: epub, libraryID: nil)
        XCTAssertEqual(restored?.backendIdentifier, "legacy-round-trip")
    }

    private func anyEpubURL() -> URL {
        tempDir.appendingPathComponent("any-book.epub")
    }
}
