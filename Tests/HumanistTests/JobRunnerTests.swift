import XCTest
@testable import Humanist

/// `JobRunner` pause / resume state machine. Pure state-machine
/// tests — the runner's heavy path (actually invoking
/// `PDFToEPUBPipeline`) isn't exercised here; that's manual /
/// end-to-end. R-Launcher-Pause's surface is the persisted flag +
/// the `start()` no-op while paused.
@MainActor
final class JobRunnerTests: XCTestCase {

    // Fresh isolated UserDefaults suite per test so the persisted
    // pause flag doesn't leak across tests or pollute the app's
    // standard defaults.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "humanist-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeRunner() -> JobRunner {
        JobRunner(store: JobStore(), defaults: defaults)
    }

    // MARK: - default state

    func test_isPaused_defaults_to_false_on_fresh_runner() {
        let runner = makeRunner()
        XCTAssertFalse(runner.isPaused)
    }

    // MARK: - pause / resume

    func test_pause_sets_isPaused_and_persists() {
        let runner = makeRunner()
        runner.pause()
        XCTAssertTrue(runner.isPaused)
        XCTAssertTrue(defaults.bool(forKey: JobRunner.pausedKey),
            "pause() should persist the flag for the next launch")
    }

    func test_resume_clears_isPaused_and_persists() {
        let runner = makeRunner()
        runner.pause()
        runner.resume()
        XCTAssertFalse(runner.isPaused)
        XCTAssertFalse(defaults.bool(forKey: JobRunner.pausedKey),
            "resume() should clear the persisted flag")
    }

    func test_pause_is_idempotent() {
        let runner = makeRunner()
        runner.pause()
        runner.pause()
        XCTAssertTrue(runner.isPaused)
    }

    func test_resume_is_idempotent_when_not_paused() {
        let runner = makeRunner()
        runner.resume()  // never paused
        XCTAssertFalse(runner.isPaused)
    }

    // MARK: - persistence across runner instances

    func test_paused_flag_survives_runner_restart() {
        // First runner pauses + drops out of scope.
        do {
            let runner = makeRunner()
            runner.pause()
        }
        // New runner with the same UserDefaults suite picks up the
        // persisted flag — simulates app relaunch with a paused queue.
        let restarted = makeRunner()
        XCTAssertTrue(restarted.isPaused,
            "paused state should survive across runner instances (i.e. app launches)")
    }

    func test_resumed_flag_survives_runner_restart() {
        do {
            let runner = makeRunner()
            runner.pause()
            runner.resume()
        }
        let restarted = makeRunner()
        XCTAssertFalse(restarted.isPaused)
    }

    // MARK: - start() interaction

    func test_start_is_noop_when_paused_and_no_jobs() {
        // With no queued jobs and isPaused=true, start() should not
        // crash and should leave isRunning false. This is the cheapest
        // observable assertion that doesn't depend on running the
        // pipeline (which would need a real PDF).
        let runner = makeRunner()
        runner.pause()
        runner.start()
        XCTAssertFalse(runner.isRunning,
            "start() while paused must not enter the run loop")
    }
}
