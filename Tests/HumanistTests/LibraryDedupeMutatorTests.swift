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
}
