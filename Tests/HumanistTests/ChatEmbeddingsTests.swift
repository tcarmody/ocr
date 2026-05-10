import XCTest
@testable import Humanist
@testable import AI

/// Unit tests for the chat embedding pipeline: paragraph extraction,
/// cosine math, sidecar round-tripping, and RRF fusion.
///
/// Backend integration (NLEmbedding actually returning useful
/// vectors) isn't covered here — that's manual / end-to-end. These
/// tests pin the math so a refactor doesn't silently break ranking.
final class ChatEmbeddingsTests: XCTestCase {

    // MARK: - ParagraphExtractor

    func test_paragraph_extractor_pulls_p_h_and_li_blocks() {
        let xhtml = """
        <html><body>
        <h1>Chapter Title</h1>
        <p>First paragraph of body text.</p>
        <p>Second paragraph with <em>emphasis</em> and a <a href="#x">link</a>.</p>
        <ul>
          <li>Bullet one</li>
          <li>Bullet two</li>
        </ul>
        </body></html>
        """
        let paragraphs = ParagraphExtractor.paragraphs(in: xhtml)
        XCTAssertEqual(paragraphs.count, 5)
        XCTAssertEqual(paragraphs[0], "Chapter Title")
        XCTAssertEqual(paragraphs[1], "First paragraph of body text.")
        XCTAssertEqual(paragraphs[2], "Second paragraph with emphasis and a link.")
        XCTAssertEqual(paragraphs[3], "Bullet one")
        XCTAssertEqual(paragraphs[4], "Bullet two")
    }

    func test_paragraph_extractor_drops_empty_blocks() {
        let xhtml = "<p></p><p>real</p><p>   </p><p>x</p>"
        let paragraphs = ParagraphExtractor.paragraphs(in: xhtml)
        // Empty-string and whitespace-only paragraphs are dropped;
        // single-character "x" is also dropped (count >= 2 cutoff).
        XCTAssertEqual(paragraphs, ["real"])
    }

