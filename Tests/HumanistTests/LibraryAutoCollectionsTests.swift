import XCTest
import Foundation
import EPUB
@testable import Humanist

/// R-Auto-Collections Phase 1: `LibraryAutoCollections.refresh`
/// materializes Type + Author collections from `LibraryEntry`
/// metadata. Tests verify:
///
///   * Type buckets honor each `conversionType` and skip empty
///     enum cases.
///   * Author buckets honor the configurable threshold.
///   * Refresh is idempotent — re-running on a stable catalog
///     produces collections with identical ids/membership so
///     SwiftUI selection state doesn't bounce.
///   * User-created collections survive refresh untouched.
///   * Toggling threshold reshapes Author collections on next
///     refresh.
@MainActor
final class LibraryAutoCollectionsTests: XCTestCase {

    private var tempDir: URL!
    private var savedThreshold: Int?

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCollections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        savedThreshold = UserDefaults.standard.object(
            forKey: ConversionSettingsKeys.autoAuthorThreshold
        ) as? Int
        UserDefaults.standard.removeObject(
            forKey: ConversionSettingsKeys.autoAuthorThreshold
        )
    }

    override func tearDown() async throws {
        if let saved = savedThreshold {
            UserDefaults.standard.set(saved,
                forKey: ConversionSettingsKeys.autoAuthorThreshold)
        } else {
            UserDefaults.standard.removeObject(
                forKey: ConversionSettingsKeys.autoAuthorThreshold
            )
        }
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

    private func addEntry(
        _ store: LibraryStore,
        title: String,
        author: String? = nil,
        type: BookConversionType
    ) {
        let url = makeEPUBStub(name: title)
        store.recordConversion(
            epubURL: url,
            title: title,
            languages: ["en"],
            conversionType: type,
            author: author
        )
    }

    // MARK: - Type collections

    func test_refresh_creates_one_collection_per_present_type() {
        let store = makeStore()
        addEntry(store, title: "A", type: .print)
        addEntry(store, title: "B", type: .print)
        addEntry(store, title: "C", type: .manuscript)
        addEntry(store, title: "D", type: .digital)

        let result = LibraryAutoCollections.refresh(library: store)
        XCTAssertEqual(result.typeCount, 3,
            "print + manuscript + digital → 3 type collections")
        let typeColls = store.collections.filter {
            if case .byType = $0.autoSource { return true } else { return false }
        }
        let typeNames = Set(typeColls.map(\.name))
        XCTAssertTrue(typeNames.contains("Print"))
        XCTAssertTrue(typeNames.contains("Manuscript"))
        XCTAssertTrue(typeNames.contains("Digital"))
        XCTAssertFalse(typeNames.contains("Early Print"),
            "no Early Print entries → no Early Print collection")
    }

    func test_refresh_skips_entries_without_conversionType() {
        // Entries with nil conversionType (no backfill match) are
        // simply excluded from Type collections — they still
        // appear in All Books.
        let store = makeStore()
        addEntry(store, title: "A", type: .print)
        // Add an unstamped row by recordConversion without type.
        let url = makeEPUBStub(name: "Untyped")
        store.recordConversion(epubURL: url, title: "Untyped", languages: [])

        LibraryAutoCollections.refresh(library: store)
        let printColl = store.collections.first { $0.name == "Print" }
        XCTAssertEqual(printColl?.bookIDs.count, 1,
            "Print collection contains only the stamped entry")
    }

    // MARK: - Author collections + threshold

    func test_refresh_respects_default_threshold_of_3() {
        let store = makeStore()
        addEntry(store, title: "F1", author: "Foucault", type: .print)
        addEntry(store, title: "F2", author: "Foucault", type: .print)
        addEntry(store, title: "F3", author: "Foucault", type: .print)
        addEntry(store, title: "D1", author: "Deleuze", type: .print)
        addEntry(store, title: "D2", author: "Deleuze", type: .print)

        let result = LibraryAutoCollections.refresh(library: store)
        XCTAssertEqual(result.authorThreshold, 3)
        let authorColls = store.collections.filter {
            if case .byAuthor = $0.autoSource { return true } else { return false }
        }
        let names = Set(authorColls.map(\.name))
        XCTAssertTrue(names.contains("Foucault"),
            "Foucault (3 books) meets the 3-book threshold")
        XCTAssertFalse(names.contains("Deleuze"),
            "Deleuze (2 books) falls below the threshold")
    }

    func test_refresh_honors_configured_threshold() {
        UserDefaults.standard.set(5,
            forKey: ConversionSettingsKeys.autoAuthorThreshold)
        let store = makeStore()
        for i in 1...4 {
            addEntry(store, title: "F\(i)", author: "Foucault", type: .print)
        }
        let result = LibraryAutoCollections.refresh(library: store)
        XCTAssertEqual(result.authorThreshold, 5)
        let authorColls = store.collections.filter {
            if case .byAuthor = $0.autoSource { return true } else { return false }
        }
        XCTAssertEqual(authorColls.count, 0,
            "Foucault has 4 books; threshold is 5 — no auto-author collections")
    }

    func test_refresh_excludes_empty_author_strings() {
        // Empty / whitespace-only author should not aggregate
        // into a "(empty)" pseudo-collection.
        let store = makeStore()
        for i in 1...5 {
            addEntry(store, title: "B\(i)", author: "   ", type: .print)
        }
        LibraryAutoCollections.refresh(library: store)
        let authorColls = store.collections.filter {
            if case .byAuthor = $0.autoSource { return true } else { return false }
        }
        XCTAssertTrue(authorColls.isEmpty,
            "whitespace-only authors should not produce collections")
    }

    // MARK: - Idempotence + preservation

    func test_refresh_preserves_user_collections() {
        let store = makeStore()
        addEntry(store, title: "A", type: .print)
        addEntry(store, title: "B", type: .manuscript)
        let mine = store.createCollection(name: "Hand-curated")
        let mineID = mine.id

        LibraryAutoCollections.refresh(library: store)

        let userColls = store.collections.filter { $0.autoSource == nil }
        XCTAssertEqual(userColls.count, 1)
        XCTAssertEqual(userColls.first?.id, mineID,
            "user-created collection id must survive refresh")
    }

    func test_second_refresh_preserves_auto_collection_ids() {
        // SwiftUI sidebar selection is keyed by collection.id.
        // A refresh that produces identical buckets should reuse
        // the same ids so the user's active selection doesn't
        // bounce.
        let store = makeStore()
        addEntry(store, title: "A", type: .print)
        addEntry(store, title: "B", type: .print)
        for i in 1...3 {
            addEntry(store, title: "F\(i)", author: "Foucault", type: .print)
        }
        LibraryAutoCollections.refresh(library: store)
        let firstIDs = store.collections
            .filter { $0.autoSource != nil }
            .map(\.id)

        LibraryAutoCollections.refresh(library: store)
        let secondIDs = store.collections
            .filter { $0.autoSource != nil }
            .map(\.id)
        XCTAssertEqual(Set(firstIDs), Set(secondIDs),
            "auto-collection ids must be stable across refreshes")
    }

    func test_refresh_drops_collections_whose_source_no_longer_exists() {
        // Entries that vanish (book removed) should also remove
        // any auto-collection that only existed because of them.
        let store = makeStore()
        for i in 1...3 {
            addEntry(store, title: "F\(i)", author: "Foucault", type: .print)
        }
        LibraryAutoCollections.refresh(library: store)
        XCTAssertEqual(
            store.collections.filter { $0.autoSource != nil }.count, 2,
            "Print type + Foucault author = 2 auto-collections"
        )

        // Remove all of Foucault's books.
        for entry in store.entries { store.remove(entry.id) }
        LibraryAutoCollections.refresh(library: store)
        XCTAssertTrue(
            store.collections.filter { $0.autoSource != nil }.isEmpty,
            "no books → no auto-collections"
        )
    }

    // MARK: - Codable

    func test_BookCollection_decodes_legacy_without_autoSource() {
        // Pre-Phase-1 collections have no autoSource key. Verify
        // decodeIfPresent leaves the field nil.
        struct LegacyPayload: Encodable {
            let id: UUID
            let name: String
            let bookIDs: [UUID]
            let createdAt: Date
        }
        let legacy = LegacyPayload(
            id: UUID(),
            name: "Legacy",
            bookIDs: [],
            createdAt: Date()
        )
        let data = try! JSONEncoder().encode(legacy)
        let decoded = try! JSONDecoder().decode(BookCollection.self, from: data)
        XCTAssertNil(decoded.autoSource)
        XCTAssertEqual(decoded.name, "Legacy")
    }

    func test_AutoCollectionSource_round_trips_through_JSON() {
        for source in [
            AutoCollectionSource.byType(.manuscript),
            AutoCollectionSource.byAuthor("Foucault"),
        ] {
            let data = try! JSONEncoder().encode(source)
            let back = try! JSONDecoder().decode(
                AutoCollectionSource.self, from: data
            )
            XCTAssertEqual(source, back)
        }
    }
}
