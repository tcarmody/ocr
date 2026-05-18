import XCTest
@testable import EPUB

/// Tests for `EPUBBook.nextAvailableHref(near:)` and the
/// R-Split-Filename-Sanity defense added 2026-05-12. The original
/// implementation took the source chapter's full stem and appended
/// `_split_NNN`, producing indefinite filename growth across
/// repeated splits — after ~23 iterations the resulting filename
/// hit macOS APFS's 255-byte limit and got silently clipped from
/// `.xhtml` to `.xht`, breaking the EPUB manifest.
final class NextAvailableHrefTests: XCTestCase {

    // MARK: - stripSplitSuffix

    func test_stripSplitSuffix_passes_through_stem_without_suffix() {
        XCTAssertEqual(
            EPUBBook.stripSplitSuffix(from: "chapter-001"),
            "chapter-001"
        )
    }

    func test_stripSplitSuffix_removes_single_split_NNN_suffix() {
        XCTAssertEqual(
            EPUBBook.stripSplitSuffix(from: "chapter-001_split_001"),
            "chapter-001"
        )
    }

    func test_stripSplitSuffix_removes_multiple_trailing_suffixes() {
        // Pathological case from the Walter Benjamin EPUB the user
        // brought in for repair: 23 nested `_split_001` segments.
        let stem = "chapter-001"
            + String(repeating: "_split_001", count: 23)
        XCTAssertEqual(
            EPUBBook.stripSplitSuffix(from: stem),
            "chapter-001"
        )
    }

    func test_stripSplitSuffix_handles_varied_counters() {
        // Legacy / hand-edited stems with single-digit or
        // double-digit counters strip cleanly too.
        XCTAssertEqual(
            EPUBBook.stripSplitSuffix(from: "ch05_split_1"),
            "ch05"
        )
        XCTAssertEqual(
            EPUBBook.stripSplitSuffix(from: "intro_split_42"),
            "intro"
        )
    }

    func test_stripSplitSuffix_only_strips_trailing_segments() {
        // A stem that *contains* `_split_NNN` in the middle but
        // doesn't end with one keeps its body intact.
        XCTAssertEqual(
            EPUBBook.stripSplitSuffix(from: "foo_split_001_bar"),
            "foo_split_001_bar"
        )
    }

    func test_stripSplitSuffix_only_strips_well_formed_suffix() {
        // `_split_` without a counter isn't a real split suffix.
        XCTAssertEqual(
            EPUBBook.stripSplitSuffix(from: "chapter_split_"),
            "chapter_split_"
        )
        // Non-digit counter isn't either.
        XCTAssertEqual(
            EPUBBook.stripSplitSuffix(from: "chapter_split_abc"),
            "chapter_split_abc"
        )
    }

    // MARK: - nextAvailableHref repeated splits stay bounded

    func test_nextAvailableHref_first_split_produces_split_001() throws {
        let book = try makeMinimalBook(initialChapterHref: "text/chapter-001.xhtml")
        let href = book.nextAvailableHref(near: "text/chapter-001.xhtml")
        XCTAssertEqual(href, "text/chapter-001_split_001.xhtml")
    }

    func test_nextAvailableHref_re_split_increments_sibling_counter() throws {
        // The key invariant: splitting an already-split chapter
        // produces another sibling (`_split_002`), not a
        // grandchild (`_split_001_split_001`).
        let book = try makeMinimalBook(
            initialChapterHref: "text/chapter-001.xhtml",
            extraHrefs: ["text/chapter-001_split_001.xhtml"]
        )
        let href = book.nextAvailableHref(
            near: "text/chapter-001_split_001.xhtml"
        )
        XCTAssertEqual(href, "text/chapter-001_split_002.xhtml")
    }

