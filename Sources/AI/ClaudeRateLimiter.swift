import Foundation
import os

private let claudeLimiterLog = Logger(
    subsystem: "com.tcarmody.Humanist",
    category: "ClaudeRateLimiter"
)

/// Process-wide rate limiter for Anthropic Messages API requests.
///
/// Multiple Claude callers exist concurrently in normal use — the
/// page-OCR engine running through pages in parallel, the post-OCR
/// Haiku cleanup gating per region, the TOC parser, the chapter
/// classifier, the coherence analyzer, the metadata extractor, the
/// chapter-structure / missed-break / front-back-matter Sonnet
/// passes. Without coordination, two books converting in parallel
/// — or a single book at high parallelism — can burst over
/// Anthropic's tier RPM / TPM caps and trigger 429s, which then
/// either cost retry-with-backoff time *or* exhaust retries and
/// kick pages out to the Tesseract / Vision fallback. Both
/// outcomes are downside-only versus pacing the requests in the
/// first place.
///
/// Mirrors the design of `GeminiEmbeddingRateLimiter.shared`:
/// process-wide actor, sliding-60-second window, configurable
/// caps. Default caps target **Anthropic Tier 1** for the
/// Sonnet models (~50 RPM / 30K input TPM as of 2026-05) with
/// ~17% headroom for sub-window enforcement and request-shape
/// variance. Callers on higher tiers should bump these via
/// `configure(...)`.
///
/// Token counting is **estimated** from the request before the
/// call fires (we don't know the actual count until the API
/// responds with usage stats). `recordSuccess(actualInputTokens:)`
/// corrects the window on response — over-estimates pre-flight
/// release budget after the fact, under-estimates do not (we
/// retain the high-water mark for the request).
public actor ClaudeRateLimiter {
    public static let shared = ClaudeRateLimiter()

    /// Target RPM ceiling. Tier 1 Sonnet 4.6 documents ~50 RPM;
    /// 40 leaves ~20% headroom for sub-window bursts. Conservative
    /// by design — over-pacing slows conversion but never breaks
    /// it; under-pacing burns 429 retries.
    private var maxRequestsPerMinute: Int = 40

    /// Target input-token-per-minute ceiling. Tier 1 documents
    /// ~30K; 25K leaves ~17% headroom. Output-TPM is rarely the
    /// binding constraint (output is usually 2-3× smaller than
    /// the rendered page-image input on Sonnet vision calls), so
    /// we only gate on input.
    private var maxInputTokensPerMinute: Int = 25_000

    /// Sliding window of (firedAt, estimated input tokens) for
    /// the last 60 seconds of fired requests.
    private var window: [Entry] = []

    private struct Entry {
        let firedAt: ContinuousClock.Instant
        var tokens: Int
    }

    /// Monotonic timestamp of the most recent request fired
    /// across any caller. Nil before the first request.
    private var lastRequestAt: ContinuousClock.Instant?

    /// Minimum wall-time between consecutive requests. At 40 RPM
    /// that's 1.5 s. Spreads bursts evenly across the window
    /// rather than letting all N callers fire in the first 100ms
    /// and then stall on TPM for the next 59.9.
    private var minimumInterval: Duration {
        .nanoseconds(Int64(60_000_000_000 / Int64(max(1, maxRequestsPerMinute))))
    }

    public init() {}

    /// Adjust the caps. Nil arguments leave the existing value
    /// in place. Idempotent for callers passing the same defaults.
    public func configure(
        maxRequestsPerMinute: Int? = nil,
        maxInputTokensPerMinute: Int? = nil
    ) {
        if let rpm = maxRequestsPerMinute {
            self.maxRequestsPerMinute = max(1, rpm)
        }
        if let tpm = maxInputTokensPerMinute {
            self.maxInputTokensPerMinute = max(1, tpm)
        }
    }

    /// Acquire a slot for one outbound request that will consume
    /// roughly `estimatedInputTokens` of input. Waits on whichever
    /// gate (RPM or TPM) is currently binding; returns when the
    /// caller can fire. Caller is expected to call
    /// `recordSuccess(actualInputTokens:)` *after* the request
    /// completes with a non-429 status so the window reflects
    /// the true cost.
    public func acquireSlot(estimatedInputTokens: Int) async throws {
        try await waitForSlot()
        try await waitForTokenBudget(needed: estimatedInputTokens)
        let now = ContinuousClock.now
        lastRequestAt = now
        // Reserve the estimated tokens in the window. Updated on
        // success when we learn the actual cost.
        window.append(Entry(firedAt: now, tokens: estimatedInputTokens))
    }

    /// Replace the most-recent reservation's estimate with the
    /// actual input-token count once the API responds. Called
    /// after `acquireSlot` on a successful (non-429) request.
    /// Caller passes the response's `usage.input_tokens`.
    public func recordSuccess(actualInputTokens: Int) {
        guard let last = window.last else { return }
        // The most recent entry should be the one we reserved
        // for this caller — update it. If two callers ran
        // concurrently the entries can interleave, but the cost
        // accounting averages out: each caller updates its own
        // call's *last-fired* entry, and the window length is
        // the load-bearing invariant.
        window[window.count - 1] = Entry(
            firedAt: last.firedAt, tokens: actualInputTokens
        )
    }

    /// Sleep until at least `minimumInterval` has elapsed since
    /// the most recent request fired by any caller. No-op on
    /// the first call.
    private func waitForSlot() async throws {
        guard let last = lastRequestAt else { return }
        let now = ContinuousClock.now
        let elapsed = last.duration(to: now)
        if elapsed < minimumInterval {
            try await Task.sleep(for: minimumInterval - elapsed)
        }
    }

    /// Sleep until the rolling 60s token window has room for
    /// `needed` more tokens. Trims aged entries first.
    private func waitForTokenBudget(needed: Int) async throws {
        let cap = maxInputTokensPerMinute
        let now = ContinuousClock.now
        let windowStart = now.advanced(by: .seconds(-60))
        window.removeAll { $0.firedAt < windowStart }

        let inWindow = window.reduce(0) { $0 + $1.tokens }
        if inWindow + needed <= cap { return }

        let surplus = inWindow + needed - cap
        let sorted = window.sorted { $0.firedAt < $1.firedAt }
        var freed = 0
        for record in sorted {
            freed += record.tokens
            if freed >= surplus {
                let wakeAt = record.firedAt.advanced(by: .seconds(60))
                let waitFor = now.duration(to: wakeAt)
                if waitFor > .zero {
                    claudeLimiterLog.info(
                        "TPM gate: waiting \(waitFor, privacy: .public) for \(needed, privacy: .public) tokens; window=\(inWindow, privacy: .public)/\(cap, privacy: .public)"
                    )
                    try await Task.sleep(for: waitFor)
                }
                let after = ContinuousClock.now
                let newStart = after.advanced(by: .seconds(-60))
                window.removeAll { $0.firedAt < newStart }
                return
            }
        }
        // Single request exceeds the entire TPM cap. Wait one full
        // window; retry-on-429 covers the remaining edge case.
        claudeLimiterLog.info(
            "TPM gate: single request \(needed, privacy: .public) exceeds cap \(cap, privacy: .public); waiting one full window"
        )
        try await Task.sleep(for: .seconds(60))
        window.removeAll()
    }
}
