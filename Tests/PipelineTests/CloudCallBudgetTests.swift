import XCTest
@testable import Pipeline

/// `CloudCallBudget` is the shared per-book cost cap actor every
/// Cloud-mode feature consults. The contract: `tryConsume()` grants
/// up to `cap` calls, then refuses; counters are accurate even
/// under contention; `cap < 0` is treated as zero.
final class CloudCallBudgetTests: XCTestCase {

    func test_grants_up_to_the_cap_then_refuses() async {
        let budget = CloudCallBudget(cap: 3)
        for _ in 0..<3 {
            let ok = await budget.tryConsume()
            XCTAssertTrue(ok)
        }
        let denied = await budget.tryConsume()
        XCTAssertFalse(denied)
    }

    func test_consumed_and_remaining_track_correctly() async {
        let budget = CloudCallBudget(cap: 5)
        _ = await budget.tryConsume()
        _ = await budget.tryConsume()
        let consumed = await budget.consumed
        let remaining = await budget.remaining
        XCTAssertEqual(consumed, 2)
        XCTAssertEqual(remaining, 3)
    }

    func test_isExhausted_flips_at_the_cap() async {
        let budget = CloudCallBudget(cap: 1)
        var exhausted = await budget.isExhausted
        XCTAssertFalse(exhausted)
        _ = await budget.tryConsume()
        exhausted = await budget.isExhausted
        XCTAssertTrue(exhausted)
    }

    func test_zero_cap_refuses_immediately() async {
        let budget = CloudCallBudget(cap: 0)
        let ok = await budget.tryConsume()
        XCTAssertFalse(ok)
    }

    func test_negative_cap_clamps_to_zero() async {
        let budget = CloudCallBudget(cap: -10)
        XCTAssertEqual(budget.cap, 0)
        let ok = await budget.tryConsume()
        XCTAssertFalse(ok)
    }

    /// Concurrent consumers should never collectively exceed the cap.
    /// Spawn 100 tasks against a cap of 10; assert exactly 10 succeed
    /// and the rest are refused. Catches naive non-actor implementations.
    func test_concurrent_consumers_dont_exceed_the_cap() async {
        let budget = CloudCallBudget(cap: 10)
        let granted = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<100 {
                group.addTask { await budget.tryConsume() }
            }
            var count = 0
            for await ok in group where ok { count += 1 }
            return count
        }
        XCTAssertEqual(granted, 10,
                       "Concurrent consumers must never collectively exceed the cap")
        let consumed = await budget.consumed
        XCTAssertEqual(consumed, 10)
    }
}
