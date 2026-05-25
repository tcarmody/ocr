import Foundation
import LibraryIndexing
import AI
import EPUB

/// Raised when a single book's index build exceeds
/// `LibraryIndexBuilder.perBookTimeout` and the watchdog cancels
/// the work. Carries the timeout that was hit so the UI can show
/// `"Timed out after 120s"` rather than a bare CancellationError.
/// Distinct from CancellationError so the bulk-index path can
/// separate "user clicked Cancel" from "this one book is stuck."
struct IndexBuildTimedOut: Error, LocalizedError {
    let seconds: TimeInterval
    var errorDescription: String? {
        "Indexing stalled — gave up after \(Int(seconds))s."
    }
}

/// Bulk-index every book in the library so library-scope chat has
/// something to retrieve from. Each book gets its embedding +
/// hierarchy + entity sidecar built (or rebuilt if the persisted
/// backend doesn't match the one selected in Settings).
///
/// This is the explicit alternative to "open every book's chat
/// pane once" — necessary on first use of library chat after
/// flipping backends, and useful any time the user wants to refresh
/// the federation in one shot.
///
/// Per-book timeout: each book's build is wrapped in a watchdog
/// (`perBookTimeout`, default 120s). A pathological EPUB that
/// stalls on extraction, unzip, or backend embed gets a hard ceiling
/// — the watchdog cancels the work task and the failure is recorded
/// as a timeout in the UI so the bulk run moves on. Without this,
/// one bad book could freeze the whole indexer for tens of minutes;
/// "the run eventually skipped it" was the user-reported symptom.
@MainActor
final class LibraryIndexBuilder: ObservableObject {

    /// Current build state. Drives the sheet UI in the library
    /// window.
    enum Status: Equatable {
        case idle
        case running
        case completed
        case cancelled
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// 1-based "indexing book N of M". Update lives on the
    /// main actor so SwiftUI refreshes the progress UI in real
    /// time without throttling.
    @Published private(set) var current: Int = 0
    @Published private(set) var total: Int = 0
    @Published private(set) var currentBookTitle: String = ""
    /// Books that errored during their build pass. The UI shows
    /// these so the user can decide whether to investigate (often
    /// one bad EPUB; rest of the library succeeds).
    @Published private(set) var failures: [(title: String, error: String)] = []
    /// Books skipped because their sidecar already matched the
    /// chosen backend + dimension and contained at least one
    /// paragraph. Surfaced so the user knows the bulk run wasn't
    /// a no-op for their library.
    @Published private(set) var skippedExistingCount: Int = 0
    /// Books that fell back to Apple's on-device NLEmbedding after
    /// the requested cloud backend (typically Gemini) errored on
    /// the whole book. Lets the progress sheet show "indexed with
    /// Apple fallback" so the user knows which books to re-index
    /// later when their cloud quota frees up. The string carries
    /// the primary backend's localized error so the user can
    /// distinguish "rate-limited" from "API key expired" etc.
    @Published private(set) var fallbacks: [(title: String, reason: String)] = []

    /// Per-book timeout strategy. Default scales with the EPUB's
    /// on-disk size so a 1MB novella gets a tight ceiling and a
    /// 50MB scanned-book monster gets enough slack to legitimately
    /// finish. Exposed as a closure so tests can substitute a
    /// constant (e.g. 0.05s) without poking at file sizes.
    var perBookTimeout: @Sendable (LibraryEntry) -> TimeInterval =
        LibraryIndexBuilder.smartTimeout(for:)

    /// Default smart-timeout: `60s base + 10s per MB of EPUB`,
    /// capped at 30 minutes. The base covers extract + serialize
    /// overhead even for tiny books; the per-MB slope tracks the
    /// rough linear relationship between file size and paragraph
    /// count (the embed loop is the slow path); the 30-min cap
    /// catches the truly pathological cases — anything that needs
    /// longer than that is almost certainly stuck, and surfacing
    /// it as a timed-out failure is the right call so the bulk run
    /// can move on. File size is read via a single `stat`; an
    /// unreadable / missing source falls back to the base value
    /// (the build will surface a real error a moment later anyway).
    nonisolated static func smartTimeout(
        for entry: LibraryEntry
    ) -> TimeInterval {
        let base: TimeInterval = 60
        let perMB: TimeInterval = 10
        let cap: TimeInterval = 30 * 60
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: entry.epubURL.path
        )
        let bytes = (attrs?[.size] as? NSNumber)?.doubleValue ?? 0
        let mb = bytes / 1_000_000
        return min(cap, base + perMB * mb)
    }

    private var task: Task<Void, Never>?

    init() {}

    deinit { task?.cancel() }

