import Foundation
import LibraryIndexing
import EPUB

/// Federated named-entity index across the user's library. Each
/// per-book `BookEntityIndex` contributes its `name → [anchor]`
/// table; the federated map keys by canonical name and unions
/// every book's anchors with the source book attached.
///
/// Supports two query shapes the embedding cosine path can't:
///
///  * **Exhaustive enumeration** — "every paragraph mentioning
///    Foucault across my library": look up the entity, get the
///    full anchor list (potentially hundreds; the retriever caps).
///  * **Set queries** — "books mentioning both Foucault and
///    Bourdieu": fall out as set intersections on the per-entity
///    anchor lists, grouped by `epubURL`.
///
/// Built lazily when the chat enters library scope; held in memory
/// until the backend changes (which forces an embedding-index
/// rebuild and is the natural moment to flush the entity index too).
struct LibraryEntityIndex: Sendable {

    /// One library-wide paragraph anchor. Carries the source book
    /// so retrieval hits can render `[book:N chapter:M]` citations
    /// alongside the existing embedding-side hits.
    struct LibraryAnchor: Sendable, Equatable, Hashable {
        let epubURL: URL
        let bookTitle: String
        let chapterIdx: Int
        let paragraphIdx: Int
    }

    /// Canonical name → every anchor across the library. Empty
    /// list when an entity is in the table but happens to have no
    /// anchors — shouldn't occur in practice; defended for safety.
    let mentions: [String: [LibraryAnchor]]
    /// Canonical name → preferred display form. Picks the longest
    /// / most-cased version seen across all books.
    let displayNames: [String: String]
    /// Books whose sidecar carried an entity index (vs ones
    /// indexed with R-Chat-Embeddings before entity extraction
    /// existed). Surfaced in the chat-pane status row.
    let indexedBookCount: Int

    init(
        mentions: [String: [LibraryAnchor]],
        displayNames: [String: String],
        indexedBookCount: Int
    ) {
        self.mentions = mentions
        self.displayNames = displayNames
        self.indexedBookCount = indexedBookCount
    }

    // MARK: - Building

    /// Walk the catalog, load each book's sidecar, fold its entity
    /// index into the federated map. Books with no sidecar or no
    /// entity section contribute nothing — they get re-indexed on
    /// next chat-pane open and join the federation on the build
    /// after that.
    static func build(
        libraryEntries: [LibraryEntry],
        store: EmbeddingsSidecarStore = EmbeddingsSidecarStore()
    ) -> LibraryEntityIndex {
        var mentions: [String: [LibraryAnchor]] = [:]
        var displayNames: [String: String] = [:]
        var indexed = 0
        for entry in libraryEntries {
            guard let sidecar = store.read(
                    for: entry.epubURL, libraryID: entry.id
                  ),
                  let book = sidecar.entities else { continue }
            indexed += 1
            for (canonical, anchors) in book.mentions {
                let federated = anchors.map {
                    LibraryAnchor(
                        epubURL: entry.epubURL,
                        bookTitle: entry.title,
                        chapterIdx: $0.chapterIdx,
                        paragraphIdx: $0.paragraphIdx
                    )
                }
                mentions[canonical, default: []].append(contentsOf: federated)
            }
            for (canonical, display) in book.displayNames {
                let existing = displayNames[canonical] ?? ""
                if scoreDisplay(display) > scoreDisplay(existing) {
                    displayNames[canonical] = display
                }
            }
        }
        return LibraryEntityIndex(
            mentions: mentions,
            displayNames: displayNames,
            indexedBookCount: indexed
        )
    }

    private static func scoreDisplay(_ s: String) -> Int {
        let uppers = s.filter(\.isUppercase).count
        return uppers * 10 + s.count
    }

    // MARK: - Querying

    /// Detect entities in `query` and return canonical keys present
    /// in this index. Order: most-mentioned across the library
    /// first.
    func entitiesMatching(query: String) -> [String] {
        let detected = EntityExtractor.extract(from: query).map(\.0)
        let unique = Array(Set(detected))
        return unique
            .filter { mentions[$0] != nil }
            .sorted {
                let lhs = mentions[$0]?.count ?? 0
                let rhs = mentions[$1]?.count ?? 0
                return lhs > rhs
            }
    }

    /// Library-wide anchors mentioning `canonical`.
    func anchors(for canonical: String) -> [LibraryAnchor] {
        mentions[canonical] ?? []
    }

    /// Books that mention `canonical` at least once. Used by the
    /// set-query path ("books that mention both X and Y") via
    /// straightforward set intersection on the caller side.
    func books(mentioning canonical: String) -> Set<URL> {
        Set((mentions[canonical] ?? []).map(\.epubURL))
    }
}
