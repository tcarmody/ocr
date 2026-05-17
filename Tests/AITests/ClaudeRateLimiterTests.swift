import XCTest
@testable import AI

/// `ClaudeRateLimiter` smoke tests. We don't exercise the sliding
/// 60s window (would make the suite slow); we cover the
/// configuration knobs and the immediate (no-prior-request) path.
final class ClaudeRateLimiterTests: XCTestCase {

    func test_first_acquire_returns_promptly() async throws {
        let limiter = ClaudeRateLimiter()
        // 10K RPM means the minimum interval is 6ms — fast enough
        // that the first call returns essentially instantly.
        await limiter.configure(maxRequestsPerMinute: 10_000)
        let start = ContinuousClock.now
        try await limiter.acquireSlot(estimatedInputTokens: 100)
        let elapsed = start.duration(to: ContinuousClock.now)
        XCTAssertLessThan(elapsed, .milliseconds(100))
    }

    func test_recordSuccess_updates_window_estimate() async throws {
        let limiter = ClaudeRateLimiter()
        await limiter.configure(
            maxRequestsPerMinute: 10_000,
            maxInputTokensPerMinute: 1_000_000
        )
        // Pre-flight with an over-estimate, then correct down on
        // success. The next acquire should see the corrected total.
        try await limiter.acquireSlot(estimatedInputTokens: 5_000)
        await limiter.recordSuccess(actualInputTokens: 1_000)
        // No assertion on internal state (the actor's window is
        // private), but the call sequence shouldn't throw and
        // shouldn't block.
        try await limiter.acquireSlot(estimatedInputTokens: 100)
    }
}
