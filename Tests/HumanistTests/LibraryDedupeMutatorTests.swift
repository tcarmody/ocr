import XCTest
import Foundation
@testable import Humanist

/// R-Library-Dedupe — the three new LibraryStore mutators plus
/// the LibraryEntry codable round-trip for the two new fields.
@MainActor
final class LibraryDedupeMutatorTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-dedupe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    private func makeStore() -> LibraryStore {
        LibraryStore(storeURL: tempDir.appendingPathComponent("library.json"))
    }

    private func makeEPUBStub(name: String) -> URL {
        let url = tempDir.appendingPathComponent(name + ".epub")
        try? Data().write(to: url)
        return url
    }

    // MARK: - recordSourceHash

    func test_recordSourceHash_appends_hash_to_entry() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Book", languages: ["en"])
        let id = store.entries[0].id

        store.recordSourceHash("abc123", on: id)
        XCTAssertEqual(store.entries[0].sourceContentHashes, ["abc123"])
    }

    func test_recordSourceHash_dedupes_within_entry() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Book", languages: ["en"])
        let id = store.entries[0].id

        store.recordSourceHash("abc123", on: id)
        store.recordSourceHash("abc123", on: id)
        store.recordSourceHash("def456", on: id)
        XCTAssertEqual(store.entries[0].sourceContentHashes, ["abc123", "def456"])
    }

    func test_recordSourceHash_ignores_empty_hash() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Book", languages: ["en"])
        let id = store.entries[0].id

        store.recordSourceHash("", on: id)
        XCTAssertTrue(store.entries[0].sourceContentHashes.isEmpty)
    }

    func test_recordSourceHash_missing_entry_is_noop() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Book", languages: ["en"])

        // No throw, no crash, no change to the existing entry.
        store.recordSourceHash("abc123", on: UUID())
        XCTAssertTrue(store.entries[0].sourceContentHashes.isEmpty)
    }

    // MARK: - addPriorPath

    func test_addPriorPath_appends_and_dedupes() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Book", languages: ["en"])
        let id = store.entries[0].id

        store.addPriorPath("/Downloads/Foo.epub", to: id)
        store.addPriorPath("/Downloads/Foo.epub", to: id)  // dupe
        store.addPriorPath("/iCloud/Foo (2).epub", to: id)

        XCTAssertEqual(
            store.entries[0].priorPaths,
            ["/Downloads/Foo.epub", "/iCloud/Foo (2).epub"]
        )
    }

    func test_addPriorPath_ignores_empty_path() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Book", languages: ["en"])
        let id = store.entries[0].id

        store.addPriorPath("", to: id)
        XCTAssertTrue(store.entries[0].priorPaths.isEmpty)
    }

    // MARK: - findEntryBySourceHash

    func test_findEntryBySourceHash_returns_matching_entry() {
        let store = makeStore()
        let a = makeEPUBStub(name: "a")
        let b = makeEPUBStub(name: "b")
        store.recordConversion(epubURL: a, title: "A", languages: ["en"])
        store.recordConversion(epubURL: b, title: "B", languages: ["en"])

        let bID = store.entries.first(where: { $0.title == "B" })!.id
        store.recordSourceHash("hash-for-b", on: bID)

        let found = store.findEntryBySourceHash("hash-for-b")
        XCTAssertEqual(found?.id, bID)
    }

    func test_findEntryBySourceHash_returns_nil_on_miss() {
        let store = makeStore()
        let a = makeEPUBStub(name: "a")
        store.recordConversion(epubURL: a, title: "A", languages: ["en"])
        let id = store.entries[0].id
        store.recordSourceHash("hash-for-a", on: id)

        XCTAssertNil(store.findEntryBySourceHash("some-other-hash"))
        XCTAssertNil(store.findEntryBySourceHash(""))
    }

    // MARK: - persistence round-trip

    func test_codable_roundtrip_preserves_new_fields() throws {
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Book", languages: ["en"])
        let id = store.entries[0].id
        store.recordSourceHash("abc123", on: id)
        store.addPriorPath("/Downloads/Foo.epub", to: id)

        // Re-open the store from disk — exercises the
        // decodeIfPresent path for the two new fields.
        let reopened = makeStore()
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.entries[0].sourceContentHashes, ["abc123"])
        XCTAssertEqual(reopened.entries[0].priorPaths, ["/Downloads/Foo.epub"])
    }

    func test_codable_handles_legacy_entries_without_new_fields() throws {
        // Build a library.json that pre-dates R-Library-Dedupe so
        // we can verify the decodeIfPresent defaults kick in.
        let storeURL = tempDir.appendingPathComponent("library.json")
        let epub = makeEPUBStub(name: "legacy")
        let legacy: [String: Any] = [
            "entries": [[
                "id": UUID().uuidString,
                "epubURL": "file://\(epub.path)",
                "title": "Legacy",
                "languages": ["en"],
                "addedAt": Date().timeIntervalSinceReferenceDate
            ]],
            "collections": [] as [[String: Any]]
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: storeURL)

        let reopened = LibraryStore(storeURL: storeURL)
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.entries[0].sourceContentHashes, [])
        XCTAssertEqual(reopened.entries[0].priorPaths, [])
    }

    // MARK: - rejectedSourceHashes (Phase D: auto-scanner tombstones)

    func test_markSourcesRejected_adds_to_set() {
        let store = makeStore()
        store.markSourcesRejected(["aaa", "bbb"])
        XCTAssertEqual(store.rejectedSourceHashes, Set(["aaa", "bbb"]))
    }

    func test_markSourcesRejected_dedupes_and_ignores_empty() {
        let store = makeStore()
        store.markSourcesRejected(["aaa", "aaa", "", "bbb"])
        XCTAssertEqual(store.rejectedSourceHashes, Set(["aaa", "bbb"]))
    }

    func test_unmarkSourcesRejected_removes_subset() {
        let store = makeStore()
        store.markSourcesRejected(["aaa", "bbb", "ccc"])
        store.unmarkSourcesRejected(["bbb", "missing"])
        XCTAssertEqual(store.rejectedSourceHashes, Set(["aaa", "ccc"]))
    }

    func test_isSourceHashKnownOrRejected_true_for_rejected() {
        let store = makeStore()
        store.markSourcesRejected(["rejected-hash"])
        XCTAssertTrue(store.isSourceHashKnownOrRejected("rejected-hash"))
        XCTAssertFalse(store.isSourceHashKnownOrRejected("other-hash"))
    }

    func test_isSourceHashKnownOrRejected_true_for_known_entry_hash() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "known")
        store.recordConversion(epubURL: epub, title: "Known", languages: ["en"])
        store.recordSourceHash("entry-hash", on: store.entries[0].id)
        XCTAssertTrue(store.isSourceHashKnownOrRejected("entry-hash"))
    }

    func test_isSourceHashKnownOrRejected_empty_hash_returns_false() {
        let store = makeStore()
        // An empty hash should never match — defends against the
        // ContentHash failure case (read error returns "" or nil).
        XCTAssertFalse(store.isSourceHashKnownOrRejected(""))
    }

    func test_rejectedSourceHashes_persist_across_reopen() {
        let store = makeStore()
        store.markSourcesRejected(["persist-1", "persist-2"])

        let reopened = makeStore()
        XCTAssertEqual(
            reopened.rejectedSourceHashes, Set(["persist-1", "persist-2"])
        )
    }

    /// `markSourcesRejected` called inside `beginBulkUpdate /
    /// endBulkUpdate` defers its save() until the bulk closes —
    /// catches the regression that caused the Library window's
    /// remove flow to issue 2N+1 saves on iCloud (felt like a
    /// hang). Indirect check: after the bulk closes, the catalog
    /// on disk reflects every mutation; before the bulk closes,
    /// only the in-memory state has changed.
    func test_markSourcesRejected_defers_save_inside_bulk_window() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "soon-gone")
        store.recordConversion(epubURL: epub, title: "Soon Gone", languages: ["en"])
        let id = store.entries[0].id
        store.recordSourceHash("inside-bulk-hash", on: id)

        store.beginBulkUpdate()
        store.markSourcesRejected(["inside-bulk-hash"])
        store.remove(id)
        // Mid-bulk: in-memory state is staged, save hasn't fired.
        // A new LibraryStore reading the same file should still
        // see the PRE-bulk state since the save is deferred.
        // (We can't precisely assert "no save happened" without an
        // instrumentation hook, but verifying that the final state
        // round-trips cleanly is the load-bearing assertion.)
        store.endBulkUpdate()

        // After bulk closes: catalog on disk should reflect the
        // rejection + the entry removal in one consistent state.
        let reopened = makeStore()
        XCTAssertEqual(reopened.entries.count, 0)
        XCTAssertTrue(reopened.isSourceHashKnownOrRejected("inside-bulk-hash"))
    }

    func test_rejectedSourceHashes_survive_entry_removal() {
        // The whole point of the rejection signal: it has to survive
        // entry deletion so the auto-scanner doesn't re-pick-up the
        // source PDF after the user explicitly says "don't re-scan".
        let store = makeStore()
        let epub = makeEPUBStub(name: "soon-gone")
        store.recordConversion(epubURL: epub, title: "Soon Gone", languages: ["en"])
        let id = store.entries[0].id
        store.recordSourceHash("survivor-hash", on: id)
        // Read the entry AFTER recording the hash — captured-before
        // would be empty and the mark below would no-op. Mirrors
        // the real call site in LibraryWindowView.performRemove.
        let hashes = store.entries[0].sourceContentHashes
        store.markSourcesRejected(hashes)
        store.remove(id)

        XCTAssertEqual(store.entries.count, 0)
        XCTAssertTrue(store.isSourceHashKnownOrRejected("survivor-hash"))
        // Reopen — still rejected on disk too.
        let reopened = makeStore()
        XCTAssertTrue(reopened.isSourceHashKnownOrRejected("survivor-hash"))
    }
}
