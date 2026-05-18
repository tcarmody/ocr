import Foundation

/// Process-wide rate limiter for Gemini embedding requests.
///
/// Multiple `GeminiEmbeddingBackend` instances exist concurrently
/// in normal use — library bulk-indexing creates one, each chat
/// view creates its own, the Settings test-connection probe
/// creates a third. Without a shared limiter each instance would
/// pace itself in isolation and the combined RPM/TPM across
/// instances could easily blow Google's per-project quota even
/// when no single instance does.
///
/// All backend instances acquire a slot here before firing a
/// request and report token usage here on success. The actor's
/// serialization makes this an authoritative global gate. Google
/// enforces quota per API project (one project per API key in
/// AI Studio), so coordinating on the process is the right scope —
/// every backend in this app shares one Google project.
///
/// Limits are mutable so callers with non-default tier numbers can
/// adjust via `configure(...)`. Last writer wins; in normal use
/// all callers pass the same defaults so the call is idempotent.
public actor GeminiEmbeddingRateLimiter {
    public static let shared = GeminiEmbeddingRateLimiter()

    /// Target RPM ceiling. Tier 1 paid Gemini documents 3000 RPM
    /// on `gemini-embedding-2`; defaulting to 2000 leaves ~33%
    /// headroom. Lowered from 2500 (2026-05-17) after observing
    /// retry storms during bursts pushed effective rate past 3000
    /// even with the spacing gate.
    private var maxRequestsPerMinute: Int = 2000
    /// Target TPM ceiling. Tier 1 cap is 1M on the embedding model;
    /// 800K leaves 20% headroom. The first throttle iteration set
    /// this to 100K, which over-paced bulk-indexing relative to the
    /// real cap; bumping in light of the user's actual dashboard.
    private var maxTokensPerMinute: Int = 800_000

    /// Monotonic timestamp of the most recent request fired across
    /// any backend instance. Nil before the first request. Used by
    /// the spacing gate that smooths bursts; the rolling-window
    /// gate below is what actually caps total throughput.
    private var lastRequestAt: ContinuousClock.Instant?
    /// Sliding 60s window of request timestamps for RPM-cap
    /// enforcement. Spacing alone (`waitForSlot`) was inadequate
    /// because retries-on-429 don't go through the spacer the same
    /// way (different call site), so a burst could push us past the
    /// per-minute count even when intervals looked correct. This
    /// window tracks actual fired requests and blocks when count
    /// reaches cap.
    private var requestWindow: [ContinuousClock.Instant] = []
    /// Sliding window of (timestamp, estimated tokens) for the
    /// last 60 seconds of requests across all backend instances.
    private var tokenWindow: [TokenWindowEntry] = []

    private struct TokenWindowEntry {
        let firedAt: ContinuousClock.Instant
        let tokens: Int
    }

    /// Minimum wall-time between consecutive requests. At 2500 RPM
    /// that's 24 ms.
    private var minimumInterval: Duration {
        .nanoseconds(Int64(60_000_000_000 / Int64(max(1, maxRequestsPerMinute))))
    }

    public init() {}

    /// Adjust the RPM / TPM caps. Nil arguments leave the existing
    /// value in place. Called by `GeminiEmbeddingBackend.init` so
    /// the limits flow from the constructor parameters — most
    /// callers use the defaults so this is idempotent in practice.
    public func configure(
        maxRequestsPerMinute: Int? = nil,
        maxTokensPerMinute: Int? = nil
    ) {
        if let rpm = maxRequestsPerMinute {
            self.maxRequestsPerMinute = max(1, rpm)
        }
        if let tpm = maxTokensPerMinute {
            self.maxTokensPerMinute = max(1, tpm)
        }
    }

    /// Acquire a slot for one outbound request that will consume
    /// `estimatedTokens` of input. Waits on whichever gate (RPM
    /// spacing, RPM window, or TPM window) is currently binding;
    /// returns when the caller can fire. Caller is expected to
    /// call `recordSuccess(tokens:)` *after* the request completes
    /// with a non-429 status. Failed (429) requests don't get
    /// recorded — Google's quota doesn't count them against the
    /// user's budget either.
    public func acquireSlot(estimatedTokens: Int) async throws {
        try await waitForSlot()
        try await waitForRequestBudget()
        try await waitForTokenBudget(needed: estimatedTokens)
        let now = ContinuousClock.now
        lastRequestAt = now
        requestWindow.append(now)
    }

    /// Record a successfully-fired request's input-token cost.
    public func recordSuccess(tokens: Int) {
        tokenWindow.append(TokenWindowEntry(
            firedAt: ContinuousClock.now,
            tokens: tokens
        ))
    }

    /// Sleep until at least `minimumInterval` has elapsed since
    /// the most recent request fired by any backend instance.
    /// No-op on the first call.
    private func waitForSlot() async throws {
        guard let last = lastRequestAt else { return }
        let now = ContinuousClock.now
        let elapsed = last.duration(to: now)
        if elapsed < minimumInterval {
            try await Task.sleep(for: minimumInterval - elapsed)
        }
    }

    /// Sleep until the rolling 60s request window has room for
    /// one more request. Trims aged entries first. This is the
    /// load-bearing RPM gate — the spacing gate above only
    /// smooths the rate, it doesn't enforce the total.
    private func waitForRequestBudget() async throws {
        let cap = maxRequestsPerMinute
        let now = ContinuousClock.now
        let windowStart = now.advanced(by: .seconds(-60))
        requestWindow.removeAll { $0 < windowStart }
        if requestWindow.count < cap { return }
        // At cap. Sleep until the oldest entry ages out of the
        // window, then re-trim and let the caller through.
        let oldest = requestWindow.first ?? now
        let wakeAt = oldest.advanced(by: .seconds(60))
        let waitFor = now.duration(to: wakeAt)
        if waitFor > .zero {
            try await Task.sleep(for: waitFor)
        }
        let after = ContinuousClock.now
        let newStart = after.advanced(by: .seconds(-60))
        requestWindow.removeAll { $0 < newStart }
    }

    /// Sleep until the rolling 60s token window has room for
    /// `needed` more tokens. Trims aged entries first.
    private func waitForTokenBudget(needed: Int) async throws {
        let cap = maxTokensPerMinute
        let now = ContinuousClock.now
        let windowStart = now.advanced(by: .seconds(-60))
        tokenWindow.removeAll { $0.firedAt < windowStart }

        let inWindow = tokenWindow.reduce(0) { $0 + $1.tokens }
        if inWindow + needed <= cap { return }

        let surplus = inWindow + needed - cap
        let sorted = tokenWindow.sorted { $0.firedAt < $1.firedAt }
        var freed = 0
        for record in sorted {
            freed += record.tokens
            if freed >= surplus {
                let wakeAt = record.firedAt.advanced(by: .seconds(60))
                let waitFor = now.duration(to: wakeAt)
                if waitFor > .zero {
                    try await Task.sleep(for: waitFor)
                }
                let after = ContinuousClock.now
                let newStart = after.advanced(by: .seconds(-60))
                tokenWindow.removeAll { $0.firedAt < newStart }
                return
            }
        }
        // Single request exceeds the entire TPM cap. Wait one full
        // window; retry-on-429 covers the remaining edge case.
        try await Task.sleep(for: .seconds(60))
        tokenWindow.removeAll()
    }
}
