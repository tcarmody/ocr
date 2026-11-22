import XCTest
import Foundation
@testable import Humanist

/// A catalog that's still a dataless iCloud placeholder must not
/// block launch, must never be overwritten before it's been read,
/// and must keep changes made while it downloads.
@MainActor
final class LibraryStoreDeferredLoadTests: XCTestCase {

    private var tempDir: URL!
    private var catalogURL: URL { tempDir.appendingPathComponent("library.json") }

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("humanist-deferred-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    private func makeEPUBStub(_ name: String) -> URL {
        let url = tempDir.appendingPathComponent(name + ".epub")
        try? Data().write(to: url)
        return url
    }

    /// Write a one-book catalog through an ordinary store.
    private func seedCatalog() {
        let seed = LibraryStore(storeURL: catalogURL)
        seed.recordConversion(
            epubURL: makeEPUBStub("in-cloud"), title: "In the Cloud", languages: ["en"]
        )
    }

    private func entryTitlesOnDisk() throws -> [String] {
        let data = try Data(contentsOf: catalogURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = json?["entries"] as? [[String: Any]] ?? []
        return entries.compactMap { $0["title"] as? String }.sorted()
    }

    func test_dataless_catalog_loads_in_background_and_merges_changes() async throws {
        seedCatalog()
        let gate = DispatchSemaphore(value: 0)
        let store = LibraryStore(
            storeURL: catalogURL,
            isDataless: { _ in true },
            readData: { url in
                gate.wait()  // the provider hasn't delivered the bytes yet
                return try? Data(contentsOf: url)
            }
        )

        // Init returned without reading — launch isn't blocked.
        XCTAssertEqual(store.loadState, .waitingForCloud)
        XCTAssertTrue(store.entries.isEmpty)

        // A conversion finishing while we wait is kept in memory but
        // not written over the cloud catalog.
        store.recordConversion(
            epubURL: makeEPUBStub("added-meanwhile"), title: "Added Meanwhile", languages: ["en"]
        )
        XCTAssertEqual(try entryTitlesOnDisk(), ["In the Cloud"])

        gate.signal()
        await store.deferredLoad?.value

        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertEqual(store.entries.map(\.title).sorted(), ["Added Meanwhile", "In the Cloud"])
        XCTAssertEqual(try entryTitlesOnDisk(), ["Added Meanwhile", "In the Cloud"])
    }

    func test_unreadable_catalog_is_never_overwritten() async throws {
        seedCatalog()
        let before = try Data(contentsOf: catalogURL)
        let store = LibraryStore(
            storeURL: catalogURL,
            isDataless: { _ in true },
            readData: { _ in nil }
        )
        await store.deferredLoad?.value

        XCTAssertEqual(store.loadState, .unreadable)
        store.recordConversion(
            epubURL: makeEPUBStub("would-clobber"), title: "Would Clobber", languages: ["en"]
        )
        XCTAssertEqual(try Data(contentsOf: catalogURL), before)
    }

    func test_missing_catalog_after_wait_starts_empty_and_saves() async throws {
        let store = LibraryStore(
            storeURL: catalogURL,
            isDataless: { _ in true },
            readData: { _ in nil }
        )
        await store.deferredLoad?.value

        XCTAssertEqual(store.loadState, .loaded)
        store.recordConversion(
            epubURL: makeEPUBStub("first"), title: "First Book", languages: ["en"]
        )
        XCTAssertEqual(try entryTitlesOnDisk(), ["First Book"])
    }

    func test_local_catalog_still_loads_synchronously() {
        seedCatalog()
        let store = LibraryStore(storeURL: catalogURL)
        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertNil(store.deferredLoad)
        XCTAssertEqual(store.entries.map(\.title), ["In the Cloud"])
    }

    func test_isDataless_is_false_for_a_local_file() {
        seedCatalog()
        XCTAssertFalse(LibraryStore.isDataless(catalogURL))
        XCTAssertFalse(LibraryStore.isDataless(tempDir.appendingPathComponent("missing.json")))
    }
}
