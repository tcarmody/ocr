import XCTest
import Foundation
@testable import Humanist

/// Coverage for `FederatedIndexCache`: round-trip, fingerprint
/// stability, corrupt-file rejection, version-byte rejection, and
/// invalidate-clears-the-file. Each test uses a tempdir-scoped
/// cache URL so we never touch the real `defaultCacheURL` under
/// Application Support.
@MainActor
final class FederatedIndexCacheTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FederatedIndexCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    private var cacheURL: URL {
        tempDir.appendingPathComponent("library-federated-index.bin")
    }

    // MARK: - Round-trip

    func test_save_then_load_roundtrips_full_payload() throws {
        let payload = makePayload(
            dimension: 8,
            sources: [
                ("alpha", "Alpha Author", "/tmp/alpha.epub", [
                    para(chapter: 0, idx: 1, hash: "a1", text: "alpha p1",
                         vec: Array(repeating: 0.1, count: 8)),
                    para(chapter: 1, idx: 0, hash: "a2", text: nil,
                         vec: Array(repeating: -0.2, count: 8))
                ]),
                // Author nil — exercises the empty-string round-trip
                // path that decodes back to `nil`, not `Optional("")`.
                ("beta", nil, "/tmp/beta.epub", [
                    para(chapter: 0, idx: 0, hash: "b1", text: "beta only para",
                         vec: Array(repeating: 0.7, count: 8))
                ])
            ],
            mentions: [
                "Foucault": [
                    anchor("/tmp/alpha.epub", "alpha", 0, 1),
                    anchor("/tmp/beta.epub", "beta", 0, 0)
                ]
            ],
            displayNames: ["foucault": "Foucault"],
            entityIndexedCount: 2
        )

        XCTAssertTrue(FederatedIndexCache.save(payload, to: cacheURL))

        let restored = FederatedIndexCache.load(
            expectedFingerprint: payload.fingerprint,
            backendIdentifier: payload.backendIdentifier,
            dimension: payload.dimension,
            from: cacheURL
        )
        let r = try XCTUnwrap(restored)

        XCTAssertEqual(r.fingerprint, payload.fingerprint)
        XCTAssertEqual(r.backendIdentifier, payload.backendIdentifier)
        XCTAssertEqual(r.dimension, payload.dimension)
        XCTAssertEqual(r.stats.indexed, payload.stats.indexed)
        XCTAssertEqual(r.stats.unindexed, payload.stats.unindexed)
        XCTAssertEqual(r.stats.backendMismatch, payload.stats.backendMismatch)

        XCTAssertEqual(r.sources.count, 2)
        XCTAssertEqual(r.sources[0].bookTitle, "alpha")
        XCTAssertEqual(r.sources[0].bookAuthor, "Alpha Author")
        XCTAssertEqual(r.sources[0].epubURL.path, "/tmp/alpha.epub")
        XCTAssertEqual(r.sources[0].paragraphs.count, 2)
        XCTAssertNil(r.sources[1].bookAuthor,
                     "empty author must round-trip back to nil, not Optional(\"\")")
        XCTAssertEqual(r.sources[0].paragraphs[0].textHash, "a1")
        XCTAssertEqual(r.sources[0].paragraphs[0].text, "alpha p1")
        XCTAssertEqual(r.sources[0].paragraphs[0].vector,
                       Array(repeating: Float(0.1), count: 8))
        XCTAssertNil(r.sources[0].paragraphs[1].text,
                     "nil text must survive the round-trip distinct from empty string")

        XCTAssertEqual(r.entityIndex.mentions["Foucault"]?.count, 2)
        XCTAssertEqual(r.entityIndex.displayNames["foucault"], "Foucault")
        XCTAssertEqual(r.entityIndex.indexedBookCount, 2)
    }

    func test_load_rejects_fingerprint_mismatch() {
        let payload = makePayload(dimension: 4, sources: [], mentions: [:],
                                  displayNames: [:], entityIndexedCount: 0)
        XCTAssertTrue(FederatedIndexCache.save(payload, to: cacheURL))

        // A different fingerprint than what we stored → load returns
        // nil. Caller falls through to a fresh build.
        let restored = FederatedIndexCache.load(
            expectedFingerprint: "stale-fingerprint",
            backendIdentifier: payload.backendIdentifier,
            dimension: payload.dimension,
            from: cacheURL
        )
        XCTAssertNil(restored)
    }

    func test_load_rejects_backend_identity_drift() {
        let payload = makePayload(dimension: 4, sources: [], mentions: [:],
                                  displayNames: [:], entityIndexedCount: 0)
        XCTAssertTrue(FederatedIndexCache.save(payload, to: cacheURL))

        // Backend changed under us — same fingerprint but a
        // different identifier. Refuse to hand back a vector set
        // tagged for the wrong embedding space.
        let restored = FederatedIndexCache.load(
            expectedFingerprint: payload.fingerprint,
            backendIdentifier: "different-backend",
            dimension: payload.dimension,
            from: cacheURL
        )
        XCTAssertNil(restored)
    }

    func test_load_rejects_dimension_drift() {
        let payload = makePayload(dimension: 4, sources: [], mentions: [:],
                                  displayNames: [:], entityIndexedCount: 0)
        XCTAssertTrue(FederatedIndexCache.save(payload, to: cacheURL))

        let restored = FederatedIndexCache.load(
            expectedFingerprint: payload.fingerprint,
            backendIdentifier: payload.backendIdentifier,
            dimension: 8,                       // changed from 4
            from: cacheURL
        )
        XCTAssertNil(restored)
    }

    // MARK: - Corruption handling

    func test_load_rejects_missing_file() {
        let result = FederatedIndexCache.load(
            expectedFingerprint: "anything",
            backendIdentifier: "anything",
            dimension: 4,
            from: cacheURL
        )
        XCTAssertNil(result)
    }

    func test_load_rejects_garbage_file() throws {
        try Data("not a humanist cache".utf8).write(to: cacheURL)
        let result = FederatedIndexCache.load(
            expectedFingerprint: "anything",
            backendIdentifier: "anything",
            dimension: 4,
            from: cacheURL
        )
        XCTAssertNil(result)
    }

    func test_load_rejects_truncated_file() throws {
        let payload = makePayload(
            dimension: 4,
            sources: [
                ("alpha", nil, "/tmp/alpha.epub", [
                    para(chapter: 0, idx: 0, hash: "h", text: "x",
                         vec: [0.1, 0.2, 0.3, 0.4])
                ])
            ],
            mentions: [:], displayNames: [:], entityIndexedCount: 0
        )
        XCTAssertTrue(FederatedIndexCache.save(payload, to: cacheURL))

        // Truncate the file mid-payload. Decoder must reject
        // cleanly rather than returning a partial / corrupted shape.
        let full = try Data(contentsOf: cacheURL)
        let truncated = full.prefix(full.count - 12)
        try truncated.write(to: cacheURL)

        let result = FederatedIndexCache.load(
            expectedFingerprint: payload.fingerprint,
            backendIdentifier: payload.backendIdentifier,
            dimension: payload.dimension,
            from: cacheURL
        )
        XCTAssertNil(result)
    }

    // MARK: - Invalidate

    func test_invalidate_removes_file() {
        let payload = makePayload(dimension: 4, sources: [], mentions: [:],
                                  displayNames: [:], entityIndexedCount: 0)
        _ = FederatedIndexCache.save(payload, to: cacheURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        FederatedIndexCache.invalidate(at: cacheURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func test_invalidate_is_safe_when_file_absent() {
        // No file present yet — invalidate must not throw.
        FederatedIndexCache.invalidate(at: cacheURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    // MARK: - Fingerprint

    func test_fingerprint_is_stable_for_identical_inputs() {
        // No sidecar files exist, so every entry reports "missing"
        // sentinel — still deterministic across runs.
        let entries = (0..<5).map { i in
            LibraryEntry(
                epubURL: URL(fileURLWithPath: "/tmp/book\(i).epub"),
                title: "Book \(i)",
                addedAt: Date(timeIntervalSince1970: TimeInterval(i))
            )
        }
        let fp1 = FederatedIndexCache.fingerprint(
            backendIdentifier: "ident", dimension: 16, entries: entries
        )
        let fp2 = FederatedIndexCache.fingerprint(
            backendIdentifier: "ident", dimension: 16, entries: entries
        )
        XCTAssertEqual(fp1, fp2)
    }

    func test_fingerprint_is_stable_under_entry_reordering() {
        // Entries sort by libraryID before hashing, so iteration
        // order on the call site doesn't matter. Important: the
        // catalog re-orders rows on rename / collection edit /
        // user sort.
        let entries = (0..<3).map { i in
            LibraryEntry(
                epubURL: URL(fileURLWithPath: "/tmp/book\(i).epub"),
                title: "B \(i)", addedAt: Date()
            )
        }
        let fpAscending = FederatedIndexCache.fingerprint(
            backendIdentifier: "id", dimension: 8, entries: entries
        )
        let fpDescending = FederatedIndexCache.fingerprint(
            backendIdentifier: "id", dimension: 8, entries: entries.reversed()
        )
        XCTAssertEqual(fpAscending, fpDescending)
    }

    func test_fingerprint_changes_when_backend_identifier_changes() {
        let entries: [LibraryEntry] = []
        let a = FederatedIndexCache.fingerprint(
            backendIdentifier: "a", dimension: 8, entries: entries
        )
        let b = FederatedIndexCache.fingerprint(
            backendIdentifier: "b", dimension: 8, entries: entries
        )
        XCTAssertNotEqual(a, b)
    }

    func test_fingerprint_changes_when_dimension_changes() {
        let entries: [LibraryEntry] = []
        let a = FederatedIndexCache.fingerprint(
            backendIdentifier: "x", dimension: 8, entries: entries
        )
        let b = FederatedIndexCache.fingerprint(
            backendIdentifier: "x", dimension: 16, entries: entries
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Helpers

    private func makePayload(
        dimension: Int,
        sources: [(
            title: String,
            author: String?,
            path: String,
            paragraphs: [EmbeddingsSidecar.Entry]
        )],
        mentions: [String: [LibraryEntityIndex.LibraryAnchor]],
        displayNames: [String: String],
        entityIndexedCount: Int
    ) -> FederatedIndexCache.Payload {
        let mappedSources = sources.map { tuple in
            LibraryEmbeddingIndex.Source(
                epubURL: URL(fileURLWithPath: tuple.path),
                bookTitle: tuple.title,
                bookAuthor: tuple.author,
                paragraphs: tuple.paragraphs
            )
        }
        let entityIndex = LibraryEntityIndex(
            mentions: mentions,
            displayNames: displayNames,
            indexedBookCount: entityIndexedCount
        )
        return FederatedIndexCache.Payload(
            backendIdentifier: "test-backend",
            dimension: dimension,
            fingerprint: "deadbeef00000000000000000000000000000000000000000000000000000000",
            stats: LibraryEmbeddingIndex.Stats(
                indexed: sources.count, unindexed: 0, backendMismatch: 0
            ),
            sources: mappedSources,
            entityIndex: entityIndex
        )
    }

    private func para(
        chapter: Int, idx: Int, hash: String, text: String?, vec: [Float]
    ) -> EmbeddingsSidecar.Entry {
        EmbeddingsSidecar.Entry(
            chapterIdx: chapter,
            paragraphIdx: idx,
            textHash: hash,
            vector: vec,
            text: text
        )
    }

    private func anchor(
        _ path: String, _ title: String, _ chapter: Int, _ paragraph: Int
    ) -> LibraryEntityIndex.LibraryAnchor {
        LibraryEntityIndex.LibraryAnchor(
            epubURL: URL(fileURLWithPath: path),
            bookTitle: title,
            chapterIdx: chapter,
            paragraphIdx: paragraph
        )
    }
}