    func test_paragraph_extractor_decodes_named_entities() {
        let xhtml = "<p>Foo &amp; bar &lt;tag&gt; with &quot;quotes&quot;.</p>"
        let paragraphs = ParagraphExtractor.paragraphs(in: xhtml)
        XCTAssertEqual(paragraphs, [#"Foo & bar <tag> with "quotes"."#])
    }

    func test_paragraph_extractor_hash_changes_with_text() {
        let a = ParagraphExtractor.hash("hello")
        let b = ParagraphExtractor.hash("hello")
        let c = ParagraphExtractor.hash("hello!")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Cosine

    func test_cosine_identical_vectors_returns_one() {
        let v: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(BookEmbeddingIndex.cosine(v, v), 1.0, accuracy: 1e-6)
    }

    func test_cosine_orthogonal_vectors_returns_zero() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        XCTAssertEqual(BookEmbeddingIndex.cosine(a, b), 0, accuracy: 1e-6)
    }

    func test_cosine_handles_zero_vector_gracefully() {
        let zero: [Float] = [0, 0, 0]
        let v: [Float] = [1, 2, 3]
        // Implementation falls back to 0 when one norm is zero —
        // the alternative (NaN) would propagate into the ranking
        // sort and break it.
        XCTAssertEqual(BookEmbeddingIndex.cosine(zero, v), 0)
        XCTAssertEqual(BookEmbeddingIndex.cosine(v, zero), 0)
    }

    func test_cosine_mismatched_dimensions_returns_zero() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [1, 2]
        XCTAssertEqual(BookEmbeddingIndex.cosine(a, b), 0)
    }

    // MARK: - Sidecar

    func test_sidecar_round_trip_preserves_vectors() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("humanist-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EmbeddingsSidecarStore(baseDirectory: dir)
        let payload = EmbeddingsSidecar(
            schemaVersion: EmbeddingsSidecar.currentSchemaVersion,
            backendIdentifier: "test.backend",
            dimension: 3,
            paragraphs: [
                .init(chapterIdx: 0, paragraphIdx: 1, textHash: "abc", vector: [0.1, 0.2, 0.3]),
                .init(chapterIdx: 1, paragraphIdx: 0, textHash: "def", vector: [0.4, 0.5, 0.6]),
            ],
            hierarchy: nil,
            entities: nil
        )
        let url = URL(fileURLWithPath: "/tmp/sample.epub")
        store.write(payload, for: url)
        let loaded = try XCTUnwrap(store.read(for: url))
        XCTAssertEqual(loaded.backendIdentifier, "test.backend")
        XCTAssertEqual(loaded.dimension, 3)
        XCTAssertEqual(loaded.paragraphs.count, 2)
        XCTAssertEqual(loaded.paragraphs[0].textHash, "abc")
        XCTAssertEqual(loaded.paragraphs[0].vector, [0.1, 0.2, 0.3])
    }

    func test_sidecar_clear_all_removes_files_and_returns_size() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("humanist-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EmbeddingsSidecarStore(baseDirectory: dir)
        let payload = EmbeddingsSidecar.empty(backend: "x", dimension: 1)
        store.write(payload, for: URL(fileURLWithPath: "/tmp/a.epub"))
        store.write(payload, for: URL(fileURLWithPath: "/tmp/b.epub"))
        XCTAssertGreaterThan(store.totalBytes(), 0)
        let cleared = store.clearAll()
        XCTAssertGreaterThan(cleared, 0)
        XCTAssertEqual(store.totalBytes(), 0)
    }

    // MARK: - HybridRetriever

    /// BM25-only style returns chapter-shaped hits; the embedding
    /// path isn't consulted.
    func test_hybrid_bm25_only_returns_bm25_chapters() {
        let bm25 = BookKeywordIndex(chapters: [
            .init(id: "c1", title: "Heterotopia", text: "Foucault discusses heterotopia at length here."),
            .init(id: "c2", title: "Other", text: "An unrelated chapter about something else."),
        ])
        let retriever = HybridRetriever(
            style: .bm25, bm25: bm25, embeddings: nil, queryVector: nil
        )
        let hits = retriever.search(query: "heterotopia", topK: 5)
        XCTAssertGreaterThan(hits.count, 0)
        // The chapter that mentions "heterotopia" outranks the other.
        XCTAssertEqual(hits.first?.chapterIdx, 0)
        XCTAssertNil(hits.first?.bm25Rank)  // BM25-only path doesn't fill rank fields
    }

    /// Hybrid style without an embedding index falls back gracefully
    /// to the BM25-only chapter list.
    func test_hybrid_without_embedding_index_falls_back_to_bm25() {
        let bm25 = BookKeywordIndex(chapters: [
            .init(id: "c1", title: "Foo", text: "Foo bar baz."),
            .init(id: "c2", title: "Bar", text: "Lorem ipsum dolor."),
        ])
        let retriever = HybridRetriever(
            style: .hybrid, bm25: bm25, embeddings: nil, queryVector: nil
        )
        let hits = retriever.search(query: "foo", topK: 5)
        XCTAssertGreaterThan(hits.count, 0)
        XCTAssertEqual(hits.first?.chapterIdx, 0)
    }

    /// Four-way RRF: a paragraph that's matched by hierarchy +
    /// entity boosts beats one that has only a marginal embedding
    /// rank. Tests the whole-fusion stacking behavior.
    func test_hybrid_rrf_with_hierarchy_and_entity_boosts() {
        let bm25 = BookKeywordIndex(chapters: [
            .init(id: "c0", title: "A", text: "alpha alpha alpha"),
            .init(id: "c1", title: "B", text: "beta beta beta"),
        ])
        let embeddings = BookEmbeddingIndex(
            paragraphs: [
                .init(chapterIdx: 0, paragraphIdx: 0, text: "alpha first", textHash: "h0", vector: [0, 0, 1]),
                .init(chapterIdx: 0, paragraphIdx: 1, text: "alpha second", textHash: "h1", vector: [0, 0, 1]),
                .init(chapterIdx: 1, paragraphIdx: 0, text: "beta first", textHash: "h2", vector: [0, 0, 1]),
            ],
            backend: StubBackend()
        )
        // Query vector orthogonal to all paragraphs — embedding
        // ranker contributes uniformly, so any winner is driven by
        // BM25 / hierarchy / entity boosts.
        var retriever = HybridRetriever(
            style: .hybrid, bm25: bm25, embeddings: embeddings,
            queryVector: [1, 0, 0]
        )
        // Tag (1, 0) as both hierarchy- and entity-matched. With
        // two rank-1 boosts on top of any BM25 / embedding rank
        // it gets, it should top the list — even though c1's BM25
        // signal is identical to c0's.
        retriever.hierarchyMatches = [(chapterIdx: 1, paragraphIdx: 0)]
        retriever.entityMatches = [(chapterIdx: 1, paragraphIdx: 0)]
        let hits = retriever.search(query: "beta", topK: 3)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first?.chapterIdx, 1)
        XCTAssertEqual(hits.first?.paragraphIdx, 0)
        XCTAssertTrue(hits.first?.hierarchyMatched ?? false)
        XCTAssertTrue(hits.first?.entityMatched ?? false)
    }

