import XCTest
import Foundation
import EPUB
import Pipeline
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
            AutoCollectionSource.byGenre(.philosophy),
            AutoCollectionSource.byGenre(.fictionFantasy),
            AutoCollectionSource.byGenre(.technologyComputing),
        ] {
            let data = try! JSONEncoder().encode(source)
            let back = try! JSONDecoder().decode(
                AutoCollectionSource.self, from: data
            )
            XCTAssertEqual(source, back)
        }
    }

    // MARK: - Phase 2: Genre

    /// Helper for genre tests: add entry with a stamped genre.
    private func addEntry(
        _ store: LibraryStore,
        title: String,
        genre: BookGenre,
        type: BookConversionType = .print
    ) {
        let url = makeEPUBStub(name: title)
        store.recordConversion(
            epubURL: url, title: title, languages: [],
            conversionType: type, genre: genre
        )
    }

    func test_refresh_creates_genre_collections_grouped_by_topLevel() {
        let store = makeStore()
        addEntry(store, title: "Iliad", genre: .poetry)
        addEntry(store, title: "Foucault", genre: .philosophy)
        addEntry(store, title: "Tolkien", genre: .fictionFantasy)
        addEntry(store, title: "Asimov", genre: .fictionScienceFiction)
        addEntry(store, title: "CLR", genre: .technologyComputing)
        addEntry(store, title: "Knuth", genre: .technologyComputing)

        let result = LibraryAutoCollections.refresh(library: store)
        XCTAssertEqual(result.genreCount, 5,
            "5 distinct genres present → 5 auto-genre collections")
        let genreColls = store.collections.filter {
            if case .byGenre = $0.autoSource { return true } else { return false }
        }
        let names = Set(genreColls.map(\.name))
        XCTAssertTrue(names.contains("Poetry"))
        XCTAssertTrue(names.contains("Philosophy"))
        XCTAssertTrue(names.contains("Fiction: Fantasy"))
        XCTAssertTrue(names.contains("Fiction: Science Fiction"))
        XCTAssertTrue(names.contains("Technology: Computing"))
    }

    func test_refresh_skips_uncategorized_genre() {
        let store = makeStore()
        addEntry(store, title: "A", genre: .uncategorized)
        addEntry(store, title: "B", genre: .philosophy)
        LibraryAutoCollections.refresh(library: store)
        let genreColls = store.collections.filter {
            if case .byGenre = $0.autoSource { return true } else { return false }
        }
        XCTAssertEqual(genreColls.count, 1,
            "uncategorized entries should not produce a collection")
        XCTAssertEqual(genreColls.first?.name, "Philosophy")
    }

    func test_refresh_sorts_genre_collections_by_topLevel_then_leaf() {
        // The sidebar reads a flat list but the order should
        // group same-topLevel together. Verify the sort order in
        // the resulting collections list.
        let store = makeStore()
        addEntry(store, title: "A", genre: .fictionMystery)
        addEntry(store, title: "B", genre: .sciencePhysics)
        addEntry(store, title: "C", genre: .fictionFantasy)
        addEntry(store, title: "D", genre: .scienceChemistry)

        LibraryAutoCollections.refresh(library: store)
        let names = store.collections
            .compactMap { c -> String? in
                if case .byGenre = c.autoSource { return c.name }
                return nil
            }
        // Fiction comes before Science alphabetically; within
        // each, sub-genres sort alphabetically by leaf name.
        XCTAssertEqual(names, [
            "Fiction: Fantasy",
            "Fiction: Mystery",
            "Science: Chemistry",
            "Science: Physics",
        ])
    }

    func test_setGenre_stamps_existing_entry() {
        let store = makeStore()
        let url = makeEPUBStub(name: "Untagged")
        store.recordConversion(epubURL: url, title: "Untagged", languages: [])
        let id = store.entries[0].id
        XCTAssertNil(store.entries[0].genre)
        store.setGenre(.philosophy, for: id)
        XCTAssertEqual(store.entries[0].genre, .philosophy)
    }

    // MARK: - Improved conversionType heuristic

    func test_inferConversionType_detects_sibling_PDF() {
        // EPUB + matching PDF in the same directory → .print
        let url = tempDir.appendingPathComponent("book.epub")
        try? Data().write(to: url)
        try? Data().write(to: tempDir.appendingPathComponent("book.pdf"))
        XCTAssertEqual(
            LibraryStore.inferConversionType(for: url),
            .print
        )
    }

    func test_inferConversionType_detects_PDF_at_outputRoot() {
        // EPUB at <root>/Books/foo.epub + PDF at <root>/foo.pdf
        // → .print. This is the layout actual Humanist libraries
        // end up with once an output folder is set.
        let root = tempDir.appendingPathComponent("Library")
        let books = root.appendingPathComponent("Books")
        try? FileManager.default.createDirectory(
            at: books, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(root.path,
            forKey: ConversionSettingsKeys.outputFolderPath)
        defer {
            UserDefaults.standard.removeObject(
                forKey: ConversionSettingsKeys.outputFolderPath
            )
        }

        let pdf = root.appendingPathComponent("foo.pdf")
        let epub = books.appendingPathComponent("foo.epub")
        try? Data().write(to: pdf)
        try? Data().write(to: epub)

        XCTAssertEqual(
            LibraryStore.inferConversionType(for: epub),
            .print,
            "should find PDF at root when EPUB is in Books/"
        )
    }

    func test_inferConversionType_handles_split_PDF_variant() {
        // EPUB basename has no .split, but the source PDF was
        // named foo.split.pdf (Humanist's split-PDF tool output).
        let root = tempDir.appendingPathComponent("Library")
        let books = root.appendingPathComponent("Books")
        try? FileManager.default.createDirectory(
            at: books, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(root.path,
            forKey: ConversionSettingsKeys.outputFolderPath)
        defer {
            UserDefaults.standard.removeObject(
                forKey: ConversionSettingsKeys.outputFolderPath
            )
        }

        let splitPDF = root.appendingPathComponent("foo.split.pdf")
        let epub = books.appendingPathComponent("foo.epub")
        try? Data().write(to: splitPDF)
        try? Data().write(to: epub)

        XCTAssertEqual(
            LibraryStore.inferConversionType(for: epub),
            .print,
            "should recognize the .split.pdf source-PDF variant"
        )
    }

    func test_inferConversionType_falls_back_to_digital_when_no_PDF() {
        let root = tempDir.appendingPathComponent("Library")
        let books = root.appendingPathComponent("Books")
        try? FileManager.default.createDirectory(
            at: books, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(root.path,
            forKey: ConversionSettingsKeys.outputFolderPath)
        defer {
            UserDefaults.standard.removeObject(
                forKey: ConversionSettingsKeys.outputFolderPath
            )
        }
        let epub = books.appendingPathComponent("foo.epub")
        try? Data().write(to: epub)
        XCTAssertEqual(
            LibraryStore.inferConversionType(for: epub),
            .digital
        )
    }

    // MARK: - backfillMetadata mutator

    func test_backfillMetadata_only_writes_nonnil_changed_fields() {
        let store = makeStore()
        addEntry(store, title: "Old", type: .print)
        let id = store.entries[0].id

        // nil author → no change
        let changed1 = store.backfillMetadata(for: id, author: nil)
        XCTAssertFalse(changed1)
        XCTAssertNil(store.entries[0].author)

        // setting author → change
        let changed2 = store.backfillMetadata(for: id, author: "Foucault")
        XCTAssertTrue(changed2)
        XCTAssertEqual(store.entries[0].author, "Foucault")

        // re-setting same author → no change
        let changed3 = store.backfillMetadata(for: id, author: "Foucault")
        XCTAssertFalse(changed3)
    }

    func test_backfillMetadata_preserves_existing_author_against_overwrite() {
        // If an entry already has an author stamp, backfill
        // doesn't replace it — the user might have edited or the
        // earlier stamp came from a more authoritative source.
        let store = makeStore()
        addEntry(store, title: "X", author: "Original", type: .print)
        let id = store.entries[0].id
        let changed = store.backfillMetadata(for: id, author: "Different")
        XCTAssertFalse(changed)
        XCTAssertEqual(store.entries[0].author, "Original")
    }

    func test_backfillMetadata_updates_conversionType_when_provided() {
        let store = makeStore()
        addEntry(store, title: "X", type: .digital)
        let id = store.entries[0].id
        let changed = store.backfillMetadata(for: id, conversionType: .print)
        XCTAssertTrue(changed)
        XCTAssertEqual(store.entries[0].conversionType, .print)
    }

    func test_LibraryEntry_decodes_legacy_JSON_without_genre() {
        // Pre-Phase-2 JSON has no `genre` key. decodeIfPresent
        // should leave it nil so existing libraries open clean.
        let entry = LibraryEntry(
            epubURL: tempDir.appendingPathComponent("legacy.epub"),
            title: "Legacy", languages: [], addedAt: Date()
        )
        let data = try! JSONEncoder().encode([entry])
        // Strip the genre key.
        var json = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        json[0].removeValue(forKey: "genre")
        let stripped = try! JSONSerialization.data(withJSONObject: json)
        let decoded = try! JSONDecoder().decode([LibraryEntry].self, from: stripped)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].genre)
    }
}
