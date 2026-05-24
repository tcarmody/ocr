import XCTest
import Foundation
import CryptoKit
import EPUB
@testable import Humanist

/// Coverage for `EmbeddingsSidecarStore`'s keying scheme. Embeddings
/// are local-only — the share-library-across-machines toggle covers
/// `library.json` + aliases but does *not* affect embeddings, which
/// always live under `~/Library/Application Support/Humanist/Embeddings/`.
/// Routing collapses to:
///
///   * `libraryID` provided → `<appSupport>/<uuid>.emb` (binary)
///   * no `libraryID` (uncataloged book) → legacy SHA-keyed at
///     `<appSupport>/<sha256>.json`
///
/// The read fallback chain still consults legacy `.json` and
/// SHA-keyed paths so pre-Phase-C sidecars remain readable.
@MainActor
final class EmbeddingsSidecarStoreKeyingTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarKeyingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
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

    func test_writeURL_with_libraryID_uses_appsupport_uuid_emb() {
        let store = makeStore()
        let id = UUID()
        let url = store.writeURL(for: anyEpubURL(), libraryID: id)
        XCTAssertEqual(url.lastPathComponent, "\(id.uuidString).emb")
        XCTAssertTrue(url.path.contains("AppSupport"))
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

    func test_read_finds_UUID_keyed_emb_in_appsupport() throws {
        let appSupport = tempDir.appendingPathComponent("AppSupport")
        try FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        let store = EmbeddingsSidecarStore(baseDirectory: appSupport)
        let id = UUID()
        let sidecar = EmbeddingsSidecar.empty(
            backend: "emb-backend", dimension: 16
        )
        try EmbeddingsSidecarBinaryFormat.encode(sidecar).write(
            to: appSupport.appendingPathComponent("\(id.uuidString).emb")
        )
        let found = store.read(for: anyEpubURL(), libraryID: id)
        XCTAssertEqual(found?.backendIdentifier, "emb-backend")
    }

    func test_read_falls_back_to_legacy_uuid_json() throws {
        // No `.emb` file present (pre-Phase-C library). The UUID-
        // keyed `.json` still resolves via the next slot in the
        // candidate chain so users see no break before the
        // background binary upgrade has run.
        let appSupport = tempDir.appendingPathComponent("AppSupport")
        try FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        let store = EmbeddingsSidecarStore(baseDirectory: appSupport)
        let id = UUID()
        let sidecar = EmbeddingsSidecar.empty(
            backend: "legacy-json", dimension: 8
        )
        try JSONEncoder().encode(sidecar).write(
            to: appSupport.appendingPathComponent("\(id.uuidString).json")
        )
        let found = store.read(for: anyEpubURL(), libraryID: id)
        XCTAssertEqual(found?.backendIdentifier, "legacy-json")
    }

    func test_read_prefers_emb_over_legacy_json_when_both_exist() throws {
        // If both a `.emb` and a `.json` are present for the same
        // UUID (mid-upgrade state), the binary file wins. Critical
        // so a partial upgrade doesn't surface stale JSON data.
        let appSupport = tempDir.appendingPathComponent("AppSupport")
        try FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        let store = EmbeddingsSidecarStore(baseDirectory: appSupport)
        let id = UUID()

        let embSidecar = EmbeddingsSidecar.empty(
            backend: "winner-emb", dimension: 4
        )
        let jsonSidecar = EmbeddingsSidecar.empty(
            backend: "loser-json", dimension: 4
        )
        try EmbeddingsSidecarBinaryFormat.encode(embSidecar).write(
            to: appSupport.appendingPathComponent("\(id.uuidString).emb")
        )
        try JSONEncoder().encode(jsonSidecar).write(
            to: appSupport.appendingPathComponent("\(id.uuidString).json")
        )

        let found = store.read(for: anyEpubURL(), libraryID: id)
        XCTAssertEqual(found?.backendIdentifier, "winner-emb")
    }

    func test_read_falls_back_to_SHA_when_no_UUID_keyed_file_exists() {
        // Pre-UUID-keying sidecar still readable when only the
        // SHA-keyed file exists. Important for users whose oldest
        // sidecars predate the dual-keying scheme.
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

    // MARK: - clearMismatched / countMismatched

    func test_clearMismatched_removesOnlyOffPrefixSidecars() {
        let store = makeStore()
        let geminiID = UUID()
        let appleID = UUID()
        let gemini = EmbeddingsSidecar.empty(
            backend: "gemini.embedding-001.3072", dimension: 3072
        )
        let apple = EmbeddingsSidecar.empty(
            backend: "apple.nl.sentence.en", dimension: 512
        )
        store.write(gemini, for: anyEpubURL(), libraryID: geminiID)
        store.write(apple, for: anyEpubURL(), libraryID: appleID)

        XCTAssertEqual(
            store.countMismatched(primaryPrefix: "gemini."), 1
        )
        let removed = store.clearMismatched(primaryPrefix: "gemini.")
        XCTAssertEqual(removed, 1)

        XCTAssertNotNil(
            store.read(for: anyEpubURL(), libraryID: geminiID),
            "On-prefix sidecar should survive"
        )
        XCTAssertNil(
            store.read(for: anyEpubURL(), libraryID: appleID),
            "Off-prefix sidecar should be gone"
        )
        XCTAssertEqual(
            store.countMismatched(primaryPrefix: "gemini."), 0
        )
    }

    func test_clearMismatched_keepsWithinProviderModelVariants() {
        // Within-provider model switches (gemini-001 → 002) keep
        // the same prefix; this clear path deliberately doesn't
        // catch them — clearAll is the escape hatch. The federated
        // build still surfaces them via its exact-identifier
        // mismatch tally.
        let store = makeStore()
        let id = UUID()
        let sidecar = EmbeddingsSidecar.empty(
            backend: "gemini.embedding-001.768", dimension: 768
        )
        store.write(sidecar, for: anyEpubURL(), libraryID: id)
        XCTAssertEqual(
            store.countMismatched(primaryPrefix: "gemini."), 0
        )
        XCTAssertEqual(
            store.clearMismatched(primaryPrefix: "gemini."), 0
        )
        XCTAssertNotNil(store.read(for: anyEpubURL(), libraryID: id))
    }

    private func anyEpubURL() -> URL {
        tempDir.appendingPathComponent("any-book.epub")
    }
}
