import Foundation

/// Per-book ceiling on Claude API calls, shared across every Cloud-mode
/// feature that consumes the API (OCR, table extraction, post-OCR
/// cleanup, semantic classification, TOC parsing).
///
/// Why one shared budget rather than one per feature: the user sets a
/// single "max calls per book" in Settings and expects that to bound
/// the cost of the conversion as a whole. A per-feature cap would let
/// a book with many tables blow past the user's intended ceiling
/// because each feature has its own reservoir.
///
/// Construct one per `convert(...)` call; pass to every Claude-backed
/// engine the conversion uses. When the budget is exhausted, callers
/// see `tryConsume()` return `false` and should fall back to the prior
/// tier (the cascade does this for OCR; future phases follow the same
/// pattern).
public actor ClaudeCallBudget {
    /// Initial cap (i.e., `AISettings.perBookCallCap`). `nonisolated`
    /// because it's set once at init and never mutates — callers can
    /// read it without a hop into the actor.
    public nonisolated let cap: Int
    /// Calls already granted this conversion. Surfaceable post-run for
    /// telemetry and audit (the editor's "AI trail" inspector will read
    /// this when it ships).
    public private(set) var consumed: Int = 0

    public init(cap: Int) {
        self.cap = max(0, cap)
    }

    /// Try to claim one call from the budget. Returns `true` if granted
    /// (and the consumed counter is incremented), `false` once the cap
    /// is reached. Callers must check the return value before issuing
    /// the network request.
    public func tryConsume() -> Bool {
        guard consumed < cap else { return false }
        consumed += 1
        return true
    }

    /// Calls still available. Useful for log lines and the cost cap UI.
    public var remaining: Int { max(0, cap - consumed) }

    /// True when the cap has been hit. Equivalent to `remaining == 0`
    /// but reads more naturally at the call site.
    public var isExhausted: Bool { remaining == 0 }
}