    /// Hybrid with both rankers blends BM25 chapter projection and
    /// embedding paragraph rank via RRF. A paragraph that scores
    /// well on both rankers wins over one that scores well on only
    /// one.
    func test_hybrid_rrf_prefers_paragraphs_in_both_rankers() {
        let bm25 = BookKeywordIndex(chapters: [
            .init(id: "c0", title: "A", text: "alpha alpha alpha alpha alpha word"),
            .init(id: "c1", title: "B", text: "beta beta beta"),
        ])
        // Paragraphs: c0 has two paragraphs, c1 has one. Vectors
        // pinned so that "p1 in c0" is the embedding top hit and
        // "p0 in c1" is a distant second.
        let embeddings = BookEmbeddingIndex(
            paragraphs: [
                .init(chapterIdx: 0, paragraphIdx: 0, text: "alpha first", textHash: "h0", vector: [0.5, 0.5, 0]),
                .init(chapterIdx: 0, paragraphIdx: 1, text: "alpha word", textHash: "h1", vector: [1, 0, 0]),
                .init(chapterIdx: 1, paragraphIdx: 0, text: "beta", textHash: "h2", vector: [0, 0, 1]),
            ],
            backend: StubBackend()
        )
        let retriever = HybridRetriever(
            style: .hybrid, bm25: bm25, embeddings: embeddings,
            queryVector: [1, 0, 0]  // exact match to (c0, p1)
        )
        let hits = retriever.search(query: "alpha", topK: 3)
        XCTAssertFalse(hits.isEmpty)
        // BM25 ranks c0 first (lots of "alpha" hits); embedding ranks
        // (c0, p1) first. RRF fuses these — (c0, p1) gets both
        // signals, so it wins.
        XCTAssertEqual(hits.first?.chapterIdx, 0)
        XCTAssertEqual(hits.first?.paragraphIdx, 1)
    }
}

/// Stub backend — never called by the tests above (they construct
/// the index with pre-computed vectors), but `BookEmbeddingIndex`
/// requires one in its initializer.
private struct StubBackend: EmbeddingBackend {
    var identifier: String { "stub.test" }
    var dimension: Int { 3 }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        Array(repeating: [0, 0, 0], count: texts.count)
    }
}

// MARK: - Entity index

final class BookEntityIndexTests: XCTestCase {

