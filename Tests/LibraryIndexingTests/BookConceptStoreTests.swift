import XCTest
@testable import LibraryIndexing

/// `BookConceptStore` persistence layer. Tests cover the round-trip
/// (write → read), idempotent re-imports (hasPayload short-circuit),
/// missing-payload handling, and the Set-shaped accessor that
/// `BookEntityIndex.build` consumes.
final class BookConceptStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: BookConceptStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookConceptStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        store = BookConceptStore(baseDirectory: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Round trip

    func test_round_trip_preserves_concepts_timestamp_and_model_identifier() throws {
        let id = UUID()
        let payload = BookConceptStore.Payload(
            concepts: ["deconstruction", "speech act", "biopolitics"],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modelIdentifier: "afm-on-device-1"
        )
        try store.write(payload, libraryID: id)
        let read = store.read(libraryID: id)
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.concepts, payload.concepts)
        XCTAssertEqual(read?.generatedAt, payload.generatedAt)
        XCTAssertEqual(read?.modelIdentifier, payload.modelIdentifier)
        XCTAssertEqual(read?.schemaVersion, BookConceptStore.Payload.currentSchemaVersion)
    }

    func test_read_returns_nil_for_missing_payload() {
        XCTAssertNil(store.read(libraryID: UUID()))
    }

    func test_read_returns_nil_for_corrupt_payload() throws {
        let id = UUID()
        let fileURL = tempDir.appendingPathComponent("\(id.uuidString).json")
        try Data("not valid json {".utf8).write(to: fileURL)
        XCTAssertNil(store.read(libraryID: id),
            "unparseable payload should read as nil, not throw")
    }

    // MARK: - hasPayload

    func test_hasPayload_returns_false_for_missing_book() {
        XCTAssertFalse(store.hasPayload(libraryID: UUID()))
    }

    func test_hasPayload_returns_true_after_write() throws {
        let id = UUID()
        try store.write(
            BookConceptStore.Payload(
                concepts: ["one"], generatedAt: Date(),
                modelIdentifier: "afm-on-device-1"
            ),
            libraryID: id
        )
        XCTAssertTrue(store.hasPayload(libraryID: id),
            "post-write hasPayload should be true (cheap stat path the bulk-extract loop relies on)")
    }

    // MARK: - conceptTerms (Set accessor)

    func test_conceptTerms_returns_set_form() throws {
        let id = UUID()
        try store.write(
            BookConceptStore.Payload(
                concepts: ["deconstruction", "biopolitics", "deconstruction"],
                generatedAt: Date(),
                modelIdentifier: "afm-on-device-1"
            ),
            libraryID: id
        )
        let terms = store.conceptTerms(libraryID: id)
        XCTAssertEqual(terms, Set(["deconstruction", "biopolitics"]),
            "Set form should dedupe duplicate entries that slipped through canonicalization")
    }

    func test_conceptTerms_returns_empty_set_for_missing_book() {
        XCTAssertEqual(store.conceptTerms(libraryID: UUID()), [])
    }

    // MARK: - delete

    func test_delete_removes_the_payload() throws {
        let id = UUID()
        try store.write(
            BookConceptStore.Payload(
                concepts: ["one"], generatedAt: Date(),
                modelIdentifier: "afm-on-device-1"
            ),
            libraryID: id
        )
        XCTAssertTrue(store.hasPayload(libraryID: id))
        store.delete(libraryID: id)
        XCTAssertFalse(store.hasPayload(libraryID: id))
    }

    // MARK: - write creates the directory lazily

    func test_write_creates_directory_when_missing() throws {
        // Construct a store rooted at a path that doesn't exist yet.
        let nested = tempDir.appendingPathComponent("a/b/c/Concepts", isDirectory: true)
        let lazyStore = BookConceptStore(baseDirectory: nested)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path),
            "precondition: nested dir doesn't exist yet")
        let id = UUID()
        try lazyStore.write(
            BookConceptStore.Payload(
                concepts: ["one"], generatedAt: Date(),
                modelIdentifier: "afm-on-device-1"
            ),
            libraryID: id
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path),
            "write should mkdir -p the directory")
        XCTAssertTrue(lazyStore.hasPayload(libraryID: id))
    }
}
