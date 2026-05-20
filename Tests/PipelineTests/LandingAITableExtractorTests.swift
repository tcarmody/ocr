import XCTest
import Document
@testable import Pipeline

/// Markdown-table parser tests for `LandingAITableExtractor`. The
/// wire-level extract path needs a live LandingAI API to exercise;
/// the only non-trivial pure-Swift logic is `parseMarkdownTable`,
/// which is what this covers.
final class LandingAITableExtractorTests: XCTestCase {

    func testParsesStandardTableWithHeader() {
        let md = """
            | Year | Title           |
            |------|-----------------|
            | 1923 | Cane            |
            | 1937 | Their Eyes Were |
            """
        let rows = LandingAITableExtractor.parseMarkdownTable(md)
        XCTAssertNotNil(rows)
        guard let rows else { return }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertTrue(rows[0].allSatisfy(\.isHeader))
        XCTAssertFalse(rows[1].contains(where: \.isHeader))
        XCTAssertEqual(rows[1][0].runs.first?.text, "1923")
        XCTAssertEqual(rows[2][1].runs.first?.text, "Their Eyes Were")
    }

    func testParsesTableWithoutOuterPipes() {
        // Some markdown emitters omit the leading/trailing pipes.
        let md = """
            a | b
            ---|---
            1 | 2
            """
        let rows = LandingAITableExtractor.parseMarkdownTable(md)
        // Without leading `|`, our scanner correctly considers these
        // non-table lines — outer pipes are the cheap signal we use
        // to find the table block. This test pins that behavior so
        // a future relaxation is an explicit choice.
        XCTAssertNil(rows)
    }

    func testSkipsCaptionBeforeTable() {
        let md = """
            Table 1: Voters by region

            | Region | Count |
            |--------|-------|
            | North  | 412   |
            | South  | 388   |
            """
        let rows = LandingAITableExtractor.parseMarkdownTable(md)
        XCTAssertEqual(rows?.count, 3)
        XCTAssertEqual(rows?[1][0].runs.first?.text, "North")
    }

    func testTreatsAlignmentColonsAsSeparator() {
        let md = """
            | Left | Center | Right |
            |:-----|:------:|------:|
            | a    | b      | c     |
            """
        let rows = LandingAITableExtractor.parseMarkdownTable(md)
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?[0].allSatisfy(\.isHeader), true)
    }

    func testReturnsNilOnNonTableMarkdown() {
        let md = """
            This is a paragraph.

            And another paragraph.
            """
        XCTAssertNil(LandingAITableExtractor.parseMarkdownTable(md))
    }

    func testStopsAtFirstTableBlock() {
        // Two tables separated by prose — only the first should be
        // returned to keep the parser predictable.
        let md = """
            | a | b |
            |---|---|
            | 1 | 2 |

            And another:

            | x | y |
            |---|---|
            | 9 | 0 |
            """
        let rows = LandingAITableExtractor.parseMarkdownTable(md)
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?[1][0].runs.first?.text, "1")
    }

    func testHandlesEmptyCells() {
        let md = """
            | a | b | c |
            |---|---|---|
            | 1 |   | 3 |
            """
        let rows = LandingAITableExtractor.parseMarkdownTable(md)
        XCTAssertEqual(rows?[1][1].runs.count, 0)
    }
}