    /// NER on a contemporary English query surfaces the canonical
    /// names that are present in the index — the matched key list
    /// is sorted by mention count descending. Uses entities
    /// NLTagger recognizes reliably (Apple / Google as orgs) so
    /// the test isn't gated on the model's recall for academic
    /// surnames.
    func test_entity_match_orders_by_mention_count() {
        let appleAnchors = (0..<5).map {
            BookEntityIndex.Anchor(chapterIdx: 0, paragraphIdx: $0)
        }
        let googleAnchors = [
            BookEntityIndex.Anchor(chapterIdx: 1, paragraphIdx: 0),
        ]
        let index = BookEntityIndex(
            mentions: [
                "apple": appleAnchors,
                "google": googleAnchors,
            ],
            displayNames: [
                "apple": "Apple",
                "google": "Google",
            ]
        )
        let matched = index.entitiesMatching(
            query: "Apple and Google compete fiercely in mobile"
        )
        XCTAssertEqual(matched, ["apple", "google"])
    }

    /// Entities not in the index are dropped from the match list
    /// even when the NER pass detects them.
    func test_entity_match_filters_unknowns() {
        let index = BookEntityIndex(
            mentions: ["apple": [
                BookEntityIndex.Anchor(chapterIdx: 0, paragraphIdx: 0),
            ]],
            displayNames: ["apple": "Apple"]
        )
        let matched = index.entitiesMatching(
            query: "Apple and Microsoft rivalry"
        )
        XCTAssertEqual(matched, ["apple"])
    }

    /// Anchors lookup returns the stored list verbatim.
    func test_anchor_lookup_returns_stored_anchors() {
        let anchors = [
            BookEntityIndex.Anchor(chapterIdx: 2, paragraphIdx: 7),
            BookEntityIndex.Anchor(chapterIdx: 5, paragraphIdx: 0),
        ]
        let index = BookEntityIndex(
            mentions: ["plato": anchors],
            displayNames: ["plato": "Plato"]
        )
        XCTAssertEqual(index.anchors(for: "plato"), anchors)
        XCTAssertTrue(index.anchors(for: "missing").isEmpty)
    }

    // MARK: - Alias dictionary

    func test_alias_parse_round_trips_through_render() {
        let input = """
        Heterotopia
        biopolitics
        Governmentality
        """
        let dict = AliasDictionary.parse(input)
        XCTAssertEqual(dict.terms, ["heterotopia", "biopolitics", "governmentality"])
        XCTAssertEqual(dict.displayTerms["heterotopia"], "Heterotopia")
        XCTAssertEqual(dict.displayTerms["biopolitics"], "biopolitics")
        // Render is sorted alphabetically; display forms preserved.
        XCTAssertEqual(
            dict.render(),
            "biopolitics\nGovernmentality\nHeterotopia"
        )
    }

    func test_alias_parse_skips_empty_and_whitespace_lines() {
        let input = """
        first


        second

        """
        let dict = AliasDictionary.parse(input)
        XCTAssertEqual(dict.terms, ["first", "second"])
    }

    func test_alias_parse_dedupes_case_insensitively() {
        let input = "Foo\nfoo\nFOO"
        let dict = AliasDictionary.parse(input)
        XCTAssertEqual(dict.terms.count, 1)
        // Display form prefers most-uppercase: "FOO" beats "Foo"
        // beats "foo" because uppercase count + length tiebreak.
        XCTAssertEqual(dict.displayTerms["foo"], "FOO")
    }

    func test_alias_store_round_trips_through_disk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("humanist-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("aliases.json")
        let store = AliasDictionaryStore(storeURL: url)
        let dict = AliasDictionary.parse("alpha\nbeta")
        store.write(dict)
        let loaded = store.read()
        XCTAssertEqual(loaded.terms, dict.terms)
        XCTAssertEqual(loaded.displayTerms, dict.displayTerms)
    }

    /// Codable round-trip — sidecar persistence relies on this.
    func test_entity_index_codable_round_trip() throws {
        let index = BookEntityIndex(
            mentions: [
                "athens": [
                    BookEntityIndex.Anchor(chapterIdx: 1, paragraphIdx: 3),
                ],
            ],
            displayNames: ["athens": "Athens"]
        )
        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(BookEntityIndex.self, from: data)
        XCTAssertEqual(decoded, index)
    }
}

// MARK: - Hierarchy parser

final class BookHierarchyIndexTests: XCTestCase {

