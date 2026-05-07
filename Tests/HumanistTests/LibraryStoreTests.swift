import XCTest
import Foundation
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
}
