import Foundation
import EPUB

/// Federated concept graph across the library. Sits on top of
/// `LibraryEntityIndex` and adds two things the per-entity anchor
/// list can't express:
///
///  * **Per-concept book coverage** — how many anchors each book
///    contributes to a concept, plus which chapters those anchors
///    live in. Powers the Concepts sidebar's bar-chart relevance
///    view ("which books most engage with phenomenology?") without
///    any extra extraction work.
///  * **Pairwise co-occurrence** — count of paragraphs across the
///    library where two distinct concepts appear together. Powers
///    the "related concepts" row in the Concepts UI and, downstream,
///    the candidate-selection pass of the Disagreement detector
///    (Phase 4 of R-Chat-Cross-Corpus).
///
/// Built by **inverting** each book's existing
/// `BookEntityIndex.mentions` table (entity → [anchor]) into a
/// transient (anchor → [entity]) view, then folding pairs from
/// each anchor's entity set into the federated co-occurrence map.
/// No NER at federation time — entirely map manipulation over data
/// the per-book sidecar already extracted.
///
/// Constraint: only entities NLTagger caught at per-book index time
/// participate. Anything missed stays missed until that book is
/// re-indexed. Acceptable for v1; the user-facing concept browser
/// makes gaps visible naturally and a re-index closes them.
struct LibraryConceptGraph: Sendable {

    /// One book's contribution to a single concept. `mentionCount`
    /// is the number of distinct paragraph anchors in this book
    /// that mention the concept; `chapters` is the set those
    /// anchors live in, useful for the detail-view "appears in
    /// chapters 3, 7, 12" badge.
    struct BookCoverage: Sendable, Equatable, Hashable {
        let epubURL: URL
        let bookTitle: String
        let mentionCount: Int
        let chapters: Set<Int>
    }

    /// Aggregate stats for a single canonical concept across every
    /// book that mentions it. `coverage` is sorted by `mentionCount`
    /// descending so the bar-chart consumer can render directly
    /// without re-sorting.
    struct ConceptStats: Sendable, Equatable {
        let canonical: String
        let displayName: String
        let totalMentions: Int
        let bookCount: Int
        let coverage: [BookCoverage]
    }

    /// Undirected pair of canonical concept names. The constructor
    /// canonicalizes ordering so `Edge(a, b)` and `Edge(b, a)` hash
    /// equal — co-occurrence is symmetric and we want a single
    /// bucket per pair.
    struct Edge: Sendable, Hashable {
        let a: String
        let b: String

        init(_ x: String, _ y: String) {
            if x <= y {
                self.a = x
                self.b = y
            } else {
                self.a = y
                self.b = x
            }
        }
    }

    /// Canonical concept name → aggregate stats. Insertion order
    /// is undefined; callers that need a sorted list (the sidebar)
    /// sort by their chosen criterion at render time.
    let concepts: [String: ConceptStats]
    /// Undirected pair → number of paragraphs (across the entire
    /// library) where both concepts appear together. Only pairs
    /// with count ≥ `minEdgeCount` are retained to keep the map
    /// tractable; singletons would balloon the dictionary without
    /// carrying useful signal.
    let coOccurrence: [Edge: Int]
    /// Number of books that contributed at least one concept to
    /// the graph. Surfaced in the sidebar header so the user can
    /// see when the corpus grew but the graph hasn't been rebuilt.
    let indexedBookCount: Int

    init(
        concepts: [String: ConceptStats],
        coOccurrence: [Edge: Int],
        indexedBookCount: Int
    ) {
        self.concepts = concepts
        self.coOccurrence = coOccurrence
        self.indexedBookCount = indexedBookCount
    }

    // MARK: - Building

    /// Default edge floor — drop pairs that only ever co-occur once
    /// across the entire library. They're almost always noise
    /// (one-off NLTagger false positives that happened to land in
    /// the same paragraph as a real entity) and they dominate the
    /// dictionary size at scale.
    static let defaultMinEdgeCount: Int = 2