    /// Real-world flat nav.xhtml shape (chapters only, no nested
    /// sections) — this is what most converted books look like.
    func test_parser_handles_flat_nav() {
        let xhtml = """
        <html><body>
        <nav epub:type="toc" id="toc">
          <h1>Title</h1>
          <ol>
            <li><a href="text/ch-001.xhtml">Chapter One</a></li>
            <li><a href="text/ch-002.xhtml">Chapter Two</a></li>
            <li><a href="text/ch-003.xhtml#hu-page-12">Chapter Three</a></li>
          </ol>
        </nav>
        </body></html>
        """
        let raw = NavParser.parse(xhtml)
        XCTAssertEqual(raw.count, 3)
        XCTAssertEqual(raw[0].title, "Chapter One")
        XCTAssertEqual(raw[0].href, "text/ch-001.xhtml")
        XCTAssertEqual(raw[2].title, "Chapter Three")
        XCTAssertEqual(raw[2].href, "text/ch-003.xhtml#hu-page-12")
    }

    /// R-Hierarchy nested nav: chapters with sub-section `<ol>`s.
    func test_parser_handles_nested_sections() {
        let xhtml = """
        <html><body>
        <nav epub:type="toc">
          <ol>
            <li><a href="text/ch-001.xhtml">Chapter One</a>
              <ol>
                <li><a href="text/ch-001.xhtml#sec-1-1">Section 1.1</a></li>
                <li><a href="text/ch-001.xhtml#sec-1-2">Section 1.2</a></li>
              </ol>
            </li>
            <li><a href="text/ch-002.xhtml">Chapter Two</a></li>
          </ol>
        </nav>
        </body></html>
        """
        let raw = NavParser.parse(xhtml)
        XCTAssertEqual(raw.count, 2)
        XCTAssertEqual(raw[0].children.count, 2)
        XCTAssertEqual(raw[0].children[0].title, "Section 1.1")
        XCTAssertEqual(raw[0].children[0].href, "text/ch-001.xhtml#sec-1-1")
        XCTAssertTrue(raw[1].children.isEmpty)
    }

    /// Empty / missing nav returns an empty list — chat path falls
    /// back to chapter-only context.
    func test_parser_returns_empty_when_no_nav() {
        XCTAssertEqual(NavParser.parse("<html></html>").count, 0)
        XCTAssertEqual(NavParser.parse("not html").count, 0)
    }

    /// Anchors with named-entity titles round-trip cleanly.
    func test_parser_decodes_entities_in_titles() {
        let xhtml = """
        <nav epub:type="toc">
          <ol>
            <li><a href="x.xhtml">Foo &amp; Bar</a></li>
          </ol>
        </nav>
        """
        let raw = NavParser.parse(xhtml)
        XCTAssertEqual(raw.first?.title, "Foo & Bar")
    }

    /// Structural-pattern matching: "chapter 3" finds the third
    /// chapter (1-based). Falls back to title-substring match too.
    func test_structural_query_matches_chapter_number() {
        let xhtml = """
        <nav epub:type="toc">
          <ol>
            <li><a href="ch-001.xhtml">On Heterotopias</a></li>
            <li><a href="ch-002.xhtml">The Order of Things</a></li>
            <li><a href="ch-003.xhtml">Power / Knowledge</a></li>
          </ol>
        </nav>
        """
        let raw = NavParser.parse(xhtml)
        let nodes = raw.enumerated().map { idx, r in
            BookHierarchyIndex.Node(
                id: "ch-\(idx)",
                kind: .chapter,
                title: r.title,
                chapterIdx: idx,
                fragment: nil,
                children: []
            )
        }
        let index = BookHierarchyIndex(nodes: nodes)
        // Numeric pattern: "chapter 2" matches the second chapter.
        let numeric = index.nodesMatching(query: "summarize chapter 2")
        XCTAssertEqual(numeric.first?.chapterIdx, 1)
        // Title pattern: "heterotopias" matches the first chapter.
        let titled = index.nodesMatching(query: "what about heterotopias?")
        XCTAssertEqual(titled.first?.chapterIdx, 0)
    }
}
