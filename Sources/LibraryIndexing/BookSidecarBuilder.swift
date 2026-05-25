import Foundation
import AI
import EPUB

/// Build a single book's embedding + hierarchy + entity sidecar.
/// Extracted from `LibraryIndexBuilder` so both the bulk-index
/// pipeline (Humanist app's @MainActor wrapper), the per-book
/// import path (`EPUBImporter`), and the headless `humanist-cli
/// reindex` subcommand can build the same sidecar shape without
/// duplicating the cache / backend / EPUB-open machinery.
///
/// Takes `libraryID` so the sidecar is keyed by the catalog
/// entry's UUID rather than the EPUB's path SHA — UUIDs survive
/// rename / move, paths don't. The file lands under
/// `~/Library/Application Support/Humanist/Embeddings/<uuid>.emb`
/// (always local; embeddings don't participate in cross-Mac sync).
/// nil libraryID means an uncataloged book — the store falls
/// back to legacy SHA-keyed storage in the same directory.
public enum BookSidecarBuilder {
    /// Outcome from a single sidecar build. `skipped` means the
    /// persisted sidecar already matched the requested backend
    /// (or the fallback's, if a fallback build was previously
    /// recorded). `built` means one or both backends were exercised
    /// and a fresh sidecar landed.
    public enum Outcome: Sendable {
        case skipped
        /// `usedFallback` is true when the primary backend threw and
        /// the fallback build succeeded. `primaryError` carries the
        /// localized description of the primary failure so the
        /// caller can surface "this book fell back because: X."
        case built(usedFallback: Bool, primaryError: String?)
    }

    /// `aliasTerms` are user-curated concept seeds (from the app's
    /// `AliasDictionary`) that `BookEntityIndex.build` folds into
    /// the index alongside NER + statistical concepts. Optional so
    /// CLI re-index paths that don't load the alias dictionary can
    /// continue with empty (NER + statistical only).
    public static func buildIfNeeded(
        epubURL: URL,
        libraryID: UUID?,
        backend: any EmbeddingBackend,
        fallbackBackend: (any EmbeddingBackend)? = nil,
        store: EmbeddingsSidecarStore,
        forceRebuild: Bool,
        aliasTerms: Set<String> = []
    ) async throws -> Outcome {
        // Cache check first — opening the EPUB is the heavy step;
        // we skip it when the persisted sidecar matches either the
        // requested backend or a previous fallback build. The latter
        // is the post-fallback-success case where the user re-runs
        // bulk-index: we'd rather keep the Apple sidecar (which
        // works) than retry Gemini and fail again. To force a
        // primary-backend retry, the user passes `forceRebuild`.
        if !forceRebuild,
           let existing = store.read(for: epubURL, libraryID: libraryID),
           sidecarMatches(
               existing, primary: backend, fallback: fallbackBackend
           ),
           !existing.paragraphs.isEmpty {
            return .skipped
        }
        // Open the book on disk. EPUBBook.open unzips into a temp
        // directory; the throwaway book is released at scope exit
        // and the temp dir cleaned by its deinit.
        let book = try EPUBBook.open(epubURL: epubURL)
        var sidecar = store.read(for: epubURL, libraryID: libraryID)
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

        // Try the primary backend. On any non-cancellation error,
        // retry the whole book with the fallback when one's
        // configured. Cancellation propagates unchanged — the user
        // hit Cancel, they don't want us silently switching backends
        // and continuing.
        do {
            _ = try await BookEmbeddingIndex.build(
                for: book, backend: backend, cache: &sidecar
            )
            sidecar.hierarchy = BookHierarchyIndex.build(from: book)
            sidecar.entities = BookEntityIndex.build(
                from: book, aliasTerms: aliasTerms
            )
            // Primary succeeded — clear any sticky fallback flag a
            // prior build left behind, so the bulk-index skip logic
            // treats this sidecar as a goal-state primary build.
            sidecar.wasFallback = false
            store.write(sidecar, for: epubURL, libraryID: libraryID)
            return .built(usedFallback: false, primaryError: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch let primaryError {
            guard let fallback = fallbackBackend else {
                throw primaryError
            }
            // Reset the in-flight sidecar to the fallback's vector
            // space and retry. The fallback (typically Apple's
            // on-device NLEmbedding) has its own dimension, so
            // any partial work the primary built is discarded.
            sidecar = EmbeddingsSidecar.empty(
                backend: fallback.identifier,
                dimension: fallback.dimension
            )
            _ = try await BookEmbeddingIndex.build(
                for: book, backend: fallback, cache: &sidecar
            )
            sidecar.hierarchy = BookHierarchyIndex.build(from: book)
            sidecar.entities = BookEntityIndex.build(
                from: book, aliasTerms: aliasTerms
            )
            // Mark so the next bulk re-index skips this book
            // instead of retrying a primary that already errored.
            // Cleared automatically the next time primary succeeds.
            sidecar.wasFallback = true
            store.write(sidecar, for: epubURL, libraryID: libraryID)
            return .built(
                usedFallback: true,
                primaryError: primaryError.localizedDescription
            )
        }
    }

    /// True when `sidecar` already records the goal state — either
    /// a primary-backend build, or a known-failure fallback build
    /// marked sticky via `wasFallback`. The fallback branch is
    /// gated on the flag (not just identifier+dimension) so a
    /// legacy Apple-NL sidecar from a pre-Gemini backend choice
    /// is treated as an upgrade candidate, not a sticky failure.
    /// If the primary still fails for a legacy book the fallback
    /// path kicks in again and re-saves with the flag set, so the
    /// next re-index skips it.
    private static func sidecarMatches(
        _ sidecar: EmbeddingsSidecar,
        primary: any EmbeddingBackend,
        fallback: (any EmbeddingBackend)?
    ) -> Bool {
        if sidecar.backendIdentifier == primary.identifier,
           sidecar.dimension == primary.dimension {
            return true
        }
        if sidecar.wasFallback,
           let fallback,
           sidecar.backendIdentifier == fallback.identifier,
           sidecar.dimension == fallback.dimension {
            return true
        }
        return false
    }
}
