import XCTest
import Foundation
@testable import Humanist

/// Coverage for `DuplicateDetector`'s four-tier grouping logic
/// + the canonical-suggestion heuristic. EPUB-hash detection
/// (tier 1) is exercised with real synthetic files; tiers 2–4
/// drive off catalog metadata only and don't touch disk.
@MainActor
final class DuplicateDetectorTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-detector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    private func makeEntry(
        title: String,
        author: String? = nil,
        addedAt: Date = Date(),
        sourceContentHashes: [String] = [],
        epubBytes: String = ""
    ) throws -> LibraryEntry {
        let epub = tempDir.appendingPathComponent("\(UUID().uuidString).epub")
        try Data(epubBytes.utf8).write(to: epub)
        return LibraryEntry(
            epubURL: epub, title: title, addedAt: addedAt,
            author: author, sourceContentHashes: sourceContentHashes
        )
    }

    // MARK: - Tier 1: identical EPUB bytes

    func test_tier1_groups_entries_with_identical_epub_bytes() async throws {
        // Three entries: A + B have identical bytes, C differs.
        let a = try makeEntry(title: "A", epubBytes: "same bytes")
        let b = try makeEntry(title: "B", epubBytes: "same bytes")
        let c = try makeEntry(title: "C", epubBytes: "different")

        let groups = await DuplicateDetector.detect(in: [a, b, c])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].tier, .identicalEPUBs)
        XCTAssertEqual(Set(groups[0].entries.map(\.id)), Set([a.id, b.id]))
    }

    func test_tier1_no_match_returns_empty() async throws {
        let a = try makeEntry(title: "A", epubBytes: "a")
        let b = try makeEntry(title: "B", epubBytes: "b")
        let groups = await DuplicateDetector.detect(in: [a, b])
        XCTAssertEqual(groups, [])
    }

    // MARK: - Tier 2: shared source-content-hash

    func test_tier2_groups_entries_with_shared_source_hash() async throws {
        // A + B share source hash "src-1" via different EPUBs; C
        // has a different source hash.
        let a = try makeEntry(
            title: "A", sourceContentHashes: ["src-1"], epubBytes: "a-bytes"
        )
        let b = try makeEntry(
            title: "B", sourceContentHashes: ["src-1", "src-2"], epubBytes: "b-bytes"
        )
        let c = try makeEntry(
            title: "C", sourceContentHashes: ["src-3"], epubBytes: "c-bytes"
        )
        let groups = await DuplicateDetector.detect(in: [a, b, c])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].tier, .sharedSourceHash)
        XCTAssertEqual(Set(groups[0].entries.map(\.id)), Set([a.id, b.id]))
    }

    func test_tier2_transitively_connects_via_overlapping_hashes() async throws {
        // A shares hash X with B; B shares hash Y with C.
        // Transitively A and C should land in one group.
        let a = try makeEntry(title: "A", sourceContentHashes: ["X"],
                              epubBytes: "a")
        let b = try makeEntry(title: "B", sourceContentHashes: ["X", "Y"],
                              epubBytes: "b")
        let c = try makeEntry(title: "C", sourceContentHashes: ["Y"],
                              epubBytes: "c")
        let groups = await DuplicateDetector.detect(in: [a, b, c])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].entries.map(\.id)), Set([a.id, b.id, c.id]))
    }

    func test_tier1_pre_empts_tier2_for_same_entries() async throws {
        // Two entries are both byte-identical AND share a source
        // hash. They should only appear once — under tier 1
        // (strongest signal wins).
        let a = try makeEntry(title: "A",
            sourceContentHashes: ["src"], epubBytes: "same")
        let b = try makeEntry(title: "B",
            sourceContentHashes: ["src"], epubBytes: "same")
        let groups = await DuplicateDetector.detect(in: [a, b])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].tier, .identicalEPUBs)
    }

    // MARK: - Tier 3: identical normalized title + author

    func test_tier3_matches_on_normalized_title_and_author() async throws {
        // Two entries differ in year prefix + punctuation; same
        // book.
        let a = try makeEntry(
            title: "1972 Anti-Oedipus: Capitalism and Schizophrenia",
            author: "Deleuze, Gilles",
            epubBytes: "a-bytes"
        )
        let b = try makeEntry(
            title: "Anti-Oedipus Capitalism and Schizophrenia",
            author: "Gilles Deleuze",
            epubBytes: "b-bytes"
        )
        let groups = await DuplicateDetector.detect(in: [a, b])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].tier, .identicalTitleAuthor)
    }

    func test_tier3_skips_when_author_missing() async throws {
        // No author on either side — tier 3 requires both.
        let a = try makeEntry(title: "Anti-Oedipus", author: nil,
                              epubBytes: "a")
        let b = try makeEntry(title: "Anti-Oedipus", author: nil,
                              epubBytes: "b")
        let groups = await DuplicateDetector.detect(in: [a, b])
        // Tier 4 picks up the same-title case but only if author
        // normalizes to something. With no author, no fuzzy match
        // bucket either. Net: no groups.
        XCTAssertEqual(groups, [])
    }

    // MARK: - Tier 4: fuzzy title

    func test_tier4_matches_subtitle_drift() async throws {
        // Word bags must overlap at >= 0.7 Jaccard. Same-author,
        // mostly-same-title pair that crosses the threshold:
        // "The Mirror Stage" {the, mirror, stage} vs
        // "The Mirror Stage Revisited" {the, mirror, stage,
        //   revisited}. Intersection 3, union 4, Jaccard 0.75.
        let a = try makeEntry(
            title: "The Mirror Stage",
            author: "Jacques Lacan",
            epubBytes: "a"
        )
        let b = try makeEntry(
            title: "The Mirror Stage Revisited",
            author: "Jacques Lacan",
            epubBytes: "b"
        )
        let groups = await DuplicateDetector.detect(in: [a, b])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.tier, .fuzzyTitleMatch)
    }

    func test_tier4_skips_below_jaccard_threshold() async throws {
        // Significant subtitle drift drops below 0.7 — the
        // detector deliberately refuses to call this a duplicate
        // because the words diverge too much. User can still
        // manually link them via a future "Merge entries" UI.
        let a = try makeEntry(
            title: "Anti-Oedipus",
            author: "Gilles Deleuze",
            epubBytes: "a"
        )
        let b = try makeEntry(
            title: "Anti-Oedipus and the Politics of Desire",
            author: "Gilles Deleuze",
            epubBytes: "b"
        )
        let groups = await DuplicateDetector.detect(in: [a, b])
        XCTAssertEqual(groups, [],
            "<0.7 Jaccard should leave both entries unlinked")
    }

    func test_tier4_skips_when_authors_differ() async throws {
        // Same approximate title, different authors — tier 4
        // requires author match.
        let a = try makeEntry(title: "Anti-Oedipus",
            author: "Gilles Deleuze", epubBytes: "a")
        let b = try makeEntry(title: "Anti-Oedipus",
            author: "Slavoj Zizek", epubBytes: "b")
        let groups = await DuplicateDetector.detect(in: [a, b])
        // No tier 3 (titles match but authors differ), no tier 4
        // (different authors → different buckets).
        XCTAssertEqual(groups, [])
    }

    // MARK: - Suggested canonical

    func test_canonical_prefers_richer_metadata() throws {
        // A is minimal; B has author + lastOpened. B wins.
        let a = try makeEntry(title: "A", author: nil, epubBytes: "a")
        let b = try makeEntry(title: "B", author: "Author Name", epubBytes: "b")
        var bMutable = b
        bMutable.lastOpened = Date()
        let canonical = DuplicateDetector.suggestCanonical([a, bMutable])
        XCTAssertEqual(canonical.id, bMutable.id)
    }

    func test_canonical_prefers_larger_file() throws {
        // A = small bytes, B = bigger bytes. B wins.
        let a = try makeEntry(title: "A", author: "Same", epubBytes: "x")
        let b = try makeEntry(title: "A", author: "Same",
            epubBytes: String(repeating: "x", count: 10_000))
        let canonical = DuplicateDetector.suggestCanonical([a, b])
        XCTAssertEqual(canonical.id, b.id)
    }

    // MARK: - Normalization unit-pins

    func test_normalizeTitle_strips_year_and_punctuation() {
        XCTAssertEqual(
            DuplicateDetector.normalizeTitle("1972 Anti-Oedipus: Capitalism!"),
            "anti oedipus capitalism"
        )
    }

    func test_normalizeTitle_strips_diacritics() {
        XCTAssertEqual(
            DuplicateDetector.normalizeTitle("Écrits Complets"),
            "ecrits complets"
        )
    }

    func test_normalizeAuthor_handles_lastname_first() {
        XCTAssertEqual(
            DuplicateDetector.normalizeAuthor("Lacan, Jacques"),
            "jacques lacan"
        )
        XCTAssertEqual(
            DuplicateDetector.normalizeAuthor("Jacques Lacan"),
            "jacques lacan"
        )
    }

    func test_jaccard_basic_overlap() {
        XCTAssertEqual(
            DuplicateDetector.jaccard(Set(["a", "b"]), Set(["a", "b"])),
            1.0
        )
        XCTAssertEqual(
            DuplicateDetector.jaccard(Set(["a", "b"]), Set(["a"])),
            0.5
        )
        XCTAssertEqual(
            DuplicateDetector.jaccard(Set(["a"]), Set(["b"])),
            0.0
        )
    }
}
