import XCTest
import Foundation
@testable import Humanist

/// Coverage for `LibraryConceptGraph.build` — the federated
/// concept rollup that powers the Concepts sidebar and (later)
/// the disagreement detector. Uses a tempdir-scoped
/// `EmbeddingsSidecarStore` so we never touch the real
/// Application Support directory.
@MainActor
final class LibraryConceptGraphTests: XCTestCase {

    private var tempDir: URL!
    private var store: EmbeddingsSidecarStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LibraryConceptGraphTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        store = EmbeddingsSidecarStore(baseDirectory: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Empty / degenerate

    func test_emptyLibrary_returnsEmptyGraph() {
        let graph = LibraryConceptGraph.build(
            libraryEntries: [], store: store
        )
        XCTAssertTrue(graph.concepts.isEmpty)
        XCTAssertTrue(graph.coOccurrence.isEmpty)
        XCTAssertEqual(graph.indexedBookCount, 0)
    }

    func test_bookWithoutSidecar_isSkipped() {
        let entry = makeEntry(title: "No Sidecar")
        let graph = LibraryConceptGraph.build(
            libraryEntries: [entry], store: store
        )
        XCTAssertEqual(graph.indexedBookCount, 0)
        XCTAssertTrue(graph.concepts.isEmpty)
    }

    func test_bookWithSidecarButNoEntities_isSkipped() {
        let entry = makeEntry(title: "No Entities")
        writeSidecar(for: entry, entities: nil)
        let graph = LibraryConceptGraph.build(
            libraryEntries: [entry], store: store
        )
        XCTAssertEqual(graph.indexedBookCount, 0)
    }

    // MARK: - Single book

    func test_singleBook_aggregatesPerConceptCoverage() {
        let entry = makeEntry(title: "Foucault Reader")
        let entities = BookEntityIndex(
            mentions: [
                "foucault": [
                    .init(chapterIdx: 0, paragraphIdx: 0),
                    .init(chapterIdx: 0, paragraphIdx: 1),
                    .init(chapterIdx: 2, paragraphIdx: 5),
                ],
                "discourse": [
                    .init(chapterIdx: 0, paragraphIdx: 0),
                ],
            ],
            displayNames: [
                "foucault": "Foucault",
                "discourse": "Discourse",
            ]
        )
        writeSidecar(for: entry, entities: entities)

        let graph = LibraryConceptGraph.build(
            libraryEntries: [entry], store: store
        )

        XCTAssertEqual(graph.indexedBookCount, 1)
        let foucault = try? XCTUnwrap(graph.concepts["foucault"])
        XCTAssertEqual(foucault?.totalMentions, 3)
        XCTAssertEqual(foucault?.bookCount, 1)
        XCTAssertEqual(foucault?.displayName, "Foucault")
        XCTAssertEqual(foucault?.coverage.first?.chapters, [0, 2])
    }

    // MARK: - Co-occurrence

    func test_coOccurrence_countsParagraphsWithBothEntities() {
        let entry = makeEntry(title: "Co-occurrence Book")
        // Both "foucault" and "discourse" share anchors at (0,0)
        // and (1,3) — two co-occurrences.
        // "foucault" + "power" share only (0,0) — one.
        let entities = BookEntityIndex(
            mentions: [
                "foucault": [
                    .init(chapterIdx: 0, paragraphIdx: 0),
                    .init(chapterIdx: 1, paragraphIdx: 3),
                    .init(chapterIdx: 2, paragraphIdx: 0),
                ],
                "discourse": [
                    .init(chapterIdx: 0, paragraphIdx: 0),
                    .init(chapterIdx: 1, paragraphIdx: 3),
                ],
                "power": [
                    .init(chapterIdx: 0, paragraphIdx: 0),
                ],
            ],
            displayNames: [
                "foucault": "Foucault",
                "discourse": "Discourse",
                "power": "Power",
            ]
        )
        writeSidecar(for: entry, entities: entities)

        // minEdgeCount = 1 so the foucault/power single-paragraph
        // edge survives and we can verify it.
        let graph = LibraryConceptGraph.build(
            libraryEntries: [entry], store: store, minEdgeCount: 1
        )

        XCTAssertEqual(
            graph.coOccurrence[.init("foucault", "discourse")], 2
        )
        XCTAssertEqual(
            graph.coOccurrence[.init("foucault", "power")], 1
        )
        XCTAssertEqual(
            graph.coOccurrence[.init("discourse", "power")], 1
        )
    }

    func test_edge_isCanonicalizedRegardlessOfArgumentOrder() {
        let a = LibraryConceptGraph.Edge("foucault", "discourse")
        let b = LibraryConceptGraph.Edge("discourse", "foucault")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func test_defaultMinEdgeCount_dropsSingletonEdges() {
        let entry = makeEntry(title: "Singleton-Edge Book")
        // Pair appears in exactly one paragraph — would be a
        // singleton edge that the default floor (2) should drop.
        let entities = BookEntityIndex(
            mentions: [
                "alpha": [.init(chapterIdx: 0, paragraphIdx: 0)],
                "beta": [.init(chapterIdx: 0, paragraphIdx: 0)],
            ],
            displayNames: ["alpha": "Alpha", "beta": "Beta"]
        )
        writeSidecar(for: entry, entities: entities)

        let graph = LibraryConceptGraph.build(
            libraryEntries: [entry], store: store
        )
        XCTAssertNil(graph.coOccurrence[.init("alpha", "beta")])
        // Concepts still get recorded — only the edge is filtered.
        XCTAssertNotNil(graph.concepts["alpha"])
        XCTAssertNotNil(graph.concepts["beta"])
    }

    // MARK: - Federation

    func test_multipleBooks_federateConceptCoverage() {
        let bookA = makeEntry(title: "Book A")
        let bookB = makeEntry(title: "Book B")
        writeSidecar(
            for: bookA,
            entities: BookEntityIndex(
                mentions: [
                    "foucault": [
                        .init(chapterIdx: 0, paragraphIdx: 0),
                        .init(chapterIdx: 0, paragraphIdx: 1),
                    ],
                ],
                displayNames: ["foucault": "Foucault"]
            )
        )
        writeSidecar(
            for: bookB,
            entities: BookEntityIndex(
                mentions: [
                    "foucault": [
                        .init(chapterIdx: 1, paragraphIdx: 0),
                    ],
                    "bourdieu": [
                        .init(chapterIdx: 2, paragraphIdx: 0),
                    ],
                ],
                displayNames: [
                    "foucault": "Michel Foucault",
                    "bourdieu": "Bourdieu",
                ]
            )
        )

        let graph = LibraryConceptGraph.build(
            libraryEntries: [bookA, bookB], store: store
        )

        XCTAssertEqual(graph.indexedBookCount, 2)
        let foucault = try? XCTUnwrap(graph.concepts["foucault"])
        XCTAssertEqual(foucault?.bookCount, 2)
        XCTAssertEqual(foucault?.totalMentions, 3)
        // Longer/more-cased display wins across books.
        XCTAssertEqual(foucault?.displayName, "Michel Foucault")
        // Coverage rows sorted by mentionCount desc, so Book A
        // (2 mentions) lands first.
        XCTAssertEqual(foucault?.coverage.first?.bookTitle, "Book A")
        XCTAssertEqual(foucault?.coverage.first?.mentionCount, 2)
        XCTAssertEqual(foucault?.coverage.last?.bookTitle, "Book B")
    }

    // MARK: - Query helpers

    func test_conceptsByBreadth_ordersBookCountThenMentionsThenName() {
        // breadth=2, mentions=5
        let big = ConceptInput(
            canonical: "big", display: "Big",
            books: [("Book A", 3), ("Book B", 2)]
        )
        // breadth=2, mentions=4 — same breadth, lower mentions
        let mid = ConceptInput(
            canonical: "mid", display: "Mid",
            books: [("Book A", 2), ("Book B", 2)]
        )
        // breadth=1
        let small = ConceptInput(
            canonical: "small", display: "Small",
            books: [("Book A", 10)]
        )
        let entries = synthesizeLibrary([big, mid, small])
        let graph = LibraryConceptGraph.build(
            libraryEntries: entries, store: store
        )
        let order = graph.conceptsByBreadth().map(\.canonical)
        XCTAssertEqual(order, ["big", "mid", "small"])
    }

    func test_related_returnsTopByCoOccurrence_excludingSelf() {
        let entry = makeEntry(title: "Related Book")
        let entities = BookEntityIndex(
            mentions: [
                "foucault": [
                    .init(chapterIdx: 0, paragraphIdx: 0),
                    .init(chapterIdx: 0, paragraphIdx: 1),
                    .init(chapterIdx: 0, paragraphIdx: 2),
                ],
                "discourse": [
                    .init(chapterIdx: 0, paragraphIdx: 0),
                    .init(chapterIdx: 0, paragraphIdx: 1),
                    .init(chapterIdx: 0, paragraphIdx: 2),
                ],
                "power": [
                    .init(chapterIdx: 0, paragraphIdx: 0),
                    .init(chapterIdx: 0, paragraphIdx: 1),
                ],
                "stray": [
                    .init(chapterIdx: 5, paragraphIdx: 5),
                ],
            ],
            displayNames: [
                "foucault": "Foucault", "discourse": "Discourse",
                "power": "Power", "stray": "Stray",
            ]
        )
        writeSidecar(for: entry, entities: entities)

        let graph = LibraryConceptGraph.build(
            libraryEntries: [entry], store: store
        )
        let related = graph.related(to: "foucault", limit: 5)
        // discourse=3, power=2, stray=0 (filtered by minEdgeCount).
        XCTAssertEqual(related.map(\.concept), ["discourse", "power"])
        XCTAssertEqual(related.first?.count, 3)
        XCTAssertFalse(related.contains { $0.concept == "foucault" })
    }

    // MARK: - Stopwords + aliases (Phase 2a)

    func test_stopwords_dropConceptsFromRollup() {
        let entry = makeEntry(title: "Stopwords Book")
        let entities = BookEntityIndex(
            mentions: [
                "new york": [.init(chapterIdx: 0, paragraphIdx: 0)],
                "foucault": [.init(chapterIdx: 0, paragraphIdx: 1)],
            ],
            displayNames: [
                "new york": "New York",
                "foucault": "Foucault",
            ]
        )
        writeSidecar(for: entry, entities: entities)

        let graph = LibraryConceptGraph.build(
            libraryEntries: [entry], store: store
        )
        XCTAssertNil(graph.concepts["new york"])
        XCTAssertNotNil(graph.concepts["foucault"])
    }

    func test_aliases_mergeSynonymousConceptsInOneBook() {
        let entry = makeEntry(title: "Aliases Book")
        // Both "america" and "united states" appear; expect them
        // to merge into the "united states" primary (per
        // ConceptAliases). mentionCount should sum.
        let entities = BookEntityIndex(
            mentions: [
                "america": [
                    .init(chapterIdx: 0, paragraphIdx: 0),
                    .init(chapterIdx: 1, paragraphIdx: 0),
                ],
                "united states": [
                    .init(chapterIdx: 2, paragraphIdx: 0),
                ],
            ],
            displayNames: [
                "america": "America",
                "united states": "United States",
            ]
        )
        writeSidecar(for: entry, entities: entities)

        let graph = LibraryConceptGraph.build(
            libraryEntries: [entry], store: store
        )
        XCTAssertNil(graph.concepts["america"])
        let primary = try? XCTUnwrap(graph.concepts["united states"])
        XCTAssertEqual(primary?.totalMentions, 3)
        XCTAssertEqual(primary?.coverage.first?.chapters, [0, 1, 2])
    }

    func test_aliases_canBeDisabled_viaApplyFiltersFlag() {
        let entry = makeEntry(title: "Filters Off Book")
        let entities = BookEntityIndex(
            mentions: [
                "new york": [.init(chapterIdx: 0, paragraphIdx: 0)],
                "america": [.init(chapterIdx: 0, paragraphIdx: 1)],
            ],
            displayNames: [
                "new york": "New York",
                "america": "America",
            ]
        )
        writeSidecar(for: entry, entities: entities)

        let graph = LibraryConceptGraph.build(
            libraryEntries: [entry], store: store, applyFilters: false
        )
        XCTAssertNotNil(graph.concepts["new york"])
        XCTAssertNotNil(graph.concepts["america"])
        XCTAssertNil(graph.concepts["united states"])
    }

    func test_significantConcepts_dropsSingleBookConcepts() {
        let bookA = makeEntry(title: "Book A")
        let bookB = makeEntry(title: "Book B")
        writeSidecar(
            for: bookA,
            entities: BookEntityIndex(
                mentions: [
                    "foucault": [.init(chapterIdx: 0, paragraphIdx: 0)],
                    "obscure": [.init(chapterIdx: 0, paragraphIdx: 1)],
                ],
                displayNames: ["foucault": "Foucault", "obscure": "Obscure"]
            )
        )
        writeSidecar(
            for: bookB,
            entities: BookEntityIndex(
                mentions: [
                    "foucault": [.init(chapterIdx: 0, paragraphIdx: 0)],
                ],
                displayNames: ["foucault": "Foucault"]
            )
        )
        let graph = LibraryConceptGraph.build(
            libraryEntries: [bookA, bookB], store: store
        )
        let significant = graph.significantConcepts()
            .map(\.canonical)
        XCTAssertEqual(significant, ["foucault"])
        // Full set still includes the obscure one for the
        // search_concept tool path.
        XCTAssertNotNil(graph.concepts["obscure"])
    }

    func test_presentationName_lowercasesAllCapsButPreservesMixedCase() {
        XCTAssertEqual(
            LibraryConceptGraph.presentationName("UNITED STATES"),
            "United States"
        )
        XCTAssertEqual(
            LibraryConceptGraph.presentationName("JESUS CHRIST"),
            "Jesus Christ"
        )
        // Mixed case proper nouns pass through untouched —
        // NLTagger gave us "Michel Foucault" because the source
        // text capitalized it correctly.
        XCTAssertEqual(
            LibraryConceptGraph.presentationName("Michel Foucault"),
            "Michel Foucault"
        )
        // Single-letter or empty edge cases shouldn't crash.
        XCTAssertEqual(LibraryConceptGraph.presentationName("X"), "X")
        XCTAssertEqual(LibraryConceptGraph.presentationName(""), "")
    }

    func test_displayName_isTitleCasedInTheBuiltGraph() {
        let entry = makeEntry(title: "All Caps Source")
        let entities = BookEntityIndex(
            mentions: ["foucault": [.init(chapterIdx: 0, paragraphIdx: 0)]],
            displayNames: ["foucault": "FOUCAULT"]
        )
        writeSidecar(for: entry, entities: entities)
        let graph = LibraryConceptGraph.build(
            libraryEntries: [entry], store: store
        )
        XCTAssertEqual(graph.concepts["foucault"]?.displayName, "Foucault")
    }

    // MARK: - Cache (Phase 2a)

    func test_cache_returnsSameInstanceOnRepeatCall() {
        let entry = makeEntry(title: "Cache Book")
        writeSidecar(
            for: entry,
            entities: BookEntityIndex(
                mentions: [
                    "foucault": [
                        .init(chapterIdx: 0, paragraphIdx: 0),
                    ],
                ],
                displayNames: ["foucault": "Foucault"]
            )
        )
        let cache = LibraryConceptGraphCache()
        let first = cache.graph(
            libraryEntries: [entry],
            backendIdentifier: "test.backend",
            store: store
        )
        XCTAssertTrue(cache.hasCache(
            libraryEntries: [entry],
            backendIdentifier: "test.backend",
            store: store
        ))
        let second = cache.graph(
            libraryEntries: [entry],
            backendIdentifier: "test.backend",
            store: store
        )
        // Concept dictionary identity isn't observable through
        // the public API, but the count + a sentinel value
        // round-trip identically.
        XCTAssertEqual(first.concepts.count, second.concepts.count)
        XCTAssertNotNil(second.concepts["foucault"])
    }

    func test_cache_invalidatesOnBackendChange() {
        let entry = makeEntry(title: "Backend-Switch Book")
        writeSidecar(
            for: entry,
            entities: BookEntityIndex(
                mentions: ["foucault": [.init(chapterIdx: 0, paragraphIdx: 0)]],
                displayNames: ["foucault": "Foucault"]
            )
        )
        let cache = LibraryConceptGraphCache()
        _ = cache.graph(
            libraryEntries: [entry],
            backendIdentifier: "backend.a",
            store: store
        )
        XCTAssertFalse(cache.hasCache(
            libraryEntries: [entry],
            backendIdentifier: "backend.b",
            store: store
        ))
    }

    // MARK: - Helpers

    private func makeEntry(title: String) -> LibraryEntry {
        let id = UUID()
        let epub = tempDir.appendingPathComponent("\(id.uuidString).epub")
        return LibraryEntry(
            id: id,
            epubURL: epub,
            title: title,
            languages: ["en"],
            addedAt: Date()
        )
    }

    private func writeSidecar(
        for entry: LibraryEntry,
        entities: BookEntityIndex?
    ) {
        let sidecar = EmbeddingsSidecar(
            schemaVersion: EmbeddingsSidecar.currentSchemaVersion,
            backendIdentifier: "test.backend",
            dimension: 1,
            paragraphs: [],
            hierarchy: nil,
            entities: entities,
            wasFallback: false
        )
        store.write(sidecar, for: entry.epubURL, libraryID: entry.id)
    }

    /// Compact shape for `synthesizeLibrary` — one concept, one
    /// display name, and a `(bookTitle, mentionCount)` distribution
    /// across books.
    private struct ConceptInput {
        let canonical: String
        let display: String
        let books: [(title: String, mentions: Int)]
    }

    /// Materializes a library where the same set of `ConceptInput`s
    /// is distributed across N synthesized books. Each book gets a
    /// fresh sidecar carrying only the concepts it should
    /// contribute, with `mentions` anchors at chapter 0.
    private func synthesizeLibrary(
        _ inputs: [ConceptInput]
    ) -> [LibraryEntry] {
        var byBook: [String: [(canonical: String, display: String, mentions: Int)]] = [:]
        for input in inputs {
            for book in input.books {
                byBook[book.title, default: []].append(
                    (input.canonical, input.display, book.mentions)
                )
            }
        }
        var entries: [LibraryEntry] = []
        for (title, items) in byBook {
            let entry = makeEntry(title: title)
            var mentions: [String: [BookEntityIndex.Anchor]] = [:]
            var displayNames: [String: String] = [:]
            for (i, item) in items.enumerated() {
                let anchors = (0..<item.mentions).map {
                    BookEntityIndex.Anchor(
                        chapterIdx: i, paragraphIdx: $0
                    )
                }
                mentions[item.canonical] = anchors
                displayNames[item.canonical] = item.display
            }
            writeSidecar(
                for: entry,
                entities: BookEntityIndex(
                    mentions: mentions, displayNames: displayNames
                )
            )
            entries.append(entry)
        }
        return entries
    }
}
