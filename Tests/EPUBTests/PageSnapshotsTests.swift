import XCTest
@testable import EPUB

final class PageSnapshotsTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageSnapshotsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Fingerprint determinism

    func test_fingerprint_is_stable_across_calls() {
        let a = PageSnapshots.fingerprint(of: "<p>hello world</p>")
        let b = PageSnapshots.fingerprint(of: "<p>hello world</p>")
        XCTAssertEqual(a, b)
    }

    func test_fingerprint_differs_for_different_bodies() {
        let a = PageSnapshots.fingerprint(of: "<p>one</p>")
        let b = PageSnapshots.fingerprint(of: "<p>two</p>")
        XCTAssertNotEqual(a, b)
    }

    func test_fingerprint_ignores_leading_trailing_whitespace() {
        // Whitespace shouldn't count as a manual edit — XHTML
        // serialization can leak indentation that varies between
        // writers.
        let a = PageSnapshots.fingerprint(of: "<p>x</p>")
        let b = PageSnapshots.fingerprint(of: "\n\n  <p>x</p>  \n")
        XCTAssertEqual(a, b)
    }

    // MARK: - Sidecar round-trip

    func test_round_trip_through_disk() throws {
        let snapshots = PageSnapshots(fingerprintByAnchor: [
            "hu-page-0": "abc123",
            "hu-page-1": "def456"
        ])
        try snapshots.write(workingDirectory: tempDir)
        let read = try XCTUnwrap(PageSnapshots.read(workingDirectory: tempDir))
        XCTAssertEqual(read, snapshots)
    }

    func test_read_returns_nil_for_legacy_books() {
        // No sidecar present in a fresh tempDir.
        let read = PageSnapshots.read(workingDirectory: tempDir)
        XCTAssertNil(read)
    }

    func test_write_creates_meta_inf_dir_if_missing() throws {
        let snapshots = PageSnapshots(fingerprintByAnchor: ["hu-page-0": "x"])
        // Confirm META-INF doesn't exist yet.
        let metaInf = tempDir.appendingPathComponent("META-INF")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaInf.path))
        try snapshots.write(workingDirectory: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaInf.path))
    }

    // MARK: - Integration with PageContentReplacer

    func test_body_extraction_then_fingerprint_roundtrips() {
        let chapter = """
        <html><body>
        <span id="hu-page-0"></span>
        <p>page 0 body</p>
        <span id="hu-page-1"></span>
        <p>page 1 body</p>
        </body></html>
        """
        let body = try! XCTUnwrap(
            PageContentReplacer.body(of: "hu-page-0", in: chapter)
        )
        let fingerprint = PageSnapshots.fingerprint(of: body)
        XCTAssertFalse(fingerprint.isEmpty)
        // SHA-256 hex is 64 chars.
        XCTAssertEqual(fingerprint.count, 64)
    }

    func test_body_extraction_returns_nil_for_unknown_anchor() {
        let chapter = "<body><span id=\"hu-page-0\"></span><p>x</p></body>"
        XCTAssertNil(PageContentReplacer.body(of: "hu-page-99", in: chapter))
    }
}
