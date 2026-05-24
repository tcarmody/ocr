import XCTest
import LibraryIndexing
import AI
import EPUB
@testable import Humanist

/// Coverage for `EPUBImporter.shouldSkipExistingImport` — the
/// short-circuit that turns "re-run a 1000-book batch after
/// interruption" from hours of redundant work into seconds of
/// FS checks.
///
/// All three guards must hold for a skip:
///   1. real file at destination,
///   2. catalog row pointing at it,
///   3. either no indexing backend OR a matching sidecar.
///
/// `@MainActor` because `LibraryStore` is.
@MainActor
final class EPUBImporterSkipTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBImporterSkipTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - helpers

    private func makeStore() -> LibraryStore {
        LibraryStore(storeURL: tempDir.appendingPathComponent("library.json"))
    }

    private func makeDestinationFile(name: String = "book") -> URL {
        let url = tempDir.appendingPathComponent(name + ".epub")
        try? Data([0x50, 0x4B]).write(to: url)  // PK header byte pretext
        return url
    }

    private func emptySidecarStore() -> EmbeddingsSidecarStore {
        EmbeddingsSidecarStore(
            baseDirectory: tempDir.appendingPathComponent("sidecars")
        )
    }

    // MARK: - tests

    func test_does_not_skip_when_destination_file_missing() async {
        let store = makeStore()
        let phantom = tempDir.appendingPathComponent("phantom.epub")
        // No file ever written at `phantom`.
        store.recordConversion(
            epubURL: phantom,
            title: "Phantom",
            languages: []
        )
        let skip = await EPUBImporter.shouldSkipExistingImport(
            destination: phantom,
            library: store,
            backend: nil,
            sidecarStore: emptySidecarStore()
        )
        XCTAssertFalse(skip)
    }

    func test_does_not_skip_when_catalog_row_missing() async {
        let store = makeStore()
        let dest = makeDestinationFile()
        // File on disk, but no catalog row.
        let skip = await EPUBImporter.shouldSkipExistingImport(
            destination: dest,
            library: store,
            backend: nil,
            sidecarStore: emptySidecarStore()
        )
        XCTAssertFalse(skip)
    }

    func test_skips_when_file_and_catalog_present_and_no_backend() async {
        // skip-indexing mode: catalog + file is enough.
        let store = makeStore()
        let dest = makeDestinationFile()
        store.recordConversion(
            epubURL: dest,
            title: "Book",
            languages: []
        )
        let skip = await EPUBImporter.shouldSkipExistingImport(
            destination: dest,
            library: store,
            backend: nil,
            sidecarStore: emptySidecarStore()
        )
        XCTAssertTrue(skip)
    }

    func test_does_not_skip_when_backend_requested_but_no_sidecar() async throws {
        // Indexing requested, no persisted sidecar — the importer
        // still needs to run so the embedding work happens.
        let store = makeStore()
        let dest = makeDestinationFile()
        store.recordConversion(epubURL: dest, title: "Book", languages: [])
        let backend = try XCTUnwrap(NLSentenceEmbeddingBackend())
        let skip = await EPUBImporter.shouldSkipExistingImport(
            destination: dest,
            library: store,
            backend: backend,
            sidecarStore: emptySidecarStore()
        )
        XCTAssertFalse(skip)
    }

    func test_skips_when_sidecar_matches_backend() async throws {
        // The full happy path: file + catalog + sidecar with
        // the right backend identifier + dimension.
        let store = makeStore()
        let dest = makeDestinationFile()
        store.recordConversion(epubURL: dest, title: "Book", languages: [])
        let backend = try XCTUnwrap(NLSentenceEmbeddingBackend())
        let sidecarStore = emptySidecarStore()
        var sidecar = EmbeddingsSidecar.empty(
            backend: backend.identifier,
            dimension: backend.dimension
        )
        sidecar.paragraphs = [
            EmbeddingsSidecar.Entry(
                chapterIdx: 0,
                paragraphIdx: 0,
                textHash: "h",
                vector: Array(repeating: Float(0.1), count: backend.dimension),
                text: "p"
            )
        ]
        sidecarStore.write(sidecar, for: dest)
        let skip = await EPUBImporter.shouldSkipExistingImport(
            destination: dest,
            library: store,
            backend: backend,
            sidecarStore: sidecarStore
        )
        XCTAssertTrue(skip)
    }

    func test_does_not_skip_when_sidecar_dimension_mismatched() async throws {
        // Sidecar present but built against a different backend.
        // Importer must re-run to refresh against the now-current
        // vector space.
        let store = makeStore()
        let dest = makeDestinationFile()
        store.recordConversion(epubURL: dest, title: "Book", languages: [])
        let backend = try XCTUnwrap(NLSentenceEmbeddingBackend())
        let sidecarStore = emptySidecarStore()
        var sidecar = EmbeddingsSidecar.empty(
            backend: "wrong-backend",
            dimension: backend.dimension + 1
        )
        sidecar.paragraphs = [
            EmbeddingsSidecar.Entry(
                chapterIdx: 0,
                paragraphIdx: 0,
                textHash: "h",
                vector: [Float(0.1)],
                text: "p"
            )
        ]
        sidecarStore.write(sidecar, for: dest)
        let skip = await EPUBImporter.shouldSkipExistingImport(
            destination: dest,
            library: store,
            backend: backend,
            sidecarStore: sidecarStore
        )
        XCTAssertFalse(skip)
    }

    func test_does_not_skip_when_sidecar_is_empty() async throws {
        // Sidecar exists at the right backend / dimension but
        // carries no paragraphs (the previous run was interrupted
        // before embedding). Treat as "needs work."
        let store = makeStore()
        let dest = makeDestinationFile()
        store.recordConversion(epubURL: dest, title: "Book", languages: [])
        let backend = try XCTUnwrap(NLSentenceEmbeddingBackend())
        let sidecarStore = emptySidecarStore()
        let sidecar = EmbeddingsSidecar.empty(
            backend: backend.identifier,
            dimension: backend.dimension
        )
        sidecarStore.write(sidecar, for: dest)
        let skip = await EPUBImporter.shouldSkipExistingImport(
            destination: dest,
            library: store,
            backend: backend,
            sidecarStore: sidecarStore
        )
        XCTAssertFalse(skip)
    }
}
