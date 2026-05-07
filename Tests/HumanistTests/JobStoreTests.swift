import XCTest
import Foundation
import Pipeline
@testable import Humanist

/// `JobStore` mutation tests. Today: `move(from:to:)` for
/// R-Launcher-Reorder. Existing helpers (`add`, `remove`, `update`,
/// `clearFinished`) round-trip through the on-disk JSON; this
/// suite exercises them via an isolated tmp-dir store URL so test
/// runs don't collide with each other or with the real app.
@MainActor
final class JobStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("humanist-jobstore-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    private func makeStore() -> JobStore {
        JobStore(storeURL: tempDir.appendingPathComponent("queue.json"))
    }

    private func makeJob(name: String, status: Job.Status = .queued) -> Job {
        Job(
            sourceURL: URL(fileURLWithPath: "/tmp/\(name).pdf"),
            outputURL: URL(fileURLWithPath: "/tmp/\(name).epub"),
            options: ConversionOptions(),
            status: status
        )
    }

    // MARK: - move(from:to:)

    func test_move_reorders_jobs_in_array() {
        let store = makeStore()
        let a = makeJob(name: "a")
        let b = makeJob(name: "b")
        let c = makeJob(name: "c")
        store.add(a); store.add(b); store.add(c)

        // Move job at index 0 to position 3 (end). SwiftUI's
        // `move(fromOffsets:toOffset:)` semantics: destination is
        // an "insertion offset", so moving from [0] to 3 means
        // "after index 2" → final order [b, c, a].
        store.move(from: IndexSet(integer: 0), to: 3)

        XCTAssertEqual(store.jobs.map(\.id), [b.id, c.id, a.id])
    }

    func test_move_promotes_a_queued_job_to_front() {
        // Common user flow: drop 5 PDFs, decide one needs to run
        // first, drag it to the top.
        let store = makeStore()
        let jobs = (0..<5).map { makeJob(name: "j\($0)") }
        for j in jobs { store.add(j) }

        // Move job at index 3 to position 0.
        store.move(from: IndexSet(integer: 3), to: 0)

        let priority = store.jobs.first?.id
        XCTAssertEqual(priority, jobs[3].id,
            "job at index 3 should become first after move(to: 0)")
        // nextQueued reflects the same priority.
        XCTAssertEqual(store.nextQueued?.id, jobs[3].id)
    }

    func test_move_with_empty_indexset_is_noop() {
        let store = makeStore()
        let a = makeJob(name: "a")
        let b = makeJob(name: "b")
        store.add(a); store.add(b)

        store.move(from: IndexSet(), to: 0)

        XCTAssertEqual(store.jobs.map(\.id), [a.id, b.id])
    }

    func test_move_persists_across_store_instances() {
        // Reordering should round-trip through the JSON file so the
        // user's intent survives an app relaunch.
        let store = makeStore()
        let a = makeJob(name: "a")
        let b = makeJob(name: "b")
        let c = makeJob(name: "c")
        store.add(a); store.add(b); store.add(c)
        store.move(from: IndexSet(integer: 0), to: 3)
        // Same backing file, fresh in-memory instance.
        let restarted = makeStore()
        XCTAssertEqual(restarted.jobs.map(\.id), [b.id, c.id, a.id])
    }

    func test_move_lets_user_reorder_among_mixed_statuses() {
        // Mixed queue: [done, queued1, queued2, queued3]. The user
        // should be able to drag queued3 ahead of queued1. The done
        // job's index is unaffected by a move that doesn't cross it.
        let store = makeStore()
        let done = makeJob(name: "done", status: .done)
        let q1 = makeJob(name: "q1")
        let q2 = makeJob(name: "q2")
        let q3 = makeJob(name: "q3")
        store.add(done); store.add(q1); store.add(q2); store.add(q3)

        // Move index 3 (q3) to position 1 (just after done).
        store.move(from: IndexSet(integer: 3), to: 1)

        XCTAssertEqual(store.jobs.map(\.id), [done.id, q3.id, q1.id, q2.id])
        // The runner picks first .queued — that's now q3.
        XCTAssertEqual(store.nextQueued?.id, q3.id)
    }
}
