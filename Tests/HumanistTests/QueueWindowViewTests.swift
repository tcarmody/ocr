import XCTest
import Foundation
import Pipeline
import AI
@testable import Humanist

/// `QueueWindowView` ships two pure sort helpers that drive the
/// Table's sortable columns: `Job.Status.sortRank` and
/// `Job.costSortKey`. The view itself is SwiftUI and not unit-
/// tested (no view-rendering test infra here), but the data plumbing
/// is — table sorting visibly broken on either of these would
/// surface as wrong column order in the FullQueue window.
final class QueueWindowViewTests: XCTestCase {

    // MARK: - Job.Status.sortRank

    func test_status_sortRank_orders_active_states_before_resolved() {
        // Running first (most active), then profiling, queued,
        // then resolved-tier (done < failed < cancelled). The rank
        // is just a stable ordering; what matters is that active
        // status floats to the top of the table when sorted asc.
        let order: [Job.Status] = [
            .running, .profiling, .queued, .done, .failed, .cancelled,
        ]
        let ranks = order.map(\.sortRank)
        XCTAssertEqual(ranks, ranks.sorted(),
            "sortRank must increase from active → resolved")
    }

    func test_status_sortRank_is_stable_per_value() {
        XCTAssertEqual(Job.Status.running.sortRank, 0)
        XCTAssertEqual(Job.Status.profiling.sortRank, 1)
        XCTAssertEqual(Job.Status.queued.sortRank, 2)
        XCTAssertEqual(Job.Status.done.sortRank, 3)
        XCTAssertEqual(Job.Status.failed.sortRank, 4)
        XCTAssertEqual(Job.Status.cancelled.sortRank, 5)
    }

    // MARK: - Job.costSortKey

    private func makeJob(
        stats: ConversionStats? = nil,
        estimate: CostEstimator.Estimate? = nil
    ) -> Job {
        Job(
            sourceURL: URL(fileURLWithPath: "/tmp/x.pdf"),
            outputURL: URL(fileURLWithPath: "/tmp/x.epub"),
            options: ConversionOptions(),
            status: .done,
            stats: stats,
            costEstimate: estimate
        )
    }

    func test_costSortKey_prefers_actual_stats_over_estimate() {
        // After-conversion stats are the authoritative cost; if both
        // are present (estimate ran pre-flight + run completed), the
        // sort key should reflect actual.
        let stats = ConversionStats(
            claudeCallCount: 5, estimatedCostUSD: 0.42
        )
        var estimate = CostEstimator.Estimate.empty
        estimate.estimatedCalls = 100
        estimate.estimatedCostUSD = 9.99
        let job = makeJob(stats: stats, estimate: estimate)
        XCTAssertEqual(job.costSortKey, 0.42, accuracy: 0.001,
            "actual stats cost should win over estimate when both present")
    }

    func test_costSortKey_falls_back_to_estimate_when_no_stats() {
        var estimate = CostEstimator.Estimate.empty
        estimate.estimatedCalls = 50
        estimate.estimatedCostUSD = 1.25
        let job = makeJob(stats: nil, estimate: estimate)
        XCTAssertEqual(job.costSortKey, 1.25, accuracy: 0.001)
    }

    func test_costSortKey_zero_when_neither_present() {
        let job = makeJob(stats: nil, estimate: nil)
        XCTAssertEqual(job.costSortKey, 0)
    }

    func test_costSortKey_zero_when_estimate_has_no_calls() {
        // `.empty` estimate (Cloud mode off / no features) shouldn't
        // contribute a non-zero sort key — those rows should sort
        // alongside the "no-Cloud" jobs at 0.
        let job = makeJob(stats: nil, estimate: .empty)
        XCTAssertEqual(job.costSortKey, 0)
    }

    func test_costSortKey_zero_when_stats_has_zero_claude_calls() {
        // A successful conversion that ran in Private mode has
        // stats but zero Claude calls — same sort treatment as
        // "no Cloud features".
        let stats = ConversionStats()  // claudeCallCount = 0 by default
        let job = makeJob(stats: stats, estimate: nil)
        XCTAssertEqual(job.costSortKey, 0)
    }
}