    /// Kick off a bulk build. `forceRebuild` wipes per-book
    /// sidecars before running so the user can recover from a
    /// stale / corrupt cache without going through Settings.
    func start(
        entries: [LibraryEntry],
        backend: any EmbeddingBackend,
        forceRebuild: Bool = false
    ) {
        guard status != .running else { return }
        status = .running
        current = 0
        total = entries.count
        currentBookTitle = ""
        failures = []
        fallbacks = []
        skippedExistingCount = 0
        let store = EmbeddingsSidecarStore()
        let snapshot = entries
        // Per-book fallback: if the requested backend errors on a
        // whole book (Gemini 429 / quota exhaustion is the
        // motivating case), retry that book with Apple's on-device
        // NLEmbedding so the user gets *some* embedding rather
        // than a hole in the library. The fallback sidecar is
        // marked with Apple's backendIdentifier so subsequent
        // re-indexes preserve it instead of looping back into the
        // failing primary. Skip when the primary IS Apple
        // NLEmbedding (no useful fallback to add) or when Apple
        // doesn't provide an English sentence model on this OS.
        let fallback: (any EmbeddingBackend)? =
            (backend.identifier.hasPrefix("apple") == false)
                ? NLSentenceEmbeddingBackend(language: .english)
                : nil
        // Register with the shared coordinator so any chat send
        // attempted during the bulk run is told to wait. Released
        // in the task's completion block (and via the token's
        // deinit safety net if the task is cancelled before it
        // can run the cleanup).
        let token = VectorIndexCoordinator.shared.begin(
            forceRebuild
                ? "Rebuilding library indexes"
                : "Indexing library books"
        )
        let timeoutFor = perBookTimeout
        // Detached on purpose. `Task { … }` from a @MainActor class
        // inherits the main-actor isolation, which would pin the
        // synchronous heavy steps (EPUB unzip, paragraph extraction,
        // sidecar serialize) to the main thread. With those running
        // on main, the Cancel button can't even repaint between
        // books, never mind register a click. Detaching pushes the
        // loop onto the cooperative thread pool; UI updates hop
        // back via the existing `await MainActor.run` blocks.
        task = Task.detached(priority: .userInitiated) { [weak self] in
            for (idx, entry) in snapshot.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self?.current = idx + 1
                    self?.currentBookTitle = entry.title
                }
                let bookTimeout = timeoutFor(entry)
                do {
                    let outcome = try await Self.runWithTimeout(
                        seconds: bookTimeout
                    ) {
                        try await Self.buildOneBook(
                            entry: entry, backend: backend,
                            fallbackBackend: fallback,
                            store: store, forceRebuild: forceRebuild
                        )
                    }
                    switch outcome {
                    case .skipped:
                        await MainActor.run { self?.skippedExistingCount += 1 }
                    case .built(let usedFallback, let primaryError):
                        if usedFallback {
                            await MainActor.run {
                                self?.fallbacks.append((
                                    title: entry.title,
                                    reason: primaryError ?? "unknown"
                                ))
                            }
                        }
                    }
                } catch is CancellationError {
                    // User clicked Cancel — outer loop will break on
                    // the next iteration's isCancelled check. Don't
                    // record this as a per-book failure; it's a
                    // run-level signal, not a book-level one.
                    break
                } catch {
                    await MainActor.run {
                        self?.failures.append(
                            (title: entry.title, error: error.localizedDescription)
                        )
                    }
                }
            }
            await MainActor.run {
                guard let self else { token.release(); return }
                self.status = Task.isCancelled ? .cancelled : .completed
                self.currentBookTitle = ""
                token.release()
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Build (or skip) a single book's sidecar. Returns the
    /// `BookSidecarBuilder.Outcome` so the caller can distinguish
    /// "skipped because cache hit," "built with primary backend,"
    /// and "built with fallback after primary failed." Thin wrapper
    /// around `BookSidecarBuilder.buildIfNeeded` — shared with
    /// `EPUBImporter`, which builds exactly one book per call.
    private static func buildOneBook(
        entry: LibraryEntry,
        backend: any EmbeddingBackend,
        fallbackBackend: (any EmbeddingBackend)?,
        store: EmbeddingsSidecarStore,
        forceRebuild: Bool
    ) async throws -> BookSidecarBuilder.Outcome {
        try await BookSidecarBuilder.buildIfNeeded(
            epubURL: entry.epubURL,
            libraryID: entry.id,
            backend: backend,
            fallbackBackend: fallbackBackend,
            store: store,
            forceRebuild: forceRebuild,
            aliasTerms: AliasDictionaryStore().read().terms
        )
    }

    /// Race `operation` against a `seconds` deadline. A watchdog
    /// `Task` sleeps for the deadline and then cancels the work
    /// task; if cancellation propagates (it does for the network /
    /// AFM `await`s that dominate this path) the operation throws
    /// `CancellationError`, which we translate to
    /// `IndexBuildTimedOut`. If the outer task is cancelled by the
    /// user clicking Cancel, the CancellationError passes through
    /// unchanged so the bulk-index loop can distinguish "this one
    /// book is stuck" from "stop the whole run."
    ///
    /// Generic in `T` so the helper isn't pinned to the Bool that
    /// `buildOneBook` returns — also lets the tests in
    /// `LibraryIndexBuilderTimeoutTests` exercise it with a Void
    /// dummy operation.
    static func runWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let work = Task<T, Error> {
            try await operation()
        }
        let watchdog = Task<Void, Never> {
            try? await Task.sleep(
                nanoseconds: UInt64(seconds * 1_000_000_000)
            )
            // Cancel the work task on timeout. If the work already
            // finished, `cancel()` is a no-op.
            work.cancel()
        }
        defer { watchdog.cancel() }

        do {
            // `withTaskCancellationHandler` is load-bearing for the
            // user's Cancel button. Without it, an unstructured
            // `Task<>` doesn't pick up cancellation from the
            // enclosing task — so when the indexer's outer Task is
            // cancelled, `work.value` keeps blocking until the work
            // task naturally finishes (which, on a stuck book, is
            // the entire problem we set out to fix). The onCancel
            // handler runs synchronously when the outer task is
            // cancelled and forwards the signal into the work +
            // watchdog tasks; the cooperative awaits inside the
            // build pipeline then bail, work.value throws, and the
            // outer indexer loop can break.
            return try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
                watchdog.cancel()
            }
        } catch is CancellationError {
            // Distinguish "user clicked Cancel on the outer Task"
            // from "watchdog cancelled this book." The outer-task
            // case is signalled by `Task.isCancelled` being true
            // here; the watchdog case leaves the outer task running.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw IndexBuildTimedOut(seconds: seconds)
        }
    }
}

