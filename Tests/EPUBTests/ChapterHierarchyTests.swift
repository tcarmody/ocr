import XCTest
import Document
@testable import EPUB

/// `ChapterHierarchy` — sub-section anchor extraction from a chapter
/// + nested `NavWriter.Entry` assembly. Pure helpers, no I/O.
final class ChapterHierarchyTests: XCTestCase {

    // MARK: - subsections(of:)

    func test_subsections_extracts_deeper_headings_only() {
        // Chapter opens with H2 (chapter title). H3 + H4 inside are
        // sub-sections; the H2 itself is excluded (the chapter row in
        // nav already carries that title).
        let chapter = Chapter(
            title: "The Will to Power",
            blocks: [
                .heading(level: 2, runs: [InlineRun("The Will to Power")]),
                .paragraph(runs: [InlineRun("Opening paragraph.")]),
                .heading(level: 3, runs: [InlineRun("§1. Antitheses")]),
                .paragraph(runs: [InlineRun("Body.")]),
                .heading(level: 4, runs: [InlineRun("Sub-subsection a")]),
                .paragraph(runs: [InlineRun("Body.")]),
                .heading(level: 3, runs: [InlineRun("§2. Higher truth")]),
                .paragraph(runs: [InlineRun("Body.")]),
            ]
        )
        let subs = ChapterHierarchy.subsections(of: chapter, chapterIdx: 5)
        XCTAssertEqual(subs.count, 3)
        XCTAssertEqual(subs[0].title, "§1. Antitheses")
        XCTAssertEqual(subs[0].level, 3)
        XCTAssertEqual(subs[0].anchorId, "hu-sec-5-2")
        XCTAssertEqual(subs[1].title, "Sub-subsection a")
        XCTAssertEqual(subs[1].level, 4)
        XCTAssertEqual(subs[2].title, "§2. Higher truth")
        XCTAssertEqual(subs[2].level, 3)
    }

    func test_subsections_empty_when_chapter_has_no_opening_heading() {
        // Front matter with just an anchor + paragraphs — no opening
        // heading defines the chapter level. Skip the pass entirely
        // rather than hoist the first internal heading.
        let chapter = Chapter(
            title: "Front Matter",
            blocks: [
                .anchor(id: "hu-page-0", label: "Page 1"),
                .paragraph(runs: [InlineRun("Dedication.")]),
                .heading(level: 3, runs: [InlineRun("Acknowledgments")]),
                .paragraph(runs: [InlineRun("…")]),
            ]
        )
        let subs = ChapterHierarchy.subsections(of: chapter, chapterIdx: 0)
        XCTAssertTrue(subs.isEmpty,
            "front-matter chapters without an opening heading should produce no sub-sections")
    }

    func test_subsections_excludes_same_level_headings() {
        // Two H2 headings — only the first defines the chapter level;
        // a second H2 isn't deeper than that, so it's not a sub-section.
        // (In practice this case shouldn't happen because
        // ChapterSplitter already split at H2, so two H2s in one
        // chapter would be a bug — but defend the math anyway.)
        let chapter = Chapter(
            title: "A",
            blocks: [
                .heading(level: 2, runs: [InlineRun("A")]),
                .paragraph(runs: [InlineRun("body")]),
                .heading(level: 2, runs: [InlineRun("Stowaway H2")]),
                .paragraph(runs: [InlineRun("body")]),
            ]
        )
        let subs = ChapterHierarchy.subsections(of: chapter, chapterIdx: 0)
        XCTAssertTrue(subs.isEmpty)
    }

