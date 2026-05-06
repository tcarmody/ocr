import XCTest
import OCR
import Layout
import Document
import EPUB
@testable import Pipeline

final class ResumeManagerTests: XCTestCase {

    private func makeStagingDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFixturePDF(at url: URL, byte: UInt8 = 0x42) {
        // Minimal byte content — fingerprint logic only reads the
        // first 64KB and the file size, so this doesn't need to be
        // a real PDF for fingerprint tests.
        let data = Data(repeating: byte, count: 4096)
        try? data.write(to: url)
    }

    // MARK: - Manifest round-trip

    func test_manifest_roundtrips() throws {
        let staging = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: staging) }
        let manager = ResumeManager(stagingDir: staging)
        let manifest = StagingManifest(
            schemaVersion: 1,
            sourceFingerprint: "abcdef:1234",
            totalPages: 250
        )
        try manager.writeManifest(manifest)
        let read = manager.readManifest()
        XCTAssertEqual(read?.schemaVersion, 1)
        XCTAssertEqual(read?.sourceFingerprint, "abcdef:1234")
        XCTAssertEqual(read?.totalPages, 250)
    }

    func test_missing_manifest_returns_nil() {
        let staging = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: staging) }
        let manager = ResumeManager(stagingDir: staging)
        XCTAssertNil(manager.readManifest())
    }

    // MARK: - Fingerprint stability

    func test_fingerprint_stable_for_same_file() {
        let staging = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: staging) }
        let pdf = staging.appendingPathComponent("book.pdf")
        writeFixturePDF(at: pdf)
        let f1 = ResumeManager.fingerprint(of: pdf)
        let f2 = ResumeManager.fingerprint(of: pdf)
        XCTAssertNotNil(f1)
        XCTAssertEqual(f1, f2)
    }

    func test_fingerprint_differs_for_different_content() {
        let staging = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: staging) }
        let a = staging.appendingPathComponent("a.pdf")
        let b = staging.appendingPathComponent("b.pdf")
        writeFixturePDF(at: a, byte: 0x42)
        writeFixturePDF(at: b, byte: 0x43)
        XCTAssertNotEqual(
            ResumeManager.fingerprint(of: a),
            ResumeManager.fingerprint(of: b)
        )
    }

    func test_fingerprint_differs_for_different_size() {
        let staging = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: staging) }
        let a = staging.appendingPathComponent("a.pdf")
        let b = staging.appendingPathComponent("b.pdf")
        try? Data(repeating: 0, count: 1024).write(to: a)
        try? Data(repeating: 0, count: 2048).write(to: b)
        XCTAssertNotEqual(
            ResumeManager.fingerprint(of: a),
            ResumeManager.fingerprint(of: b)
        )
    }

    // MARK: - Per-page checkpoint round-trip

    func test_checkpoint_roundtrips() throws {
        let staging = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: staging) }
        let manager = ResumeManager(stagingDir: staging)
        let checkpoint = PageCheckpoint(
            pageIndex: 42,
            pageBoundsWidth: 612,
            pageBoundsHeight: 792,
            observations: [
                TextObservation(
                    text: "Hello world", confidence: 0.95,
                    box: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.05),
                    source: .vision
                )
            ],
            layoutRegions: [
                LayoutRegion(
                    kind: .text,
                    box: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.05),
                    readingOrder: 0,
                    confidence: 0.9
                )
            ],
            figures: [],
            tableExtractionsByRegionIndex: [:],
            verdict: "reocr",
            correctionTrailEntries: []
        )
        try manager.writeCheckpoint(checkpoint)
        let read = manager.readCheckpoint(forPage: 42)
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.pageIndex, 42)
        XCTAssertEqual(read?.observations.first?.text, "Hello world")
        XCTAssertEqual(read?.observations.first?.source, .vision)
        XCTAssertEqual(read?.layoutRegions?.first?.kind, .text)
        XCTAssertEqual(read?.verdict, "reocr")
    }

    func test_completedPages_lists_written_checkpoints() throws {
        let staging = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: staging) }
        let manager = ResumeManager(stagingDir: staging)
        for i in [0, 5, 12, 99] {
            let checkpoint = PageCheckpoint(
                pageIndex: i, pageBoundsWidth: 1, pageBoundsHeight: 1,
                observations: [], layoutRegions: nil, figures: [],
                tableExtractionsByRegionIndex: [:],
                verdict: nil, correctionTrailEntries: []
            )
            try manager.writeCheckpoint(checkpoint)
        }
        let pages = manager.completedPages()
        XCTAssertEqual(pages, [0, 5, 12, 99])
    }

    func test_completedPages_ignores_non_checkpoint_files() throws {
        let staging = makeStagingDir()
        defer { try? FileManager.default.removeItem(at: staging) }
        let manager = ResumeManager(stagingDir: staging)
        let checkpoint = PageCheckpoint(
            pageIndex: 7, pageBoundsWidth: 1, pageBoundsHeight: 1,
            observations: [], layoutRegions: nil, figures: [],
            tableExtractionsByRegionIndex: [:],
            verdict: nil, correctionTrailEntries: []
        )
        try manager.writeCheckpoint(checkpoint)
        // Drop a debug file in the same dir; should be ignored.
        try? "log".data(using: .utf8)?.write(
            to: staging.appendingPathComponent("log.txt")
        )
        try? "render".data(using: .utf8)?.write(
            to: staging.appendingPathComponent("page-7.png")
        )
        XCTAssertEqual(manager.completedPages(), [7])
    }

    func test_deleteAll_removes_staging_dir() throws {
        let staging = makeStagingDir()
        let manager = ResumeManager(stagingDir: staging)
        try manager.writeManifest(StagingManifest(
            sourceFingerprint: "x", totalPages: 1
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        manager.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }
}