    func test_nextAvailableHref_thirty_repeated_splits_stay_short() throws {
        // Real-world stress: simulate 30 successive splits of the
        // *same* chapter — each new resource gets added to the
        // manifest so the next call has to find a free counter
        // past all the previous ones. Filenames must stay well
        // under the 200-byte cap; before R-Split-Filename-Sanity
        // they'd have hit 245 bytes by iteration 23 and triggered
        // macOS filename truncation.
        let book = try makeMinimalBook(
            initialChapterHref: "text/chapter-001.xhtml"
        )
        var current = "text/chapter-001.xhtml"
        var hrefs: [String] = []
        for _ in 0..<30 {
            let next = book.nextAvailableHref(near: current)
            hrefs.append(next)
            // Add the new href to the book so the next iteration
            // can't reuse it.
            try book.appendResource(Resource(
                id: "r-\(hrefs.count)",
                hrefRelativeToOPF: next,
                mediaType: "application/xhtml+xml",
                properties: nil,
                content: .text("<html></html>"),
                isDirty: true
            ))
            // The user-visible "I just re-split the new piece"
            // workflow chains splits off the most-recent file.
            current = next
        }
        // Sanity: filenames remain bounded.
        for h in hrefs {
            XCTAssertLessThanOrEqual(
                h.utf8.count, 200,
                "href \(h) exceeded the 200-byte cap"
            )
        }
        // The first split is `_split_001`; subsequent splits of
        // sibling pieces should produce the `_split_002`, `_split_003`,
        // … line up to `_split_030`. Counter resets aren't expected.
        XCTAssertEqual(hrefs.first, "text/chapter-001_split_001.xhtml")
        XCTAssertEqual(hrefs.last, "text/chapter-001_split_030.xhtml")
    }

    // MARK: - Byte-cap fallback

    func test_nextAvailableHref_falls_back_to_chapter_NNN_at_byte_cap() throws {
        // Construct a stem long enough that even one
        // `_split_NNN.xhtml` push exceeds the 200-byte cap.
        // 180 chars of stem + `text/` + `_split_001.xhtml` = 205
        // bytes > 200 → trigger fallback.
        let longStem = String(repeating: "a", count: 180)
        let longHref = "text/\(longStem).xhtml"
        let book = try makeMinimalBook(initialChapterHref: longHref)
        let next = book.nextAvailableHref(near: longHref)
        // Expectation: fallback to `text/chapter-NNN.xhtml`. The
        // specific N depends on existing manifest — for a book with
        // only the long file, the counter starts at 001.
        XCTAssertEqual(next, "text/chapter-001.xhtml")
    }

    func test_nextAvailableHref_fallback_respects_collisions() throws {
        let longStem = String(repeating: "a", count: 180)
        let longHref = "text/\(longStem).xhtml"
        let book = try makeMinimalBook(
            initialChapterHref: longHref,
            extraHrefs: [
                "text/chapter-001.xhtml",
                "text/chapter-002.xhtml",
            ]
        )
        let next = book.nextAvailableHref(near: longHref)
        // 001 and 002 taken → fallback picks 003.
        XCTAssertEqual(next, "text/chapter-003.xhtml")
    }

    // MARK: - appendingHref percent-decoding

    /// Surfaced 2026-05-12 by the Walter Benjamin EPUB import bug:
    /// OPF stores hrefs as URI references with percent-encoding
    /// (`text/Table%20of%20Contents.xhtml`), but the filesystem
    /// has the decoded form (`text/Table of Contents.xhtml`). The
    /// loader's existence check used `appendingPathComponent` which
    /// treats `%20` as literal path characters; the file lookup
    /// then failed and `EPUBBookLoader` threw `missingFile`.
    // MARK: - slug-based variant (R-Content-Aware-Rename auto-split)

    func test_nextAvailableHref_slug_uses_slug_as_stem() throws {
        let book = try makeMinimalBook(
            initialChapterHref: "text/chapter-001.xhtml"
        )
        let href = book.nextAvailableHref(
            slug: "on-the-program-of-the-coming-philosophy",
            near: "text/chapter-001.xhtml"
        )
        XCTAssertEqual(
            href,
            "text/on-the-program-of-the-coming-philosophy.xhtml"
        )
    }

    func test_nextAvailableHref_slug_inherits_directory_and_extension() throws {
        let book = try makeMinimalBook(
            initialChapterHref: "OEBPS/chapter-005.xhtml"
        )
        let href = book.nextAvailableHref(
            slug: "the-task-of-the-translator",
            near: "OEBPS/chapter-005.xhtml"
        )
        XCTAssertEqual(
            href, "OEBPS/the-task-of-the-translator.xhtml"
        )
    }

    func test_nextAvailableHref_slug_increments_on_collision() throws {
        // First slug-href is already in the manifest; the slug
        // variant should suffix `-2`, not collide.
        let book = try makeMinimalBook(
            initialChapterHref: "text/chapter-001.xhtml",
            extraHrefs: ["text/preface.xhtml"]
        )
        let href = book.nextAvailableHref(
            slug: "preface", near: "text/chapter-001.xhtml"
        )
        XCTAssertEqual(href, "text/preface-2.xhtml")
    }

