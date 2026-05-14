import XCTest
import Foundation
@testable import Humanist

/// R-Library-Export — coverage for the filename composer
/// (`Author - Title.epub`, fallback to `Title.epub`, sanitization,
/// byte clamp) plus the end-to-end copy / skip-if-exists / failure
/// path against synthetic EPUB stubs in a temp directory.
@MainActor
final class LibraryExporterTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-exporter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - filename composition

    func test_exportBaseName_joins_author_and_title() {
        XCTAssertEqual(
            LibraryExporter.exportBaseName(
                author: "Gilles Deleuze",
                title: "Anti-Oedipus"
            ),
            "Gilles Deleuze - Anti-Oedipus"
        )
    }

    func test_exportBaseName_falls_back_to_title_when_no_author() {
        XCTAssertEqual(
            LibraryExporter.exportBaseName(author: nil, title: "Anti-Oedipus"),
            "Anti-Oedipus"
        )
        XCTAssertEqual(
            LibraryExporter.exportBaseName(author: "", title: "Anti-Oedipus"),
            "Anti-Oedipus"
        )
        // Whitespace-only author counts as missing.
        XCTAssertEqual(
            LibraryExporter.exportBaseName(
                author: "   ", title: "Anti-Oedipus"
            ),
            "Anti-Oedipus"
        )
    }

    func test_exportBaseName_replaces_path_separators() {
        // `/` is APFS-fatal; `:` is the historical HFS path separator
        // and trips the Finder; `\` is convention-fatal on imports.
        // All three must collapse to a safe substitute (`-`).
        XCTAssertEqual(
            LibraryExporter.exportBaseName(
                author: "A/B Author",
                title: "Foo: Bar / Baz"
            ),
            "A-B Author - Foo- Bar - Baz"
        )
    }

    func test_exportBaseName_strips_control_characters() {
        // Embedded `\n` + NUL come up when titles carry pasted-in
        // newlines or stray control chars from PDF metadata.
        XCTAssertEqual(
            LibraryExporter.exportBaseName(
                author: "Lacan\u{0000}",
                title: "Écrits\nComplets"
            ),
            "Lacan - ÉcritsComplets"
        )
    }

    func test_exportBaseName_trims_leading_and_trailing_dots() {
        // A filename starting with `.` reads as hidden on macOS;
        // trailing dot makes it look extensionless. Sanitizer strips
        // both edges.
        XCTAssertEqual(
            LibraryExporter.exportBaseName(author: ".A.", title: ".Title."),
            "A - Title"
        )
    }

    func test_exportBaseName_uses_untitled_when_title_empty() {
        // A wholly-empty title (or one that sanitizes to empty) gets
        // the literal "Untitled" so we never produce a `.epub` with
        // no base name.
        XCTAssertEqual(
            LibraryExporter.exportBaseName(author: "Author", title: ""),
            "Author - Untitled"
        )
        XCTAssertEqual(
            LibraryExporter.exportBaseName(author: nil, title: "..."),
            "Untitled"
        )
    }

    func test_clampBytes_respects_utf8_byte_budget() {
        // Long ASCII string trimmed in place.
        let ascii = String(repeating: "x", count: 300)
        let clamped = LibraryExporter.clampBytes(ascii, maxBytes: 100)
        XCTAssertEqual(clamped.count, 100)

        // Multi-byte: each "é" is 2 UTF-8 bytes; we must not break
        // mid-scalar.
        let multibyte = String(repeating: "é", count: 60) // 120 bytes
        let clampedMB = LibraryExporter.clampBytes(multibyte, maxBytes: 50)
        XCTAssertLessThanOrEqual(clampedMB.utf8.count, 50)
        // No replacement chars (would imply mid-scalar break).
        XCTAssertFalse(clampedMB.contains("\u{FFFD}"))
    }

    // MARK: - end-to-end export

    private func stubEntry(
        title: String, author: String?, bytes: String = "epub-bytes"
    ) throws -> LibraryEntry {
        let url = tempDir
            .appendingPathComponent("source-\(UUID().uuidString).epub")
        try Data(bytes.utf8).write(to: url)
        return LibraryEntry(
            epubURL: url, title: title, addedAt: Date(), author: author
        )
    }

    func test_export_copies_each_entry_with_renamed_filename() async throws {
        let destination = tempDir.appendingPathComponent("destination")
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true
        )
        let a = try stubEntry(title: "Anti-Oedipus", author: "Gilles Deleuze")
        let b = try stubEntry(title: "Untitled Lyric", author: nil)

        let exporter = LibraryExporter()
        exporter.start(entries: [a, b], destination: destination)
        try await waitUntilDone(exporter)

        XCTAssertEqual(exporter.copied, 2)
        XCTAssertEqual(exporter.skipped, [])
        XCTAssertEqual(exporter.failed.count, 0)

        let dirs = try FileManager.default.contentsOfDirectory(
            atPath: destination.path
        ).sorted()
        XCTAssertEqual(
            dirs,
            ["Gilles Deleuze - Anti-Oedipus.epub", "Untitled Lyric.epub"]
        )
    }

    func test_export_skips_when_target_already_exists() async throws {
        let destination = tempDir.appendingPathComponent("destination")
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true
        )
        // Pre-stage the target with different content so we can prove
        // the export didn't overwrite it.
        let target = destination
            .appendingPathComponent("Author - Title.epub")
        try Data("preexisting".utf8).write(to: target)
        let entry = try stubEntry(
            title: "Title", author: "Author", bytes: "fresh"
        )

        let exporter = LibraryExporter()
        exporter.start(entries: [entry], destination: destination)
        try await waitUntilDone(exporter)

        XCTAssertEqual(exporter.copied, 0)
        XCTAssertEqual(exporter.skipped, ["Author - Title.epub"])

        let onDisk = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(
            onDisk, "preexisting",
            "Pre-existing target must not be overwritten on skip"
        )
    }

    func test_export_reports_failure_when_source_missing() async throws {
        let destination = tempDir.appendingPathComponent("destination")
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true
        )
        // Build a valid stub, then delete the file so the copy fails.
        let entry = try stubEntry(title: "Gone", author: "Ghost")
        try FileManager.default.removeItem(at: entry.epubURL)

        let exporter = LibraryExporter()
        exporter.start(entries: [entry], destination: destination)
        try await waitUntilDone(exporter)

        XCTAssertEqual(exporter.copied, 0)
        XCTAssertEqual(exporter.failed.count, 1)
        XCTAssertEqual(exporter.failed.first?.0, "Ghost - Gone.epub")
    }

    func test_export_two_entries_with_same_resolved_name_skips_second() async throws {
        // Two distinct catalog entries that happen to sanitize to the
        // same filename. First wins; second is reported as skipped —
        // the user-facing semantics of "duplicate already in dest".
        let destination = tempDir.appendingPathComponent("destination")
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true
        )
        let a = try stubEntry(
            title: "Madness and Civilization", author: "Michel Foucault"
        )
        let b = try stubEntry(
            title: "Madness and Civilization", author: "Michel Foucault"
        )

        let exporter = LibraryExporter()
        exporter.start(entries: [a, b], destination: destination)
        try await waitUntilDone(exporter)

        XCTAssertEqual(exporter.copied, 1)
        XCTAssertEqual(
            exporter.skipped,
            ["Michel Foucault - Madness and Civilization.epub"]
        )
    }

    // MARK: - helpers

    /// Drive the runloop until the exporter's `done` flag flips.
    /// `LibraryExporter.run` is structured + main-actor isolated, so
    /// a short polling loop is the cleanest way to await it from a
    /// test without coupling to a private completion handle.
    private func waitUntilDone(
        _ exporter: LibraryExporter,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !exporter.done {
            if Date() > deadline {
                XCTFail("LibraryExporter never completed within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
    }
}
