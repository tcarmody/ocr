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
            ]
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
