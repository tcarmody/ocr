import XCTest
@testable import EPUB

/// `FileCoordination` is mostly a thin wrapper around
/// `NSFileCoordinator`. Testing the coordination behavior itself
/// requires iCloud / sync involvement we can't simulate in CI.
/// These tests pin two things we CAN check without iCloud:
///
///   * The iCloud-path detector fires on the right shape of URL.
///   * The local-path fast path runs `body` directly and returns
///     its result / propagates its thrown error without involving
///     `NSFileCoordinator` machinery.
///
/// End-to-end coordination behavior is verified by manual testing
/// against real iCloud Drive paths.
final class FileCoordinationTests: XCTestCase {

    // MARK: - isICloudPath

    func test_detects_icloud_drive_paths() {
        let icloud = URL(fileURLWithPath:
            "/Users/tim/Library/Mobile Documents/com~apple~CloudDocs/Humanist/Books/x.epub"
        )
        XCTAssertTrue(FileCoordination.isICloudPath(icloud))
    }

    func test_detects_nested_icloud_paths() {
        let nested = URL(fileURLWithPath:
            "/Users/tim/Library/Mobile Documents/com~apple~CloudDocs/A/B/C/D.epub"
        )
        XCTAssertTrue(FileCoordination.isICloudPath(nested))
    }

    func test_rejects_local_documents_path() {
        let local = URL(fileURLWithPath: "/Users/tim/Documents/x.epub")
        XCTAssertFalse(FileCoordination.isICloudPath(local))
    }

    func test_rejects_temp_path() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("x.epub")
        XCTAssertFalse(FileCoordination.isICloudPath(tmp))
    }

    func test_rejects_lookalike_library_path() {
        // `Library/Mobile Documents/` outside the canonical
        // CloudDocs container — a different app's ubiquity
        // container (e.g., third-party note apps that use
        // their own iCloud container ID). We don't coordinate
        // there; the helper's contract is iCloud Drive only.
        let other = URL(fileURLWithPath:
            "/Users/tim/Library/Mobile Documents/iCloud~md~obsidian/Documents/x.md"
        )
        XCTAssertFalse(FileCoordination.isICloudPath(other))
    }

    // MARK: - Local-path passthrough

    func test_coordinated_read_runs_body_for_local_path() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-test-\(UUID().uuidString).txt")
        try "hello".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let read: String = try FileCoordination.coordinatedRead(at: tmp) { url in
            try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertEqual(read, "hello")
    }

    func test_coordinated_read_propagates_thrown_error() {
        struct Bang: Error {}
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-throw-\(UUID().uuidString).txt")
        // File doesn't exist on disk but path is local — body
        // gets called and throws; the helper must propagate.
        XCTAssertThrowsError(
            try FileCoordination.coordinatedRead(at: tmp) { _ in
                throw Bang()
            }
        ) { error in
            XCTAssertTrue(error is Bang)
        }
    }

    func test_coordinated_write_runs_body_for_local_path() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-write-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileCoordination.coordinatedWrite(at: tmp) { url in
            try "wrote it".write(to: url, atomically: true, encoding: .utf8)
        }
        let back = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(back, "wrote it")
    }

    func test_coordinated_write_propagates_thrown_error() {
        struct Bang: Error {}
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-write-throw-\(UUID().uuidString).txt")
        XCTAssertThrowsError(
            try FileCoordination.coordinatedWrite(at: tmp) { _ in
                throw Bang()
            }
        ) { error in
            XCTAssertTrue(error is Bang)
        }
    }
}
