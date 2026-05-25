import XCTest
import Foundation
@testable import Humanist

/// Regression coverage for `EPUBImporter.destinationURL` — the
/// destination-resolution that decides where an imported EPUB
/// lands under the configured Books/ directory. The case that
/// regressed: "source file is ALREADY at the canonical
/// destination," which used to fall into the collision-suffix
/// loop and return `(2).epub`, leaving the original orphaned
/// as a duplicate. Most-visible via File → Update Library from
/// Output Folder over an output root that already contained
/// indexed EPUBs.
@MainActor
final class EPUBImporterDestinationURLTests: XCTestCase {

    private var tempRoot: URL!
    private var libraryStore: LibraryStore!
    private var savedOutputPath: Any?
    private let outputKey = "humanist.conversion.outputFolderPath"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EPUBImporterDestinationURLTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("Books"),
            withIntermediateDirectories: true
        )
        savedOutputPath = UserDefaults.standard.object(forKey: outputKey)
        UserDefaults.standard.set(tempRoot.path, forKey: outputKey)
        // Use an in-memory library — tests must not write to the
        // user's Application Support catalog.
        libraryStore = LibraryStore(
            storeURL: tempRoot.appendingPathComponent("library.json")
        )
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        if let savedOutputPath {
            UserDefaults.standard.set(savedOutputPath, forKey: outputKey)
        } else {
            UserDefaults.standard.removeObject(forKey: outputKey)
        }
        tempRoot = nil
        libraryStore = nil
        try await super.tearDown()
    }

    // MARK: - The regression case

    func test_destinationURL_returnsSourcePath_whenSourceAlreadyAtCanonicalDestination() throws {
        // Source file sits at <root>/Books/foo.epub — the canonical
        // destination basename. No catalog entry exists for it yet.
        // Without the fix, destinationURL would see "file exists at
        // base" and enter the collision-suffix loop, returning
        // <root>/Books/foo (2).epub and producing a duplicate when
        // the importer repacked.
        let source = tempRoot
            .appendingPathComponent("Books/foo.epub")
        try Data().write(to: source)

        let resolved = try EPUBImporter.destinationURL(
            for: source, library: libraryStore
        )

        XCTAssertEqual(
            resolved.canonicalForFile,
            source.canonicalForFile,
            "Source already at canonical destination should resolve to itself, not a (2) duplicate."
        )
    }

    // MARK: - Non-regression: the suffix loop still works when it
    // SHOULD fire (different file, same basename, neither cataloged)

    func test_destinationURL_returnsSuffixed_whenDifferentFileAtBaseAndSourceElsewhere() throws {
        // Existing file at the base destination (unrelated to the
        // source). Source lives elsewhere with the same basename.
        // The collision loop should still produce (2).
        let basePath = tempRoot
            .appendingPathComponent("Books/foo.epub")
        try Data().write(to: basePath)

        let elsewhere = tempRoot
            .appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(
            at: elsewhere, withIntermediateDirectories: true
        )
        let source = elsewhere.appendingPathComponent("foo.epub")
        try Data().write(to: source)

        let resolved = try EPUBImporter.destinationURL(
            for: source, library: libraryStore
        )

        XCTAssertEqual(
            resolved.lastPathComponent,
            "foo (2).epub",
            "Different-file collision should still fall into the suffix loop."
        )
    }

    // MARK: - Non-regression: idempotent re-import via catalog entry

    func test_destinationURL_returnsBase_whenCatalogAlreadyContainsBase() throws {
        // No file on disk at base, but the catalog already has an
        // entry pointing at base. This is the "re-import" idempotent
        // case — destinationURL returns base regardless of whether
        // source itself sits there.
        let base = tempRoot
            .appendingPathComponent("Books/foo.epub")
        libraryStore.recordConversion(
            epubURL: base,
            title: "Foo",
            languages: ["en"],
            conversionType: .digital
        )

        let elsewhere = tempRoot
            .appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(
            at: elsewhere, withIntermediateDirectories: true
        )
        let source = elsewhere.appendingPathComponent("foo.epub")
        try Data().write(to: source)

        let resolved = try EPUBImporter.destinationURL(
            for: source, library: libraryStore
        )

        XCTAssertEqual(
            resolved.canonicalForFile,
            base.canonicalForFile,
            "Existing catalog entry at base should win over a source-elsewhere collision check."
        )
    }
}
