import XCTest
import Foundation
@testable import Humanist

/// Coverage for `SourceHashBackfill` — the launch-time pass that
/// stamps `sourceContentHashes` on pre-R-Library-Dedupe entries.
/// Touches the real `ContentHash.sha256` (no mock) since the
/// backfill's whole job is "hash these specific files," and uses
/// temp PDFs the test controls.
@MainActor
final class SourceHashBackfillTests: XCTestCase {

    private var tempDir: URL!
    private var savedOutputRoot: String?

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        savedOutputRoot = UserDefaults.standard.string(
            forKey: ConversionSettingsKeys.outputFolderPath
        )
    }

    override func tearDown() async throws {
        if let saved = savedOutputRoot {
            UserDefaults.standard.set(
                saved, forKey: ConversionSettingsKeys.outputFolderPath
            )
        } else {
            UserDefaults.standard.removeObject(
                forKey: ConversionSettingsKeys.outputFolderPath
            )
        }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    private func makeStore() -> LibraryStore {
        LibraryStore(storeURL: tempDir.appendingPathComponent("library.json"))
    }

    private func writePDF(at url: URL, bytes: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(bytes.utf8).write(to: url)
    }

    /// Configure the output root + canonical Books/ subdir so
    /// `LibraryStore.locateSourcePDF` can find the sibling PDF.
    private func setUpCanonicalLayout(
        bookBasename: String,
        pdfContent: String
    ) throws -> (root: URL, epub: URL, pdf: URL) {
        let root = tempDir.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(
            root.path, forKey: ConversionSettingsKeys.outputFolderPath
        )
        let pdf = root.appendingPathComponent("\(bookBasename).pdf")
        try writePDF(at: pdf, bytes: pdfContent)
        let epub = root.appendingPathComponent("Books/\(bookBasename).epub")
        try FileManager.default.createDirectory(
            at: epub.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: epub)
        return (root, epub, pdf)
    }

    // MARK: - locateSourcePDF probe sites

    func test_locateSourcePDF_finds_sibling_pdf() throws {
        let epub = tempDir.appendingPathComponent("foo.epub")
        try Data().write(to: epub)
        let pdf = tempDir.appendingPathComponent("foo.pdf")
        try writePDF(at: pdf, bytes: "x")
        let found = LibraryStore.locateSourcePDF(for: epub)
        XCTAssertEqual(found?.path, pdf.path)
    }

    func test_locateSourcePDF_finds_pdf_at_output_root() throws {
        let layout = try setUpCanonicalLayout(
            bookBasename: "alpha", pdfContent: "alpha bytes"
        )
        let found = LibraryStore.locateSourcePDF(for: layout.epub)
        XCTAssertEqual(found?.path, layout.pdf.path)
    }

    func test_locateSourcePDF_collapses_split_suffix() throws {
        // EPUB has `.split` in its basename; PDF without `.split`
        // is the actual source.
        let root = tempDir.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(
            root.path, forKey: ConversionSettingsKeys.outputFolderPath
        )
        let pdf = root.appendingPathComponent("Foo.pdf")
        try writePDF(at: pdf, bytes: "y")
        let epub = root.appendingPathComponent("Books/Foo.split.epub")
        try FileManager.default.createDirectory(
            at: epub.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: epub)
        let found = LibraryStore.locateSourcePDF(for: epub)
        XCTAssertEqual(found?.path, pdf.path)
    }

    func test_locateSourcePDF_finds_pdf_in_input_folder() throws {
        let root = tempDir.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(
            root.path, forKey: ConversionSettingsKeys.outputFolderPath
        )
        let pdf = root
            .appendingPathComponent("Input")
            .appendingPathComponent("Beta.pdf")
        try writePDF(at: pdf, bytes: "z")
        let epub = root.appendingPathComponent("Books/Beta.epub")
        try FileManager.default.createDirectory(
            at: epub.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: epub)
        let found = LibraryStore.locateSourcePDF(for: epub)
        XCTAssertEqual(found?.path, pdf.path)
    }

    func test_locateSourcePDF_returns_nil_when_no_source_found() throws {
        let layout = try setUpCanonicalLayout(
            bookBasename: "ghost", pdfContent: "x"
        )
        try FileManager.default.removeItem(at: layout.pdf)
        let found = LibraryStore.locateSourcePDF(for: layout.epub)
        XCTAssertNil(found)
    }

    // MARK: - Backfill behavior

    func test_stamps_hash_on_entry_with_locatable_source() async throws {
        let layout = try setUpCanonicalLayout(
            bookBasename: "stamp-me",
            pdfContent: "deterministic source bytes"
        )
        let store = makeStore()
        store.recordConversion(
            epubURL: layout.epub, title: "Stamp Me", languages: ["en"]
        )
        XCTAssertEqual(store.entries[0].sourceContentHashes, [])

        let result = await SourceHashBackfill.runIfNeeded(library: store)
        XCTAssertEqual(result.stamped, 1)
        XCTAssertEqual(result.hashFailed, 0)
        XCTAssertEqual(store.entries[0].sourceContentHashes.count, 1)

        // Hash must match what ContentHash.sha256 produces directly —
        // we want byte-for-byte parity with the scanner's runtime hash.
        let expected = try ContentHash.sha256(of: layout.pdf)
        XCTAssertEqual(store.entries[0].sourceContentHashes.first, expected)
    }

    func test_skips_entries_that_already_have_a_hash() async throws {
        let layout = try setUpCanonicalLayout(
            bookBasename: "already",
            pdfContent: "real bytes"
        )
        let store = makeStore()
        store.recordConversion(
            epubURL: layout.epub, title: "Already", languages: ["en"]
        )
        let id = store.entries[0].id
        // Pretend an earlier conversion stamped this hash. The
        // backfill must not overwrite it (no re-hash work).
        store.recordSourceHash("pretend-existing-hash", on: id)

        let result = await SourceHashBackfill.runIfNeeded(library: store)
        XCTAssertEqual(result.stamped, 0)
        XCTAssertEqual(result.alreadyStamped, 1)
        // The pre-existing hash is preserved; no extra hash appended.
        XCTAssertEqual(
            store.entries[0].sourceContentHashes, ["pretend-existing-hash"]
        )
    }

    func test_counts_source_missing_entries_without_stamping() async throws {
        // Entry exists but no source PDF on disk — the layout
        // sets one up, then we delete the PDF.
        let layout = try setUpCanonicalLayout(
            bookBasename: "missing",
            pdfContent: "x"
        )
        try FileManager.default.removeItem(at: layout.pdf)
        let store = makeStore()
        store.recordConversion(
            epubURL: layout.epub, title: "Missing", languages: ["en"]
        )

        let result = await SourceHashBackfill.runIfNeeded(library: store)
        XCTAssertEqual(result.stamped, 0)
        XCTAssertEqual(result.sourceMissing, 1)
        XCTAssertEqual(result.hashFailed, 0)
        XCTAssertEqual(store.entries[0].sourceContentHashes, [])
    }

    func test_handles_multiple_entries_in_one_pass() async throws {
        // Three entries, distinct source bytes. All should stamp in
        // a single backfill pass — exercises the bulk-save path.
        let root = tempDir.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(
            root.path, forKey: ConversionSettingsKeys.outputFolderPath
        )
        let store = makeStore()
        var hashes: [String: String] = [:]   // basename → expected hash
        for name in ["a", "b", "c"] {
            let pdf = root.appendingPathComponent("\(name).pdf")
            try writePDF(at: pdf, bytes: "content for \(name)")
            let epub = root.appendingPathComponent("Books/\(name).epub")
            try FileManager.default.createDirectory(
                at: epub.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: epub)
            store.recordConversion(
                epubURL: epub, title: name, languages: ["en"]
            )
            hashes[name] = try ContentHash.sha256(of: pdf)
        }

        let result = await SourceHashBackfill.runIfNeeded(library: store)
        XCTAssertEqual(result.stamped, 3)
        for entry in store.entries {
            let key = entry.epubURL.deletingPathExtension().lastPathComponent
            XCTAssertEqual(entry.sourceContentHashes, [hashes[key]!],
                "entry for \(key) should have the matching hash")
        }
    }

    func test_idempotent_second_run_is_a_noop() async throws {
        let layout = try setUpCanonicalLayout(
            bookBasename: "idemp", pdfContent: "y"
        )
        let store = makeStore()
        store.recordConversion(
            epubURL: layout.epub, title: "Idemp", languages: ["en"]
        )

        let first = await SourceHashBackfill.runIfNeeded(library: store)
        XCTAssertEqual(first.stamped, 1)

        let second = await SourceHashBackfill.runIfNeeded(library: store)
        XCTAssertEqual(second.stamped, 0)
        XCTAssertEqual(second.alreadyStamped, 1)
    }

    func test_after_backfill_dedupe_query_recognizes_source() async throws {
        // End-to-end: the whole point of the backfill is that the
        // scanner's `isSourceHashKnownOrRejected` returns true after
        // it runs. Verify that loop.
        let layout = try setUpCanonicalLayout(
            bookBasename: "dedupe-check", pdfContent: "abc"
        )
        let store = makeStore()
        store.recordConversion(
            epubURL: layout.epub, title: "Dedupe Check", languages: ["en"]
        )

        let hash = try ContentHash.sha256(of: layout.pdf)
        XCTAssertFalse(store.isSourceHashKnownOrRejected(hash),
            "pre-backfill: scanner can't see this source")

        _ = await SourceHashBackfill.runIfNeeded(library: store)

        XCTAssertTrue(store.isSourceHashKnownOrRejected(hash),
            "post-backfill: scanner skips this source on next pass")
    }
}