    func test_nextAvailableHref_slug_returns_nil_for_empty_slug() throws {
        let book = try makeMinimalBook(
            initialChapterHref: "text/chapter-001.xhtml"
        )
        XCTAssertNil(book.nextAvailableHref(
            slug: "", near: "text/chapter-001.xhtml"
        ))
    }

    func test_nextAvailableHref_slug_returns_nil_when_byte_cap_exceeded() throws {
        // Pathological slug: 230 chars + ".xhtml" + "text/" prefix
        // pushes past the 200-byte cap. Caller should fall back to
        // the counter-style nextAvailableHref(near:).
        let book = try makeMinimalBook(
            initialChapterHref: "text/chapter-001.xhtml"
        )
        let longSlug = String(repeating: "a", count: 230)
        XCTAssertNil(book.nextAvailableHref(
            slug: longSlug, near: "text/chapter-001.xhtml"
        ))
    }

    func test_appendingHref_decodes_percent_escapes_for_disk_lookup() {
        let base = URL(fileURLWithPath: "/tmp/example/OEBPS")
        let url = EPUBBook.appendingHref(
            "text/Table%20of%20Contents.xhtml", to: base
        )
        XCTAssertEqual(
            url.path, "/tmp/example/OEBPS/text/Table of Contents.xhtml"
        )
    }

    func test_appendingHref_handles_apostrophe_and_comma() {
        // Both characters appear in the Benjamin EPUB's hrefs.
        let base = URL(fileURLWithPath: "/tmp/OEBPS")
        XCTAssertEqual(
            EPUBBook.appendingHref(
                "text/A%20Child%27s%20View%20of%20Color.xhtml",
                to: base
            ).path,
            "/tmp/OEBPS/text/A Child's View of Color.xhtml"
        )
        XCTAssertEqual(
            EPUBBook.appendingHref(
                "text/Painting%2C%20or%20Signs%20and%20Marks.xhtml",
                to: base
            ).path,
            "/tmp/OEBPS/text/Painting, or Signs and Marks.xhtml"
        )
    }

    func test_appendingHref_passes_through_unencoded_hrefs() {
        // Plain ASCII hrefs (the typical case) round-trip unchanged.
        let base = URL(fileURLWithPath: "/tmp/OEBPS")
        XCTAssertEqual(
            EPUBBook.appendingHref(
                "text/chapter-001.xhtml", to: base
            ).path,
            "/tmp/OEBPS/text/chapter-001.xhtml"
        )
    }

    func test_appendingHref_falls_back_for_malformed_escape() {
        // `%XY` with non-hex characters is invalid percent-encoding;
        // `removingPercentEncoding` returns nil. The helper falls
        // back to the raw string so the lookup at least proceeds
        // (and fails with a more accurate "file not found" later).
        let base = URL(fileURLWithPath: "/tmp/OEBPS")
        let url = EPUBBook.appendingHref(
            "text/bad%ZZ.xhtml", to: base
        )
        XCTAssertEqual(url.path, "/tmp/OEBPS/text/bad%ZZ.xhtml")
    }

    // MARK: - Helpers

    private func makeMinimalBook(
        initialChapterHref: String,
        extraHrefs: [String] = []
    ) throws -> EPUBBook {
        let workingDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: workingDir, withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDir)
        }
        let opfDir = workingDir.appendingPathComponent("OEBPS")
        try FileManager.default.createDirectory(
            at: opfDir, withIntermediateDirectories: true
        )
        var resources: [String: Resource] = [:]
        var order: [String] = []
        var spine: [String] = []
        let allHrefs = [initialChapterHref] + extraHrefs
        for (i, href) in allHrefs.enumerated() {
            let id = "chap-\(i)"
            let r = Resource(
                id: id,
                hrefRelativeToOPF: href,
                mediaType: "application/xhtml+xml",
                properties: nil,
                content: .text("<html><body><p>x</p></body></html>"),
                isDirty: false
            )
            resources[id] = r
            order.append(id)
            spine.append(id)
        }
        return EPUBBook(
            sourceURL: workingDir.appendingPathComponent("source.epub"),
            workingDirectory: workingDir,
            opfPathRelativeToRoot: "OEBPS/content.opf",
            originalOPFText: "",
            metadata: OPFReader.Metadata(
                title: "Test",
                author: nil,
                language: "en"
            ),
            resourceOrder: order,
            resourcesByID: resources,
            spine: spine
        )
    }
}
