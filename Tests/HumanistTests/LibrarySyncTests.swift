import XCTest
import Foundation
import CryptoKit
import EPUB  // canonicalForFile
@testable import Humanist

/// R-Library-Sync Phase A coverage:
///
///   * `LibraryEntry`'s new `relativePath` field round-trips
///     through the catalog JSON (forward-compatible + backward-
///     compatible decode).
///   * On save, the store populates `relativePath` when the EPUB
///     lives under the configured output root.
///   * In sharing-across-machines mode, on load the store rewrites
///     each entry's `epubURL` from `<currentRoot>/<relativePath>`
///     — the portability invariant that makes a synced catalog
///     resolve correctly on a second Mac with a different
///     absolute root.
///   * `LibrarySyncMigration.run()` copies `library.json` from
///     Application Support to `<outputRoot>/.humanist/` and is
///     idempotent on re-run.
///
/// Tests stub the output root via the same `@AppStorage`
/// `outputFolderPath` key the app uses; each test cleans up
/// after itself.
@MainActor
final class LibrarySyncTests: XCTestCase {

    private var tempDir: URL!
    private var savedOutputRoot: String?
    private var savedShareToggle: Bool?

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        // Snapshot prefs so we can restore after the test.
        savedOutputRoot = UserDefaults.standard.string(
            forKey: ConversionSettingsKeys.outputFolderPath
        )
        savedShareToggle = UserDefaults.standard.bool(
            forKey: ConversionSettingsKeys.shareLibraryAcrossMachines
        )
    }

    override func tearDown() async throws {
        if let saved = savedOutputRoot {
            UserDefaults.standard.set(saved, forKey: ConversionSettingsKeys.outputFolderPath)
        } else {
            UserDefaults.standard.removeObject(forKey: ConversionSettingsKeys.outputFolderPath)
        }
        if let saved = savedShareToggle {
            UserDefaults.standard.set(saved, forKey: ConversionSettingsKeys.shareLibraryAcrossMachines)
        } else {
            UserDefaults.standard.removeObject(forKey: ConversionSettingsKeys.shareLibraryAcrossMachines)
        }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - helpers

    private func makeEPUBStub(at url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data().write(to: url)
    }

    private func makeStore(at url: URL) -> LibraryStore {
        LibraryStore(storeURL: url)
    }

    // MARK: - relativePath round-trip

    func test_recordConversion_populates_relativePath_under_root() {
        // Configure a root, drop an EPUB at <root>/Books/foo.epub,
        // catalog it; on save the entry should carry the
        // relativePath `Books/foo.epub`.
        let root = tempDir.appendingPathComponent("Library")
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(root.path,
            forKey: ConversionSettingsKeys.outputFolderPath)

        let epub = root.appendingPathComponent("Books/foo.epub")
        makeEPUBStub(at: epub)

        let storeURL = tempDir.appendingPathComponent("library.json")
        let store = makeStore(at: storeURL)
        store.recordConversion(epubURL: epub, title: "Foo", languages: [])

        // Read the raw file to check the persisted shape.
        let data = try! Data(contentsOf: storeURL)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let entries = json["entries"] as! [[String: Any]]
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["relativePath"] as? String,
                       "Books/foo.epub")
    }

    func test_legacy_entry_without_relativePath_decodes_cleanly() {
        // Pre-R-Library-Sync libraries have no relativePath key.
        // Decoder must accept that shape (decodeIfPresent) and
        // default the field to nil.
        let entry = LibraryEntry(
            epubURL: tempDir.appendingPathComponent("legacy.epub"),
            title: "Legacy",
            addedAt: Date()
        )
        let encoder = JSONEncoder()
        let data = try! encoder.encode([entry])
        // Strip the relativePath key from the encoded JSON to
        // simulate a pre-extension write.
        var json = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        json[0].removeValue(forKey: "relativePath")
        let stripped = try! JSONSerialization.data(withJSONObject: json)

        let decoded = try! JSONDecoder().decode([LibraryEntry].self, from: stripped)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].relativePath)
    }

    // MARK: - load resolves against current root in sharing mode

    func test_resolveAgainstOutputRoot_rewrites_epubURL_under_new_root() {
        // The portability invariant: same JSON, different
        // absolute root → epubURL resolves to the local root's
        // path. Critical for catalogs written on machine A
        // loading correctly on machine B.
        let machineBRoot = tempDir.appendingPathComponent("MachineB")
        try? FileManager.default.createDirectory(
            at: machineBRoot, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(machineBRoot.path,
            forKey: ConversionSettingsKeys.outputFolderPath)

        // Construct an entry as if written on machine A.
        let machineAEpub = URL(fileURLWithPath:
            "/Users/alice/Library/Mobile Documents/iCloud~Drive/MachineA/Books/foo.epub")
        var entry = LibraryEntry(
            epubURL: machineAEpub,
            title: "Foo",
            addedAt: Date()
        )
        entry.relativePath = "Books/foo.epub"

        let resolved = LibraryStore.resolveAgainstOutputRoot(entry)
        let expected = machineBRoot.appendingPathComponent("Books/foo.epub")
            .canonicalForFile
        XCTAssertEqual(resolved.epubURL.canonicalForFile, expected)
        XCTAssertEqual(resolved.id, entry.id,
            "id must survive the rewrite — it's the only stable identity")
        XCTAssertEqual(resolved.relativePath, "Books/foo.epub")
    }

    func test_resolveAgainstOutputRoot_is_noop_when_relativePath_missing() {
        // Books outside the configured root (legacy entries, or
        // imports from arbitrary paths) keep their absolute URL.
        let root = tempDir.appendingPathComponent("Library")
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(root.path,
            forKey: ConversionSettingsKeys.outputFolderPath)
        let entry = LibraryEntry(
            epubURL: tempDir.appendingPathComponent("Outside/foo.epub"),
            title: "Outside",
            addedAt: Date()
        )
        // No relativePath set.
        let resolved = LibraryStore.resolveAgainstOutputRoot(entry)
        XCTAssertEqual(resolved.epubURL, entry.epubURL)
    }

    func test_resolveAgainstOutputRoot_is_noop_when_no_root_configured() {
        // Sharing off / root unset: even an entry with a
        // relativePath stays as-is. The legacy single-machine
        // path keeps working.
        UserDefaults.standard.removeObject(
            forKey: ConversionSettingsKeys.outputFolderPath
        )
        var entry = LibraryEntry(
            epubURL: tempDir.appendingPathComponent("foo.epub"),
            title: "Foo",
            addedAt: Date()
        )
        entry.relativePath = "Books/foo.epub"
        let resolved = LibraryStore.resolveAgainstOutputRoot(entry)
        XCTAssertEqual(resolved.epubURL, entry.epubURL)
    }

    // MARK: - migration

    func test_migration_returns_rootMissing_when_no_output_folder() {
        UserDefaults.standard.removeObject(
            forKey: ConversionSettingsKeys.outputFolderPath
        )
        XCTAssertEqual(LibrarySyncMigration.run(), .rootMissing)
    }

    func test_migration_returns_nothingToMigrate_when_no_existing_catalog() throws {
        // Configure a root but ensure no Application Support
        // library.json exists. Migration should report nothing to
        // do — the in-root file gets created fresh on next save.
        let root = tempDir.appendingPathComponent("Library")
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(root.path,
            forKey: ConversionSettingsKeys.outputFolderPath)

        // Defensive: remove any pre-existing Application Support
        // library.json that the dev environment might have. We
        // restore it implicitly via teardown's pref restoration
        // (not perfect, but the file's untouched if absent).
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let supportURL = support
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("library.json")
        let preExisting = FileManager.default.fileExists(atPath: supportURL.path)
        if preExisting {
            // Skip this test on developer machines with real data
            // — the assertion would be wrong here, and we don't
            // want to clobber the user's library.
            throw XCTSkip("real Humanist library present at \(supportURL.path); test skipped")
        }
        XCTAssertEqual(LibrarySyncMigration.run(), .nothingToMigrate)
    }

    // MARK: - Phase B: sidecar + alias migration

    func test_runFull_copies_sha_keyed_sidecar_to_root_uuid_location() throws {
        // Set up: an EPUB at <root>/Books/foo.epub, a catalog
        // entry pointing at it with a known UUID, and a
        // SHA-keyed sidecar in Application Support. After
        // runFull, the UUID-keyed copy should exist at
        // <root>/.humanist/Embeddings/<uuid>.json.
        let root = tempDir.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(root.path,
            forKey: ConversionSettingsKeys.outputFolderPath)

        let epub = root.appendingPathComponent("Books/foo.epub")
        try FileManager.default.createDirectory(
            at: epub.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: epub)

        // Build the catalog row in a real LibraryStore (so its UUID
        // is captured correctly).
        let storeURL = tempDir.appendingPathComponent("library.json")
        let library = LibraryStore(storeURL: storeURL)
        library.recordConversion(epubURL: epub, title: "Foo", languages: [])
        guard let entry = library.entries.first else {
            return XCTFail("expected one entry after recordConversion")
        }

        // Plant a SHA-keyed sidecar at the AppSupport location
        // the migration helper will scan. We can't redirect that
        // location from inside the test (it uses the real
        // Application Support path), so this assertion is
        // skip-gated: if there's no pre-existing AppSupport
        // sidecar dir we can safely write into, skip.
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let supportEmbDir = appSupport
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("Embeddings", isDirectory: true)
        // Only run when the developer machine is happy to host a
        // throwaway sidecar; otherwise skip to avoid mutating
        // real-user data.
        if FileManager.default.fileExists(atPath: supportEmbDir.path) {
            // Don't pollute a real Humanist install.
            throw XCTSkip("Application Support/Humanist/Embeddings exists; skipping to avoid touching real data")
        }
        try FileManager.default.createDirectory(
            at: supportEmbDir, withIntermediateDirectories: true
        )
        defer {
            // Clean up our test sidecar dir on exit.
            try? FileManager.default.removeItem(at: supportEmbDir)
        }
        let canonical = entry.epubURL
            .canonicalForFile.standardizedFileURL.path
        let sha = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let legacyURL = supportEmbDir.appendingPathComponent("\(sha).json")
        let sidecar = EmbeddingsSidecar.empty(
            backend: "legacy", dimension: 8
        )
        try JSONEncoder().encode(sidecar).write(to: legacyURL)

        // Run the full migration.
        let result = LibrarySyncMigration.runFull(library: library)
        XCTAssertEqual(result.sidecarsCopied, 1)

        let expectedDest = root
            .appendingPathComponent(".humanist/Embeddings")
            .appendingPathComponent("\(entry.id.uuidString).json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedDest.path),
            "UUID-keyed sidecar must exist at \(expectedDest.path)"
        )
    }

    func test_runFull_skips_already_migrated_sidecars() {
        // Idempotent re-run: if the UUID-keyed copy already
        // exists, sidecarsCopied is 0 — the helper doesn't
        // re-copy or clobber.
        let root = tempDir.appendingPathComponent("Library")
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(root.path,
            forKey: ConversionSettingsKeys.outputFolderPath)

        let epub = root.appendingPathComponent("Books/foo.epub")
        makeEPUBStub(at: epub)
        let library = LibraryStore(
            storeURL: tempDir.appendingPathComponent("library.json")
        )
        library.recordConversion(epubURL: epub, title: "Foo", languages: [])
        guard let entry = library.entries.first else { return }

        // Plant an already-migrated UUID-keyed file under the
        // root. Migration should skip it.
        let destDir = root
            .appendingPathComponent(".humanist/Embeddings")
        try? FileManager.default.createDirectory(
            at: destDir, withIntermediateDirectories: true
        )
        try? Data().write(
            to: destDir.appendingPathComponent("\(entry.id.uuidString).json")
        )

        let result = LibrarySyncMigration.runFull(library: library)
        XCTAssertEqual(result.sidecarsCopied, 0)
    }

    func test_migration_is_idempotent_when_inroot_exists() {
        // If the in-root catalog already exists, migration is a
        // no-op (alreadyMigrated). This covers the multi-machine
        // case: machine B activates sync; machine A's catalog
        // already sits under the shared root.
        let root = tempDir.appendingPathComponent("Library")
        let inRootDir = root.appendingPathComponent(".humanist")
        try? FileManager.default.createDirectory(
            at: inRootDir, withIntermediateDirectories: true
        )
        let inRootURL = inRootDir.appendingPathComponent("library.json")
        try? Data().write(to: inRootURL)

        UserDefaults.standard.set(root.path,
            forKey: ConversionSettingsKeys.outputFolderPath)
        XCTAssertEqual(LibrarySyncMigration.run(), .alreadyMigrated)
    }
}
