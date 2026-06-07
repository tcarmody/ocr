import XCTest
@testable import Humanist

/// R-Reader. `AnnotationStore` is the per-content-hash sidecar
/// for bookmarks / highlights / passages. Mirrors the
/// `ReadingPositionStore` shape; tests cover the round-trip,
/// cache-miss / corrupt-file fallbacks, and the add / update /
/// remove convenience operations.
final class AnnotationStoreTests: XCTestCase {

    /// Unique hash per test so writes don't collide across runs
    /// of the suite (the store writes into real Application
    /// Support — no sandbox).
    private func uniqueHash() -> String {
        "test-annot-" + UUID().uuidString
    }

    /// Best-effort cleanup of stored annotations. Failures are
    /// silent — tearDown shouldn't crash on already-removed
    /// files.
    private func cleanup(_ hash: String) {
        if let url = AnnotationStore.fileURL(forContentHash: hash) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Round-trip

    func test_save_then_load_roundtrip() {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        let bookmark = Annotation(
            chapterIdx: 3, paragraphAnchorId: "hu-p-3-12",
            kind: .bookmark
        )
        let highlight = Annotation(
            chapterIdx: 5,
            paragraphAnchorId: "hu-p-5-7",
            selectedText: "the unexamined life",
            selectionRange: Annotation.TextRange(
                startOffset: 10, endOffset: 30
            ),
            kind: .highlight
        )
        let passage = Annotation(
            chapterIdx: 5,
            paragraphAnchorId: "hu-p-5-12",
            selectedText: "is not worth living",
            selectionRange: Annotation.TextRange(
                startOffset: 0, endOffset: 19
            ),
            note: "Apology, 38a",
            kind: .passage
        )
        let bundle = AnnotationsBundle(
            contentHash: hash,
            annotations: [bookmark, highlight, passage]
        )
        AnnotationStore.save(bundle)
        let loaded = AnnotationStore.load(forContentHash: hash)
        XCTAssertEqual(loaded.contentHash, hash)
        XCTAssertEqual(loaded.annotations.count, 3)
        XCTAssertEqual(loaded.annotations[0].kind, .bookmark)
        XCTAssertEqual(loaded.annotations[1].selectedText, "the unexamined life")
        XCTAssertEqual(loaded.annotations[2].note, "Apology, 38a")
    }

    func test_paragraph_fingerprint_roundtrips() {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        let highlight = Annotation(
            chapterIdx: 2,
            paragraphAnchorId: "hu-p-2-4",
            selectedText: "spade is turned",
            selectionRange: Annotation.TextRange(
                startOffset: 5, endOffset: 20
            ),
            paragraphFingerprint: "1a2b3c4d",
            kind: .highlight
        )
        AnnotationStore.save(
            AnnotationsBundle(contentHash: hash, annotations: [highlight])
        )
        let loaded = AnnotationStore.load(forContentHash: hash)
        XCTAssertEqual(
            loaded.annotations.first?.paragraphFingerprint, "1a2b3c4d"
        )
    }

    /// A sidecar written before fingerprinting existed has no
    /// `paragraphFingerprint` key; it must still decode (field is
    /// an optional that defaults to nil), so upgrades don't drop
    /// a reader's existing highlights.
    func test_decodes_legacy_json_without_fingerprint() throws {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        guard let url = AnnotationStore.fileURL(forContentHash: hash) else {
            XCTFail("Expected fileURL to resolve")
            return
        }
        let legacy = """
        {
          "contentHash": "\(hash)",
          "annotations": [
            {
              "id": "\(UUID().uuidString)",
              "chapterIdx": 1,
              "paragraphAnchorId": "hu-p-1-2",
              "selectedText": "bedrock",
              "kind": "highlight",
              "createdAt": "2024-01-01T00:00:00Z",
              "updatedAt": "2024-01-01T00:00:00Z"
            }
          ]
        }
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let loaded = AnnotationStore.load(forContentHash: hash)
        XCTAssertEqual(loaded.annotations.count, 1)
        XCTAssertNil(loaded.annotations.first?.paragraphFingerprint)
        XCTAssertEqual(loaded.annotations.first?.selectedText, "bedrock")
    }

    // MARK: - Missing / corrupt files

    func test_load_returns_empty_bundle_for_missing_hash() {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        let loaded = AnnotationStore.load(forContentHash: hash)
        XCTAssertEqual(loaded.contentHash, hash)
        XCTAssertTrue(loaded.annotations.isEmpty)
    }

    func test_load_returns_empty_bundle_on_corrupt_file() throws {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        guard let url = AnnotationStore.fileURL(
            forContentHash: hash
        ) else {
            XCTFail("Expected fileURL to resolve")
            return
        }
        try "not valid json".write(
            to: url, atomically: true, encoding: .utf8
        )
        // Corrupt sidecar must not crash the reader on open —
        // load returns an empty bundle.
        let loaded = AnnotationStore.load(forContentHash: hash)
        XCTAssertTrue(loaded.annotations.isEmpty)
    }

    // MARK: - Add / update / remove

    func test_add_appends_to_existing_bundle() {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        AnnotationStore.add(
            Annotation(chapterIdx: 1, kind: .bookmark),
            forContentHash: hash
        )
        AnnotationStore.add(
            Annotation(chapterIdx: 2, kind: .bookmark),
            forContentHash: hash
        )
        let loaded = AnnotationStore.load(forContentHash: hash)
        XCTAssertEqual(loaded.annotations.count, 2)
        XCTAssertEqual(
            loaded.annotations.map(\.chapterIdx), [1, 2]
        )
    }

    func test_update_replaces_annotation_by_id() {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        var annot = Annotation(
            chapterIdx: 1,
            selectedText: "original",
            note: "first note",
            kind: .passage
        )
        AnnotationStore.add(annot, forContentHash: hash)
        annot.note = "edited note"
        annot.updatedAt = Date()
        AnnotationStore.update(annot, forContentHash: hash)
        let loaded = AnnotationStore.load(forContentHash: hash)
        XCTAssertEqual(loaded.annotations.count, 1)
        XCTAssertEqual(loaded.annotations[0].note, "edited note")
    }

    func test_update_unknown_id_is_noop() {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        AnnotationStore.add(
            Annotation(chapterIdx: 1, kind: .bookmark),
            forContentHash: hash
        )
        AnnotationStore.update(
            Annotation(chapterIdx: 99, kind: .bookmark),
            forContentHash: hash
        )
        XCTAssertEqual(
            AnnotationStore.load(forContentHash: hash).annotations.count,
            1
        )
    }

    func test_remove_drops_annotation_by_id() {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        let keep = Annotation(chapterIdx: 1, kind: .bookmark)
        let drop = Annotation(chapterIdx: 2, kind: .bookmark)
        AnnotationStore.save(AnnotationsBundle(
            contentHash: hash, annotations: [keep, drop]
        ))
        AnnotationStore.remove(id: drop.id, forContentHash: hash)
        let loaded = AnnotationStore.load(forContentHash: hash)
        XCTAssertEqual(loaded.annotations.count, 1)
        XCTAssertEqual(loaded.annotations[0].id, keep.id)
    }

    func test_remove_unknown_id_is_noop() {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        AnnotationStore.add(
            Annotation(chapterIdx: 1, kind: .bookmark),
            forContentHash: hash
        )
        AnnotationStore.remove(id: UUID(), forContentHash: hash)
        XCTAssertEqual(
            AnnotationStore.load(forContentHash: hash).annotations.count,
            1
        )
    }
}
