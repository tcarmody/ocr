import Foundation
import AppKit
import AI
import EPUB
import Pipeline

/// R-EPUB-Import. Take existing EPUBs (already-edited books, books
/// converted from documents the user no longer has, books from other
/// sources) and bring them into the Humanist library: inject
/// paragraph anchors, copy to the configured Books folder, catalog
/// in `LibraryStore`, and build the federated-chat embedding sidecar.
///
/// Idempotent on re-import — already-anchored books pass through the
/// injector unchanged and the catalog entry updates in place rather
/// than duplicating.
///
/// v1 scope: anchor injection + cataloging + indexing. AFM
/// classification / metadata / coherence passes are deliberately
/// out of scope here — they layer on later by re-running the
/// imported book through the existing per-book pipelines. The
/// minimum-viable shape ("get it into the library so chat sees
/// it") is the load-bearing piece.
@MainActor
final class EPUBImporter: ObservableObject {

    enum Status: Equatable {
        case idle
        case running
        case completed
        case cancelled
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// 1-based "importing N of M". Drives the progress sheet's
    /// counter.
    @Published private(set) var current: Int = 0
    @Published private(set) var total: Int = 0
    @Published private(set) var currentTitle: String = ""
    /// Books that errored during import. UI shows these so the user
    /// can decide whether to investigate (often one bad EPUB; rest
    /// of the batch succeeds).
    @Published private(set) var failures: [Failure] = []
    /// Successfully-imported destination URLs in import order.
    @Published private(set) var imported: [URL] = []

    struct Failure: Identifiable {
        let id = UUID()
        let sourceURL: URL
        let error: String
    }

