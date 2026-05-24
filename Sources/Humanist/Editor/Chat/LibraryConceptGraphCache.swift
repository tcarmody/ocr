import Foundation
import CryptoKit

/// Process-lifetime in-memory cache for `LibraryConceptGraph`.
/// The full rollup takes ~40s on a 2k-book library; rebuilding it
/// every time the user opens the Concepts sidebar would be a UX
/// disaster. The cache holds the most recently built graph alongside
/// its fingerprint and returns it directly on a fingerprint hit.
///
/// **In-memory only.** On process restart, the next request rebuilds
/// from sidecars. Persistent on-disk caching is the deferred
/// Schema-option-C work; we don't want to ship a new sidecar format
/// before we know the in-memory size / shape is stable.
///
/// Thread model: `@MainActor`-confined. The Concepts sidebar lives
/// on the main actor, and the build work itself runs synchronously
/// inside the cache call — callers that want async behavior should
/// wrap the call in `Task.detached` themselves.
@MainActor
final class LibraryConceptGraphCache {

    /// Process-wide singleton. The library catalog is a singleton
    /// (one `LibraryStore` per app launch), so the cache shape
    /// matches it. Tests construct their own instance to avoid
    /// state leak between cases.
    static let shared = LibraryConceptGraphCache()

    private struct CachedEntry {
        let fingerprint: String
        let graph: LibraryConceptGraph
        let builtAt: Date
        let buildDuration: TimeInterval
    }

    private var current: CachedEntry?

    init() {}

    /// Return the cached graph if its fingerprint matches the
    /// current library state, otherwise build a fresh one, cache
    /// it, and return that. `backendIdentifier` participates in
    /// the fingerprint because the per-book entity index changes
    /// shape when the user re-indexes against a different backend.
    func graph(
        libraryEntries: [LibraryEntry],
        backendIdentifier: String,
        store: EmbeddingsSidecarStore = EmbeddingsSidecarStore()
    ) -> LibraryConceptGraph {
        let fp = fingerprint(
            libraryEntries: libraryEntries,
            backendIdentifier: backendIdentifier,
            store: store
        )
        if let current, current.fingerprint == fp {
            return current.graph
        }
        let start = Date()
        let graph = LibraryConceptGraph.build(
            libraryEntries: libraryEntries, store: store
        )
        let elapsed = Date().timeIntervalSince(start)
        current = CachedEntry(
            fingerprint: fp,
            graph: graph,
            builtAt: Date(),
            buildDuration: elapsed
        )
        return graph
    }

    /// Drop the cached entry. Called from Settings → "Clear all
    /// indexes" and from tests.
    func invalidate() {
        current = nil
    }

    /// Last build's wall-clock duration. Exposed for the sidebar
    /// header so the user can see "Built in 38.2s" rather than
    /// staring at a spinner with no context.
    var lastBuildDuration: TimeInterval? {
        current?.buildDuration
    }

    /// True iff the cache currently holds a graph for the given
    /// `(library, backend)` shape. Lets the sidebar decide between
    /// "show cached graph immediately" vs "show progress UI while
    /// background build runs."
    func hasCache(
        libraryEntries: [LibraryEntry],
        backendIdentifier: String,
        store: EmbeddingsSidecarStore = EmbeddingsSidecarStore()
    ) -> Bool {
        guard let current else { return false }
        let fp = fingerprint(
            libraryEntries: libraryEntries,
            backendIdentifier: backendIdentifier,
            store: store
        )
        return current.fingerprint == fp
    }

    // MARK: - Fingerprint

    /// SHA-256 over (backendIdentifier, sorted (libraryID,
    /// sidecar-mtime, sidecar-size) tuples). Same shape as
    /// `FederatedIndexCache.fingerprint` so a backend change or a
    /// sidecar rewrite invalidates both caches consistently. We
    /// compute it independently rather than reusing the federated
    /// helper to avoid coupling the two cache lifecycles.
    private func fingerprint(
        libraryEntries: [LibraryEntry],
        backendIdentifier: String,
        store: EmbeddingsSidecarStore
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(backendIdentifier.utf8))

        struct Tuple {
            var id: UUID
            var mtime: Int64
            var size: Int64
        }
        var tuples: [Tuple] = []
        tuples.reserveCapacity(libraryEntries.count)
        let fm = FileManager.default
        for entry in libraryEntries {
            let candidates = store.readCandidateURLs(
                for: entry.epubURL, libraryID: entry.id
            )
            var mtime: Int64 = -1
            var size: Int64 = -1
            for url in candidates {
                guard let attrs = try? fm.attributesOfItem(atPath: url.path)
                else { continue }
                if let date = attrs[.modificationDate] as? Date {
                    mtime = Int64(date.timeIntervalSince1970)
                }
                if let s = attrs[.size] as? NSNumber {
                    size = s.int64Value
                }
                break
            }
            tuples.append(Tuple(id: entry.id, mtime: mtime, size: size))
        }
        tuples.sort { $0.id.uuidString < $1.id.uuidString }
        for tuple in tuples {
            var tuple = tuple
            withUnsafeBytes(of: &tuple) { hasher.update(bufferPointer: $0) }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
