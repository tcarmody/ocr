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
        XCTAssertEqual(result.stampedFromPDF, 1,
            "source PDF was on disk — should hash via the PDF path")
        XCTAssertEqual(result.stampedFromEPUB, 0)
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

    func test_falls_back_to_epub_hash_when_no_source_pdf() async throws {
        // No source PDF — the canonical EPUB-import case. Backfill
        // should hash the catalog EPUB itself so re-imports of the
        // same bytes dedupe across Macs sharing the library.
        let layout = try setUpCanonicalLayout(
            bookBasename: "import-only",
            pdfContent: "irrelevant"
        )
        try FileManager.default.removeItem(at: layout.pdf)
        // Replace the empty EPUB stub with real bytes so the hash
        // is meaningful + reproducible.
        let epubBytes = "imagine this is a real EPUB archive"
        try Data(epubBytes.utf8).write(to: layout.epub)

        let store = makeStore()
        store.recordConversion(
            epubURL: layout.epub, title: "Import Only", languages: ["en"]
        )

        let result = await SourceHashBackfill.runIfNeeded(library: store)
        XCTAssertEqual(result.stampedFromPDF, 0)
        XCTAssertEqual(result.stampedFromEPUB, 1,
            "no PDF — should fall back to hashing the catalog EPUB")
        XCTAssertEqual(result.hashFailed, 0)

        let expected = try ContentHash.sha256(of: layout.epub)
        XCTAssertEqual(store.entries[0].sourceContentHashes.first, expected,
            "stamped hash should match the EPUB bytes — needed for re-import dedupe")
    }

    func test_pdf_path_preferred_over_epub_when_both_available() async throws {
        // Defends the preference order: even though we could hash
        // the EPUB, hashing the PDF gives the auto-scanner the
        // signal it actually consults when a PDF re-lands in Input/.
        let layout = try setUpCanonicalLayout(
            bookBasename: "prefer-pdf",
            pdfContent: "this is the pdf source"
        )
        try Data("this is the converted epub".utf8).write(to: layout.epub)
        let store = makeStore()
        store.recordConversion(
            epubURL: layout.epub, title: "Prefer PDF", languages: ["en"]
        )
        let result = await SourceHashBackfill.runIfNeeded(library: store)
        XCTAssertEqual(result.stampedFromPDF, 1)
        XCTAssertEqual(result.stampedFromEPUB, 0)
        let pdfHash = try ContentHash.sha256(of: layout.pdf)
        XCTAssertEqual(store.entries[0].sourceContentHashes.first, pdfHash,
            "PDF hash wins — that's what auto-scan compares re-drops against")
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

    func test_epub_re_import_dedupes_after_backfill() async throws {
        // The reason the EPUB-fallback exists: a peer Mac re-drops
        // the same EPUB bytes (different filename / path) and the
        // importer's dedupe path should fire instead of writing
        // a second catalog row. We stand in for the importer here
        // by hashing the EPUB ourselves and checking the
        // isSourceHashKnownOrRejected query — same surface area.
        let root = tempDir.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        UserDefaults.standard.set(
            root.path, forKey: ConversionSettingsKeys.outputFolderPath
        )
        let epub = root.appendingPathComponent("Books/imported.epub")
        try FileManager.default.createDirectory(
            at: epub.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("real epub bytes".utf8).write(to: epub)

        let store = makeStore()
        store.recordConversion(
            epubURL: epub, title: "Imported", languages: ["en"]
        )
        _ = await SourceHashBackfill.runIfNeeded(library: store)

        // Same bytes, "different" file the user might re-drop:
        let reDropPath = tempDir.appendingPathComponent("downloads/imported-renamed.epub")
        try FileManager.default.createDirectory(
            at: reDropPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("real epub bytes".utf8).write(to: reDropPath)
        let reDropHash = try ContentHash.sha256(of: reDropPath)
        XCTAssertTrue(store.isSourceHashKnownOrRejected(reDropHash),
            "EPUB-fallback hash should be byte-identical, so a re-import dedupes")
    }
}
