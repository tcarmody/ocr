import XCTest
import Foundation
@testable import Humanist

/// R-Library-Index — coverage for the per-book timeout machinery
/// added so one pathological EPUB can't freeze the whole bulk-index
/// run. The race-helper (`runWithTimeout`) is exercised in
/// isolation; the smart per-book sizing is exercised against
/// synthetic on-disk files of known sizes.
@MainActor
final class LibraryIndexBuilderTimeoutTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-index-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - runWithTimeout

    /// Fast path: an operation that finishes well before the
    /// deadline returns its value unchanged. The timeout machinery
    /// must add zero observable latency on the happy path.
    func test_runWithTimeout_returns_value_when_operation_completes_in_time() async throws {
        let result = try await LibraryIndexBuilder.runWithTimeout(
            seconds: 5
        ) { @Sendable in
            return 42
        }
        XCTAssertEqual(result, 42)
    }

    /// Operation errors pass through unchanged — no double-wrap as
    /// timeout failures. The bulk-index loop relies on this so the
    /// failures list distinguishes "this EPUB is corrupt" from
    /// "this EPUB is stuck."
    func test_runWithTimeout_passes_through_operation_errors() async {
        struct CustomError: Error {}
        do {
            _ = try await LibraryIndexBuilder.runWithTimeout(
                seconds: 5
            ) { @Sendable () async throws -> Int in
                throw CustomError()
            }
            XCTFail("Expected operation error to propagate")
        } catch is CustomError {
            // Expected — bare CustomError, not wrapped.
        } catch {
            XCTFail("Wrong error type propagated: \(error)")
        }
    }

    /// Slow path: an operation that sleeps past the deadline gets
    /// cancelled and the helper throws `IndexBuildTimedOut`. The
    /// timeout is reported in the error so the UI can label the
    /// failure honestly.
    func test_runWithTimeout_raises_IndexBuildTimedOut_when_operation_overruns() async {
        let start = Date()
        do {
            _ = try await LibraryIndexBuilder.runWithTimeout(
                seconds: 0.1
            ) { @Sendable () async throws -> Int in
                // 5s sleep — comfortably past the 0.1s deadline.
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 0
            }
            XCTFail("Expected IndexBuildTimedOut")
        } catch let error as IndexBuildTimedOut {
            XCTAssertEqual(error.seconds, 0.1)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        // Helper must actually short-circuit — if it waited for the
        // full 5s, the timeout machinery is broken.
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 2.0,
            "Helper should return shortly after the deadline, not wait for the operation"
        )
    }

    /// Regression: when the OUTER caller's Task is cancelled (the
    /// user-clicks-Cancel path), `runWithTimeout` must unstick
    /// immediately rather than waiting for the in-flight operation
    /// to naturally finish. Pre-fix, the unstructured work-Task's
    /// `value` await silently ignored the outer cancellation; the
    /// indexer would freeze on a stuck book until its own watchdog
    /// fired (minutes for a large EPUB). The
    /// `withTaskCancellationHandler` plumbing inside the helper
    /// is what makes Cancel actually responsive — assert that
    /// here so a future refactor can't quietly regress it.
    func test_runWithTimeout_propagates_outer_task_cancellation() async {
        let started = Date()
        let outer = Task<Void, Error> {
            try await LibraryIndexBuilder.runWithTimeout(
                seconds: 600  // 10 minutes — comfortably longer than the test
            ) { @Sendable () async throws -> Void in
                // Long sleep that respects cooperative cancellation.
                try await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            }
        }
        // Give the inner work a moment to start.
        try? await Task.sleep(nanoseconds: 50_000_000)
        outer.cancel()
        do {
            try await outer.value
            XCTFail("Expected outer-cancelled task to throw")
        } catch is CancellationError {
            // Expected — outer's cancellation was forwarded into
            // the work task; work bailed via cooperative cancel;
            // runWithTimeout re-threw CancellationError so the
            // outer loop can break on this signal.
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 5.0,
            "Outer cancel must unstick the helper within seconds, not wait for the inner operation to finish"
        )
    }

    // MARK: - smart timeout sizing

    /// Tiny EPUB → base ceiling. The base is generous enough to
    /// cover extract + serialize overhead even on a near-empty
    /// file, so a 1KB synthetic stub should land right at the base.
    func test_smartTimeout_returns_base_for_tiny_files() throws {
        let url = tempDir.appendingPathComponent("tiny.epub")
        try Data(count: 1024).write(to: url)
        let entry = LibraryEntry(
            epubURL: url, title: "Tiny", addedAt: Date()
        )
        let timeout = LibraryIndexBuilder.smartTimeout(for: entry)
        // 60s base + (~0 MB × 10s) — should be 60 ± rounding.
        XCTAssertEqual(timeout, 60, accuracy: 1.0)
    }

    /// A 10MB book picks up 100s of slack over the base (10 MB ×
    /// 10s/MB). This is the load-bearing assertion that the slope
    /// actually scales with file size — without it, the timeout
    /// would be a flat ceiling and big books would mass-fail.
    func test_smartTimeout_scales_with_file_size() throws {
        let url = tempDir.appendingPathComponent("medium.epub")
        try Data(count: 10 * 1_000_000).write(to: url)
        let entry = LibraryEntry(
            epubURL: url, title: "Medium", addedAt: Date()
        )
        let timeout = LibraryIndexBuilder.smartTimeout(for: entry)
        // 60s base + (10 MB × 10s/MB) = 160s.
        XCTAssertEqual(timeout, 160, accuracy: 1.0)
    }

    /// Pathologically-huge file (here we just claim it via the API,
    /// not by writing 5GB to disk) — the cap saves us from giving
    /// a single book half an hour of slack. 30 min is the documented
    /// hard ceiling; if a book genuinely needs longer than that,
    /// something has gone wrong and surfacing it as a timeout is
    /// the right call.
    func test_smartTimeout_caps_at_thirty_minutes() throws {
        // A 5GB file would saturate the formula; we don't actually
        // need to write 5GB — we can write a sparse stub and adjust
        // the file's reported size via FileManager attributes…
        // simpler: just check that an arbitrarily large `bytes`
        // input clamps. Since the helper reads file size via
        // FileManager, we feed it a hand-rolled scenario via a
        // bigger-than-cap write to a small chunk. Skip the disk
        // path and use a large sparse file.
        let url = tempDir.appendingPathComponent("huge.epub")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        // 5GB sparse file — `truncate` extends size without writing
        // physical bytes, so this is essentially free on APFS.
        try handle.truncate(atOffset: 5 * 1_000_000_000)
        try handle.close()

        let entry = LibraryEntry(
            epubURL: url, title: "Huge", addedAt: Date()
        )
        let timeout = LibraryIndexBuilder.smartTimeout(for: entry)
        // Naïve formula: 60 + 5000 × 10 = 50,060s. Cap clamps to
        // 30 × 60 = 1800s.
        XCTAssertEqual(timeout, 1800, accuracy: 1.0)
    }

    /// Missing file (catalog row points at a vanished EPUB) — the
    /// helper falls back to the base. The build will throw a real
    /// error a moment later anyway; the timeout sizing just doesn't
    /// crash on the stat() failure.
    func test_smartTimeout_falls_back_to_base_when_file_missing() {
        let url = tempDir.appendingPathComponent("does-not-exist.epub")
        let entry = LibraryEntry(
            epubURL: url, title: "Gone", addedAt: Date()
        )
        let timeout = LibraryIndexBuilder.smartTimeout(for: entry)
        XCTAssertEqual(timeout, 60, accuracy: 1.0)
    }
}
