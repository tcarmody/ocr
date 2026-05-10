import Foundation
import AI
import EPUB

/// Bulk-index every book in the library so library-scope chat has
/// something to retrieve from. Each book gets its embedding +
/// hierarchy + entity sidecar built (or rebuilt if the persisted
/// backend doesn't match the one selected in Settings).
///
/// This is the explicit alternative to "open every book's chat
/// pane once" — necessary on first use of library chat after
/// flipping backends, and useful any time the user wants to refresh
/// the federation in one shot.
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
        skippedExistingCount = 0
        let store = EmbeddingsSidecarStore()
        let snapshot = entries
        task = Task { [weak self] in
            for (idx, entry) in snapshot.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self?.current = idx + 1
                    self?.currentBookTitle = entry.title
                }
                do {
                    let didBuild = try await Self.buildOneBook(
                        entry: entry, backend: backend,
                        store: store, forceRebuild: forceRebuild
                    )
                    if !didBuild {
                        await MainActor.run { self?.skippedExistingCount += 1 }
                    }
                } catch {
                    await MainActor.run {
                        self?.failures.append(
                            (title: entry.title, error: error.localizedDescription)
                        )
                    }
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.status = Task.isCancelled ? .cancelled : .completed
                self.currentBookTitle = ""
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Build (or skip) a single book's sidecar. Returns true if a
    /// fresh build ran; false if the cached sidecar already matched
    /// the requested backend and was non-empty.
    private static func buildOneBook(
        entry: LibraryEntry,
        backend: any EmbeddingBackend,
        store: EmbeddingsSidecarStore,
        forceRebuild: Bool
    ) async throws -> Bool {
        // Cache check first — opening the EPUB is the heavy step;
        // we skip it entirely when the persisted sidecar matches
        // and is non-empty.
        if !forceRebuild,
           let existing = store.read(for: entry.epubURL),
           existing.backendIdentifier == backend.identifier,
           existing.dimension == backend.dimension,
           !existing.paragraphs.isEmpty {
            return false
        }
        // Open the book on disk. EPUBBook.open unzips into a temp
        // directory; the throwaway book is released at scope exit
        // and the temp dir cleaned by its deinit.
        let book = try EPUBBook.open(epubURL: entry.epubURL)
        var sidecar = store.read(for: entry.epubURL)
            ?? EmbeddingsSidecar.empty(
                backend: backend.identifier,
                dimension: backend.dimension
            )
        if forceRebuild
            || sidecar.backendIdentifier != backend.identifier
            || sidecar.dimension != backend.dimension {
            sidecar = EmbeddingsSidecar.empty(
                backend: backend.identifier,
                dimension: backend.dimension
            )
        }
        _ = try await BookEmbeddingIndex.build(
            for: book, backend: backend, cache: &sidecar
        )
        sidecar.hierarchy = BookHierarchyIndex.build(from: book)
        sidecar.entities = BookEntityIndex.build(from: book)
        store.write(sidecar, for: entry.epubURL)
        return true
    }
}