    enum ImportError: Error, LocalizedError {
        case sourceMissing(URL)
        case destinationConflict(String)
        case openFailed(underlying: Error)
        case saveFailed(underlying: Error)
        case repackFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let url):
                return "Source EPUB doesn't exist: \(url.lastPathComponent)"
            case .destinationConflict(let detail):
                return "Couldn't pick a destination filename: \(detail)"
            case .openFailed(let e):
                return "Couldn't open EPUB: \(e.localizedDescription)"
            case .saveFailed(let e):
                return "Couldn't save EPUB: \(e.localizedDescription)"
            case .repackFailed(let e):
                return "Couldn't repack EPUB: \(e.localizedDescription)"
            }
        }
    }

    private var task: Task<Void, Never>?

    init() {}

    deinit { task?.cancel() }

    /// Kick off a batch import. UI builds the `sources` list (from a
    /// NSOpenPanel multi-select); the importer owns the per-book
    /// orchestration + progress publishing.
    ///
    /// `indexBackend` is the resolved embedding backend the federated
    /// chat will use; passed through so the per-book sidecar gets
    /// built against the right vector space. Nil skips the indexing
    /// step (book still appears in the catalog; chat won't retrieve
    /// from it until a separate index pass runs).
    func start(
        sources: [URL],
        library: LibraryStore,
        indexBackend: (any EmbeddingBackend)?
    ) {
        guard status != .running else { return }
        status = .running
        current = 0
        total = sources.count
        currentTitle = ""
        failures = []
        imported = []
        let store = EmbeddingsSidecarStore()
        task = Task { [weak self] in
            for (idx, source) in sources.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self?.current = idx + 1
                    self?.currentTitle = source
                        .deletingPathExtension().lastPathComponent
                }
                do {
                    let result = try await Self.importOne(
                        source: source,
                        library: library,
                        backend: indexBackend,
                        sidecarStore: store
                    )
                    await MainActor.run {
                        self?.imported.append(result.destinationURL)
                    }
                } catch {
                    await MainActor.run {
                        self?.failures.append(Failure(
                            sourceURL: source,
                            error: error.localizedDescription
                        ))
                    }
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.status = Task.isCancelled ? .cancelled : .completed
                self.currentTitle = ""
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Per-book orchestration

    /// Per-book result. Surfaces the destination URL for the catalog
    /// row + caller's success accounting.
    private struct ImportResult {
        let destinationURL: URL
    }

    /// Open + anchor + save + repack + catalog + index in one shot.
    /// Pure async; no UI work. The caller (`start`) does the
    /// main-actor progress publishing around each call.
    private static func importOne(
        source: URL,
        library: LibraryStore,
        backend: (any EmbeddingBackend)?,
        sidecarStore: EmbeddingsSidecarStore
    ) async throws -> ImportResult {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ImportError.sourceMissing(source)
        }

        // 1. Open via the EPUBBook in-memory model. Unzips into a
        // temp directory; the book owns its lifecycle.
        let book: EPUBBook
        do {
            book = try EPUBBook.open(epubURL: source)
        } catch {
            throw ImportError.openFailed(underlying: error)
        }

        // 2. Inject paragraph anchors. Idempotent — already-anchored
        // books pass through unchanged. Marks touched resources
        // dirty so the saver flushes them.
        _ = ParagraphAnchorInjector.injectAnchors(in: book)

        // 3. Save dirty resources back into the working directory.
        // No-ops cleanly when nothing changed (e.g. re-import).
        do {
            try EPUBBookSaver().save(book)
        } catch {
            throw ImportError.saveFailed(underlying: error)
        }

        // 4. Pick a destination URL inside the library's Books
        // folder. Collisions resolve via `(2)` / `(3)` etc.
        let destination = try await MainActor.run {
            try Self.destinationURL(for: source, library: library)
        }

        // 5. Repack working directory → destination EPUB.
        do {
            try EPUBRepacker().repack(
                workingDirectory: book.workingDirectory,
                to: destination
            )
        } catch {
            throw ImportError.repackFailed(underlying: error)
        }

        // 6. Catalog. Title + language come from the OPF (resolved
        // via the in-memory book's metadata). `recordConversion`
        // dedupes by canonical destination URL, so a re-import that
        // lands at the same path updates the existing row.
        let title = book.displayTitle
        let languages = book.metadata.language
            .flatMap { $0.isEmpty ? nil : [$0] } ?? []
        await MainActor.run {
            library.recordConversion(
                epubURL: destination,
                title: title,
                languages: languages
            )
        }

        // 7. Build the embedding sidecar so library chat sees the
        // book immediately. Skipped when no backend is available —
        // the catalog row stays, just without retrieval-time recall.
        if let backend {
            _ = try await BookSidecarBuilder.buildIfNeeded(
                epubURL: destination,
                backend: backend,
                store: sidecarStore,
                forceRebuild: false
            )
        }

        return ImportResult(destinationURL: destination)
    }

    // MARK: - Destination resolution

    /// Resolve the destination URL inside the library's Books
    /// directory. Honors the user's configured output root when
    /// set; otherwise falls back to
    /// `~/Documents/Humanist Library/Books/` (auto-created) so the
    /// user always knows where to look for their imports.
    ///
    /// Filename comes from the source EPUB's basename. Collisions
    /// resolve by appending `(2)`, `(3)`, etc. — same posture as
    /// `EPUBBook.nextAvailableHref`. Re-importing the exact same
    /// source overwrites cleanly (the original destination's
    /// catalog row gets updated rather than duplicated), so the
    /// collision check only fires for *different* sources sharing
    /// a basename.
    private static func destinationURL(
        for source: URL,
        library: LibraryStore
    ) throws -> URL {
        let booksDirectory = booksLibraryDirectory()
        try? FileManager.default.createDirectory(
            at: booksDirectory, withIntermediateDirectories: true
        )

        let stem = source.deletingPathExtension().lastPathComponent
        let base = booksDirectory
            .appendingPathComponent(stem)
            .appendingPathExtension("epub")

        // If `base` already corresponds to an existing library
        // entry pointing at the *same* source, re-use it — that's
        // the idempotent re-import case. Compare canonical paths
        // since the library stores canonical URLs.
        let baseCanonical = base.canonicalForFile
        if library.entries.contains(where: {
            $0.epubURL.canonicalForFile == baseCanonical
        }) {
            return base
        }

        // Otherwise resolve a collision-free path.
        if !FileManager.default.fileExists(atPath: base.path) {
            return base
        }
        for i in 2..<1000 {
            let candidate = booksDirectory
                .appendingPathComponent("\(stem) (\(i))")
                .appendingPathExtension("epub")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw ImportError.destinationConflict(
            "exhausted suffix range for \(stem)"
        )
    }

    /// Root directory for imported (and converted) EPUBs. Honors
    /// the user's configured conversion output root when set;
    /// otherwise lands in `~/Documents/Humanist Library/Books/`.
    /// The fallback is deliberately visible to the user — hiding
    /// imports under Application Support would make them hard to
    /// find when the user later wants to manage the files directly.
    private static func booksLibraryDirectory() -> URL {
        if let root = ConversionOutputResolver.currentRoot() {
            return root.appendingPathComponent(
                ConversionOutputSubfolder.books, isDirectory: true
            )
        }
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return documents
            .appendingPathComponent("Humanist Library", isDirectory: true)
            .appendingPathComponent("Books", isDirectory: true)
    }
}