    func test_subsections_skips_empty_heading_text() {
        let chapter = Chapter(
            title: "Foo",
            blocks: [
                .heading(level: 1, runs: [InlineRun("Foo")]),
                .heading(level: 2, runs: [InlineRun("   ")]),  // whitespace only
                .heading(level: 2, runs: [InlineRun("Real Section")]),
            ]
        )
        let subs = ChapterHierarchy.subsections(of: chapter, chapterIdx: 0)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].title, "Real Section")
    }

    // MARK: - navChildren(from:chapterHref:)

    func test_navChildren_flat_when_all_subsections_at_same_level() {
        let subs = [
            ChapterHierarchy.Subsection(blockIndex: 1, level: 3,
                title: "A", anchorId: "hu-sec-0-1"),
            ChapterHierarchy.Subsection(blockIndex: 4, level: 3,
                title: "B", anchorId: "hu-sec-0-4"),
        ]
        let children = ChapterHierarchy.navChildren(
            from: subs, chapterHref: "text/chapter-001.xhtml"
        )
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].title, "A")
        XCTAssertEqual(children[0].href, "text/chapter-001.xhtml#hu-sec-0-1")
        XCTAssertTrue(children[0].children.isEmpty)
        XCTAssertEqual(children[1].title, "B")
    }

    func test_navChildren_nests_deeper_under_shallower() {
        // H3 "A" → H4 "A.1" + "A.2" → H3 "B" → H4 "B.1" should
        // produce: A {A.1, A.2}, B {B.1}.
        let subs = [
            ChapterHierarchy.Subsection(blockIndex: 1, level: 3,
                title: "A", anchorId: "hu-sec-0-1"),
            ChapterHierarchy.Subsection(blockIndex: 2, level: 4,
                title: "A.1", anchorId: "hu-sec-0-2"),
            ChapterHierarchy.Subsection(blockIndex: 3, level: 4,
                title: "A.2", anchorId: "hu-sec-0-3"),
            ChapterHierarchy.Subsection(blockIndex: 4, level: 3,
                title: "B", anchorId: "hu-sec-0-4"),
            ChapterHierarchy.Subsection(blockIndex: 5, level: 4,
                title: "B.1", anchorId: "hu-sec-0-5"),
        ]
        let children = ChapterHierarchy.navChildren(
            from: subs, chapterHref: "text/chapter-001.xhtml"
        )
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].title, "A")
        XCTAssertEqual(children[0].children.count, 2)
        XCTAssertEqual(children[0].children[0].title, "A.1")
        XCTAssertEqual(children[0].children[1].title, "A.2")
        XCTAssertEqual(children[1].title, "B")
        XCTAssertEqual(children[1].children.count, 1)
        XCTAssertEqual(children[1].children[0].title, "B.1")
    }

    func test_navChildren_three_levels_deep() {
        // H2 → H3 → H4 chain. The H4 should sit under the H3 which
        // sits under the H2, all under the chapter row.
        let subs = [
            ChapterHierarchy.Subsection(blockIndex: 1, level: 2,
                title: "Outer", anchorId: "id1"),
            ChapterHierarchy.Subsection(blockIndex: 2, level: 3,
                title: "Middle", anchorId: "id2"),
            ChapterHierarchy.Subsection(blockIndex: 3, level: 4,
                title: "Inner", anchorId: "id3"),
        ]
        let children = ChapterHierarchy.navChildren(
            from: subs, chapterHref: "text/chapter-001.xhtml"
        )
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0].title, "Outer")
        XCTAssertEqual(children[0].children.count, 1)
        XCTAssertEqual(children[0].children[0].title, "Middle")
        XCTAssertEqual(children[0].children[0].children.count, 1)
        XCTAssertEqual(children[0].children[0].children[0].title, "Inner")
    }

    func test_navChildren_misnested_deeper_first_attaches_to_root() {
        // Pathological: H4 appears before any H3. With no shallower
        // parent in scope, it attaches to the chapter root rather
        // than getting dropped — better to surface it (slightly
        // mis-leveled) than to lose it from navigation entirely.
        let subs = [
            ChapterHierarchy.Subsection(blockIndex: 1, level: 4,
                title: "Orphan", anchorId: "id1"),
            ChapterHierarchy.Subsection(blockIndex: 2, level: 3,
                title: "Proper", anchorId: "id2"),
        ]
        let children = ChapterHierarchy.navChildren(
            from: subs, chapterHref: "text/chapter-001.xhtml"
        )
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].title, "Orphan")
        XCTAssertEqual(children[1].title, "Proper")
    }

    func test_navChildren_empty_when_no_subsections() {
        let children = ChapterHierarchy.navChildren(
            from: [], chapterHref: "text/chapter-001.xhtml"
        )
        XCTAssertTrue(children.isEmpty)
    }
}
