import XCTest
import Foundation
import EPUB  // canonicalForFile
@testable import Humanist

/// `LibraryStore` JSON round-trip + dedup + record-open semantics.
@MainActor
final class LibraryStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("humanist-library-test-\(UUID().uuidString)")
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

    /// Create a real .epub stub on disk so `LibraryStore.load`'s
    /// existence-filter doesn't drop the entry under test. Bytes
    /// don't matter — only file presence.
    private func makeEPUBStub(name: String) -> URL {
        let url = tempDir.appendingPathComponent(name + ".epub")
        try? Data().write(to: url)
        return url
    }

    // MARK: - recordConversion

    func test_recordConversion_appends_new_entry() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "book-a")
        store.recordConversion(epubURL: epub, title: "Book A", languages: ["en"])
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].title, "Book A")
        XCTAssertEqual(store.entries[0].languages, ["en"])
        XCTAssertNil(store.entries[0].lastOpened)
    }

    func test_recordConversion_dedupes_by_canonical_url() {
        // Re-converting to the same .epub shouldn't duplicate the
        // row — just refresh title + languages and keep the
        // original `addedAt` so the "added on" date stays honest.
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Original", languages: ["en"])
        let firstAddedAt = store.entries[0].addedAt
        store.recordConversion(epubURL: epub, title: "Updated", languages: ["en", "grc"])
        XCTAssertEqual(store.entries.count, 1, "re-conversion must not duplicate")
        XCTAssertEqual(store.entries[0].title, "Updated")
        XCTAssertEqual(store.entries[0].languages, ["en", "grc"])
        XCTAssertEqual(store.entries[0].addedAt, firstAddedAt,
            "addedAt must be preserved across re-conversion")
    }

    // MARK: - recordEPUBContentHash + bookID (R-Reader-Stable-Position-Key)

    func test_recordEPUBContentHash_stamps_hash_and_bookID() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Book", languages: ["en"])
        store.recordEPUBContentHash(
            "deadbeef", bookID: "urn:uuid:abc", forEPUB: epub
        )
        XCTAssertEqual(store.entries[0].epubContentHash, "deadbeef")
        XCTAssertEqual(store.entries[0].epubBookID, "urn:uuid:abc")
    }

    func test_recordEPUBContentHash_without_bookID_leaves_it_nil() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Book", languages: ["en"])
        store.recordEPUBContentHash("deadbeef", forEPUB: epub)
        XCTAssertEqual(store.entries[0].epubContentHash, "deadbeef")
        XCTAssertNil(store.entries[0].epubBookID)
    }

    /// A catalog written before this field must still decode (the
    /// new key defaults to nil), so upgrades don't drop the library.
    func test_libraryEntry_decodes_legacy_json_without_epubBookID() throws {
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "epubURL": "file:///tmp/book.epub",
          "title": "Legacy",
          "languages": ["en"],
          "addedAt": "2024-01-01T00:00:00Z",
          "epubContentHash": "abc123"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(
            LibraryEntry.self, from: Data(legacy.utf8)
        )
        XCTAssertEqual(entry.epubContentHash, "abc123")
        XCTAssertNil(entry.epubBookID)
    }

    // MARK: - recordOpen

    func test_recordOpen_bumps_lastOpened() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Book", languages: [])
        XCTAssertNil(store.entries[0].lastOpened)
        store.recordOpen(epub)
        XCTAssertNotNil(store.entries[0].lastOpened)
    }

    func test_recordOpen_is_noop_for_unknown_url() {
        // Library is for "books I converted in this app" — opening
        // an EPUB the library doesn't know about (third-party file
        // dragged in for editing) doesn't retroactively add it.
        let store = makeStore()
        let unknown = makeEPUBStub(name: "unknown")
        store.recordOpen(unknown)
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - persistence

    func test_entries_round_trip_through_disk() {
        let store = makeStore()
        let a = makeEPUBStub(name: "a")
        let b = makeEPUBStub(name: "b")
        store.recordConversion(epubURL: a, title: "A", languages: ["en"])
        store.recordConversion(epubURL: b, title: "B", languages: ["grc"])
        store.recordOpen(a)

        let restarted = makeStore()
        XCTAssertEqual(restarted.entries.count, 2)
        let aEntry = restarted.entries.first { $0.title == "A" }
        XCTAssertNotNil(aEntry?.lastOpened, "lastOpened must persist")
    }

    func test_load_filters_out_missing_files() {
        // An entry whose .epub got moved / deleted on disk should
        // be dropped on next load — same posture as RecentsStore.
        let store = makeStore()
        let real = makeEPUBStub(name: "real")
        let phantomURL = tempDir.appendingPathComponent("phantom.epub")
        // Phantom is never written — no file backing.
        store.recordConversion(epubURL: real, title: "Real", languages: [])
        store.recordConversion(epubURL: phantomURL, title: "Phantom", languages: [])
        XCTAssertEqual(store.entries.count, 2)

        let restarted = makeStore()
        XCTAssertEqual(restarted.entries.count, 1,
            "missing file should be pruned on load")
        XCTAssertEqual(restarted.entries[0].title, "Real")
    }

    // MARK: - remove

    func test_remove_drops_entry() {
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Book", languages: [])
        let id = store.entries[0].id
        store.remove(id)
        XCTAssertTrue(store.entries.isEmpty)
        // Removing again is a no-op.
        store.remove(id)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_remove_does_not_delete_file() {
        // The library only forgets — the .epub stays on disk.
        let store = makeStore()
        let epub = makeEPUBStub(name: "book")
        store.recordConversion(epubURL: epub, title: "Book", languages: [])
        store.remove(store.entries[0].id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: epub.path),
            "remove must not delete the .epub file from disk")
    }

    // MARK: - collections

    func test_createCollection_appends_named_grouping() {
        let store = makeStore()
        let a = makeEPUBStub(name: "a")
        store.recordConversion(epubURL: a, title: "A", languages: [])
        let aID = store.entries[0].id
        let created = store.createCollection(
            name: "Foucault corpus", bookIDs: [aID]
        )
        XCTAssertEqual(store.collections.count, 1)
        XCTAssertEqual(store.collections[0].name, "Foucault corpus")
        XCTAssertEqual(store.collections[0].bookIDs, [aID])
        XCTAssertEqual(created.id, store.collections[0].id)
    }

    func test_createCollection_drops_ids_for_unknown_entries() {
        // Seeding membership with an id that isn't in `entries` is
        // a programmer error; silently drop rather than carry a
        // dangling reference.
        let store = makeStore()
        let phantom = UUID()
        store.createCollection(name: "Mystery", bookIDs: [phantom])
        XCTAssertEqual(store.collections[0].bookIDs, [])
    }

    func test_addToCollection_appends_without_duplicates() {
        let store = makeStore()
        let a = makeEPUBStub(name: "a")
        let b = makeEPUBStub(name: "b")
        store.recordConversion(epubURL: a, title: "A", languages: [])
        store.recordConversion(epubURL: b, title: "B", languages: [])
        let aID = store.entries[0].id
        let bID = store.entries[1].id
        let c = store.createCollection(name: "Pair")
        store.addToCollection(c.id, bookIDs: [aID])
        store.addToCollection(c.id, bookIDs: [aID, bID])
        XCTAssertEqual(store.collections[0].bookIDs, [aID, bID],
            "duplicate add must not double-list a book")
    }

    func test_removeFromCollection_drops_listed_ids() {
        let store = makeStore()
        let a = makeEPUBStub(name: "a")
        let b = makeEPUBStub(name: "b")
        store.recordConversion(epubURL: a, title: "A", languages: [])
        store.recordConversion(epubURL: b, title: "B", languages: [])
        let aID = store.entries[0].id
        let bID = store.entries[1].id
        let c = store.createCollection(name: "Pair", bookIDs: [aID, bID])
        store.removeFromCollection(c.id, bookIDs: [aID])
        XCTAssertEqual(store.collections[0].bookIDs, [bID])
    }

    func test_remove_drops_id_from_every_collection() {
        // Forgetting a book must scrub its id out of any
        // collection that referenced it — otherwise membership
        // lists carry dangling refs.
        let store = makeStore()
        let a = makeEPUBStub(name: "a")
        let b = makeEPUBStub(name: "b")
        store.recordConversion(epubURL: a, title: "A", languages: [])
        store.recordConversion(epubURL: b, title: "B", languages: [])
        let aID = store.entries[0].id
        let bID = store.entries[1].id
        let one = store.createCollection(name: "One", bookIDs: [aID, bID])
        let two = store.createCollection(name: "Two", bookIDs: [aID])
        store.remove(aID)
        let oneAfter = store.collections.first { $0.id == one.id }!
        let twoAfter = store.collections.first { $0.id == two.id }!
        XCTAssertEqual(oneAfter.bookIDs, [bID])
        XCTAssertEqual(twoAfter.bookIDs, [])
    }

    func test_renameCollection_updates_name_and_persists() {
        let store = makeStore()
        let c = store.createCollection(name: "Original")
        store.renameCollection(c.id, to: "New name")
        XCTAssertEqual(store.collections[0].name, "New name")
        let restarted = makeStore()
        XCTAssertEqual(restarted.collections[0].name, "New name")
    }

    func test_deleteCollection_removes_grouping_only() {
        let store = makeStore()
        let a = makeEPUBStub(name: "a")
        store.recordConversion(epubURL: a, title: "A", languages: [])
        let aID = store.entries[0].id
        let c = store.createCollection(name: "Doomed", bookIDs: [aID])
        store.deleteCollection(c.id)
        XCTAssertTrue(store.collections.isEmpty)
        XCTAssertEqual(store.entries.count, 1,
            "deleting a collection must not touch the library catalog")
    }

    func test_collections_round_trip_through_disk() {
        let store = makeStore()
        let a = makeEPUBStub(name: "a")
        store.recordConversion(epubURL: a, title: "A", languages: [])
        let aID = store.entries[0].id
        store.createCollection(name: "Persisted", bookIDs: [aID])

        let restarted = makeStore()
        XCTAssertEqual(restarted.collections.count, 1)
        XCTAssertEqual(restarted.collections[0].name, "Persisted")
        XCTAssertEqual(restarted.collections[0].bookIDs, [aID])
    }

    func test_legacy_bare_array_file_loads_with_no_collections() {
        // Pre-Collections library files are a bare `[LibraryEntry]`
        // array. Load must accept that shape and treat
        // `collections` as empty so existing users see no
        // disruption.
        let storeURL = tempDir.appendingPathComponent("library.json")
        let epub = makeEPUBStub(name: "legacy")
        let entry = LibraryEntry(
            epubURL: epub.canonicalForFile,
            title: "Legacy",
            languages: ["en"],
            addedAt: Date()
        )
        let data = try! JSONEncoder().encode([entry])
        try! data.write(to: storeURL)

        let store = LibraryStore(storeURL: storeURL)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].title, "Legacy")
        XCTAssertTrue(store.collections.isEmpty)
    }

    func test_load_prunes_membership_pointing_at_missing_files() {
        // A collection that references a book whose .epub vanished
        // on disk should lose that membership on next load — the
        // garbage-collection equivalent of `load`'s entry filter.
        let storeURL = tempDir.appendingPathComponent("library.json")
        let real = makeEPUBStub(name: "real")
        let phantom = tempDir.appendingPathComponent("phantom.epub")
        let realEntry = LibraryEntry(
            epubURL: real.canonicalForFile,
            title: "Real",
            languages: [],
            addedAt: Date()
        )
        let phantomEntry = LibraryEntry(
            epubURL: phantom,
            title: "Phantom",
            languages: [],
            addedAt: Date()
        )
        let collection = BookCollection(
            name: "Mixed",
            bookIDs: [realEntry.id, phantomEntry.id]
        )
        struct Payload: Codable {
            var entries: [LibraryEntry]
            var collections: [BookCollection]
        }
        let payload = Payload(
            entries: [realEntry, phantomEntry],
            collections: [collection]
        )
        let data = try! JSONEncoder().encode(payload)
        try! data.write(to: storeURL)

        let store = LibraryStore(storeURL: storeURL)
        XCTAssertEqual(store.entries.count, 1, "phantom should be pruned")
        XCTAssertEqual(store.collections.count, 1)
        XCTAssertEqual(store.collections[0].bookIDs, [realEntry.id],
            "phantom id must be scrubbed out of collection membership on load")
    }
}