    /// Fold every book's per-paragraph entity sets into the
    /// federated concept stats + co-occurrence map. `store` is
    /// injectable so tests can use a tempdir-scoped sidecar store.
    static func build(
        libraryEntries: [LibraryEntry],
        store: EmbeddingsSidecarStore = EmbeddingsSidecarStore(),
        minEdgeCount: Int = defaultMinEdgeCount
    ) -> LibraryConceptGraph {
        // Per-concept aggregation across books. Keyed by canonical;
        // value carries each contributing book's coverage row, the
        // running totalMentions sum, and the best display form
        // seen so far (longer / more-cased wins).
        struct ConceptAccumulator {
            var displayName: String
            var totalMentions: Int
            var coverage: [BookCoverage]
        }
        var concepts: [String: ConceptAccumulator] = [:]
        var coOccurrence: [Edge: Int] = [:]
        var indexedBookCount = 0

        for entry in libraryEntries {
            guard let sidecar = store.read(
                    for: entry.epubURL, libraryID: entry.id
                  ),
                  let book = sidecar.entities,
                  !book.mentions.isEmpty
            else { continue }
            indexedBookCount += 1

            // Step 1: invert this book's `entity → [anchor]` table
            // into `anchor → Set<entity>`. Sets dedupe entities that
            // happen to repeat within a paragraph; the per-book
            // builder already dedupes via last-anchor check, so the
            // Set form is a defense rather than a load-bearing
            // optimization.
            var perAnchor: [BookEntityIndex.Anchor: Set<String>] = [:]
            var perConceptInBook: [String: (count: Int, chapters: Set<Int>)] = [:]
            for (canonical, anchors) in book.mentions {
                var chaptersForConcept: Set<Int> = []
                for anchor in anchors {
                    perAnchor[anchor, default: []].insert(canonical)
                    chaptersForConcept.insert(anchor.chapterIdx)
                }
                perConceptInBook[canonical] = (
                    anchors.count, chaptersForConcept
                )
            }

            // Step 2: contribute this book's per-concept coverage
            // rows to the federated map.
            for (canonical, stats) in perConceptInBook {
                let display = book.displayNames[canonical] ?? canonical
                let row = BookCoverage(
                    epubURL: entry.epubURL,
                    bookTitle: entry.title,
                    mentionCount: stats.count,
                    chapters: stats.chapters
                )
                if var acc = concepts[canonical] {
                    acc.totalMentions += stats.count
                    acc.coverage.append(row)
                    if Self.scoreDisplay(display)
                        > Self.scoreDisplay(acc.displayName) {
                        acc.displayName = display
                    }
                    concepts[canonical] = acc
                } else {
                    concepts[canonical] = ConceptAccumulator(
                        displayName: display,
                        totalMentions: stats.count,
                        coverage: [row]
                    )
                }
            }

            // Step 3: walk the inverted per-anchor map and bump
            // every distinct pair's edge count. O(k²) per paragraph
            // where k = entities in that paragraph; in practice k
            // is small (< 10) so the quadratic blow-up never bites.
            for (_, entities) in perAnchor where entities.count >= 2 {
                let sorted = entities.sorted()
                for i in 0..<sorted.count {
                    for j in (i + 1)..<sorted.count {
                        let edge = Edge(sorted[i], sorted[j])
                        coOccurrence[edge, default: 0] += 1
                    }
                }
            }
        }

        // Materialize the final stats: sort each concept's coverage
        // by mentionCount desc, count books, drop edges below the
        // floor.
        var finalConcepts: [String: ConceptStats] = [:]
        finalConcepts.reserveCapacity(concepts.count)
        for (canonical, acc) in concepts {
            let sortedCoverage = acc.coverage.sorted {
                if $0.mentionCount != $1.mentionCount {
                    return $0.mentionCount > $1.mentionCount
                }
                return $0.bookTitle < $1.bookTitle
            }
            finalConcepts[canonical] = ConceptStats(
                canonical: canonical,
                displayName: acc.displayName,
                totalMentions: acc.totalMentions,
                bookCount: sortedCoverage.count,
                coverage: sortedCoverage
            )
        }
        let filteredEdges = coOccurrence.filter { $0.value >= minEdgeCount }

        return LibraryConceptGraph(
            concepts: finalConcepts,
            coOccurrence: filteredEdges,
            indexedBookCount: indexedBookCount
        )
    }

    private static func scoreDisplay(_ s: String) -> Int {
        let uppers = s.filter(\.isUppercase).count
        return uppers * 10 + s.count
    }

    // MARK: - Querying

    /// Concepts sorted by `bookCount` descending — the natural
    /// default for the sidebar's "broadly-discussed first" ordering.
    /// Ties broken by `totalMentions` desc, then `displayName` asc
    /// so the list is deterministic across rebuilds.
    func conceptsByBreadth() -> [ConceptStats] {
        concepts.values.sorted {
            if $0.bookCount != $1.bookCount {
                return $0.bookCount > $1.bookCount
            }
            if $0.totalMentions != $1.totalMentions {
                return $0.totalMentions > $1.totalMentions
            }
            return $0.displayName < $1.displayName
        }
    }

    /// Top `limit` related concepts for `canonical`, ranked by raw
    /// co-occurrence count desc. Filters out the self-edge (which
    /// can't appear given `Edge`'s a≠b construction, but the guard
    /// costs nothing).
    func related(
        to canonical: String, limit: Int = 8
    ) -> [(concept: String, count: Int)] {
        var hits: [(String, Int)] = []
        for (edge, count) in coOccurrence {
            let other: String?
            if edge.a == canonical { other = edge.b }
            else if edge.b == canonical { other = edge.a }
            else { other = nil }
            if let other, other != canonical {
                hits.append((other, count))
            }
        }
        return hits
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }
}
