import Foundation
import Combine

/// Tracks ongoing operations that mutate the on-disk vector index —
/// per-book embedding sidecars, entity sidecars, the alias
/// dictionary, the federated catalog file. Chat retrieval reads
/// from those sidecars, and reading while a writer is in flight
/// gives inconsistent results: partial JSON, mismatched backend
/// dimensions, missing books that were just added, double-counted
/// books mid-rebuild. Worse, a chat send during a bulk index also
/// piles on disk-IO contention while the publish storm from the
/// indexer's per-book progress updates churns the SwiftUI view
/// tree.
///
/// Operations call `begin(_:)` to register a mutating window and
/// `release()` on the returned token when the work completes.
/// Readers consult `isStable` (or observe `activeOperations`) to
/// decide whether to start a chat send. The shared singleton is
/// the right shape here: the on-disk vector index is a single
/// process-wide resource, and writers from different code paths
/// (bulk indexer, EPUB importer, per-book sidecar build during
/// editor open) all need to coordinate against the same lock.
@MainActor
final class VectorIndexCoordinator: ObservableObject {
    static let shared = VectorIndexCoordinator()

    /// Active mutating-operation count. Zero means the index is
    /// stable for chat retrieval. Driven by paired begin/release
    /// calls; clamped at zero so an accidental double-release
    /// can't push it negative.
    @Published private(set) var activeOperations: Int = 0

    /// Human-readable description of the most recently-registered
    /// operation. The chat pane surfaces this so the user knows
    /// *what* is in flight, not just that something is. Last-write-
    /// wins because the UI displays a single banner — a deep stack
    /// of concurrent ops is rare in practice (the launcher
    /// serializes bulk operations) and would clutter the UI.
    @Published private(set) var activeDescription: String? = nil

    /// True when no mutating operation is in flight. Convenience
    /// for read-side callers that just want a boolean.
    var isStable: Bool { activeOperations == 0 }

    private init() {}

    /// Register the start of a mutating window. Returns a token;
    /// callers MUST call `.release()` when the work completes (or
    /// let the token deinit auto-release as a safety net). Pair
    /// with `defer { token.release() }` at the top of a function
    /// to guarantee balance even on early returns / thrown errors.
    func begin(_ description: String) -> Token {
        activeOperations += 1
        activeDescription = description
        return Token(coordinator: self)
    }

    fileprivate func end() {
        activeOperations = max(0, activeOperations - 1)
        if activeOperations == 0 {
            activeDescription = nil
        }
    }

    /// RAII-ish token. Release is idempotent — a no-op after the
    /// first call so a `defer token.release()` plus an explicit
    /// release on the success path can coexist. Deinit-time auto-
    /// release is a backstop for code paths that forget; it hops
    /// to MainActor because `end()` is actor-isolated.
    @MainActor
    final class Token {
        private weak var coordinator: VectorIndexCoordinator?
        private var released: Bool = false

        fileprivate init(coordinator: VectorIndexCoordinator) {
            self.coordinator = coordinator
        }

        deinit {
            guard !released else { return }
            // `self` is dying — we can't hop back to MainActor from
            // a deinit if the runtime isn't already on it. The
            // common case is that release() was called explicitly;
            // this branch only fires for truly orphaned tokens
            // (cancelled tasks that didn't run their defer). Best-
            // effort: schedule on main without capturing self.
            let coord = coordinator
            Task { @MainActor in coord?.end() }
        }

        func release() {
            guard !released else { return }
            released = true
            coordinator?.end()
        }
    }
}
