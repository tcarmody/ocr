import XCTest
@testable import EPUB

/// Tests for `CorpusMetricsExtractor`'s regex-based pure helpers
/// (full integration via `humanist-cli compare-corpus` exercises
/// the EPUB-open path; here we lock down the extraction primitives
/// on synthetic XHTML so future regex tweaks don't drift the
/// metric meaning).
final class CorpusMetricsTests: XCTestCase {

    // MARK: - countMatches

    func test_count_matches_simple() {
        let xhtml = "<p>One</p><p>Two</p><p>Three</p>"
        XCTAssertEqual(
            CorpusMetricsExtractor.countMatches(
                pattern: "<p\\b[^>]*>", in: xhtml
            ),
            3
        )
    }

    func test_count_matches_case_insensitive() {
        let xhtml = "<P>uppercase</P><p>lowercase</p>"
        XCTAssertEqual(
            CorpusMetricsExtractor.countMatches(
                pattern: "<p\\b[^>]*>", in: xhtml
            ),
            2
        )
    }

    func test_count_matches_respects_word_boundary() {
        // `<para>` shouldn't count as `<p>` — `\b` after the tag
        // name distinguishes.
        let xhtml = "<p>real p</p><para>not a p</para>"
        XCTAssertEqual(
            CorpusMetricsExtractor.countMatches(
                pattern: "<p\\b[^>]*>", in: xhtml
            ),
            1
        )
    }

    // MARK: - extractBodyEpubType

    func test_extracts_simple_epub_type() {
        let xhtml = """
        <html xmlns:epub="http://www.idpf.org/2007/ops">
        <body epub:type="chapter"><p>Hi.</p></body></html>
        """
        XCTAssertEqual(
            CorpusMetricsExtractor.extractBodyEpubType(from: xhtml),
            "chapter"
        )
    }

    func test_extracts_epub_type_with_multiple_attributes() {
        let xhtml = """
        <body class="x" epub:type="preface" id="ch1"><p>Hi.</p></body>
        """
        XCTAssertEqual(
            CorpusMetricsExtractor.extractBodyEpubType(from: xhtml),
            "preface"
        )
    }

    func test_returns_nil_when_body_unlabeled() {
        let xhtml = "<body><p>Hi.</p></body>"
        XCTAssertNil(
            CorpusMetricsExtractor.extractBodyEpubType(from: xhtml)
        )
    }

    func test_returns_nil_when_no_body_tag() {
        let xhtml = "<html><p>No body.</p></html>"
        XCTAssertNil(
            CorpusMetricsExtractor.extractBodyEpubType(from: xhtml)
        )
    }

    // MARK: - stripXHTML

    func test_stripXHTML_removes_tags() {
        let xhtml = "<p>Hello <em>world</em>.</p>"
        XCTAssertEqual(
            CorpusMetricsExtractor.stripXHTML(xhtml),
            "Hello world ."
        )
    }

    func test_stripXHTML_decodes_named_entities() {
        let xhtml = "<p>Tom &amp; Jerry &lt;3</p>"
        XCTAssertEqual(
            CorpusMetricsExtractor.stripXHTML(xhtml),
            "Tom & Jerry <3"
        )
    }

    func test_stripXHTML_collapses_whitespace() {
        let xhtml = "<p>foo\n\n  bar\t\tbaz</p>"
        XCTAssertEqual(
            CorpusMetricsExtractor.stripXHTML(xhtml),
            "foo bar baz"
        )
    }

    // MARK: - CorpusComparison retention

    func test_retention_one_when_actual_matches_reference() {
        let actual = CorpusMetrics(inlineCodeCount: 10)
        let reference = CorpusMetrics(inlineCodeCount: 10)
        let comp = CorpusComparison(
            bookStem: "x", actual: actual, reference: reference
        )
        XCTAssertEqual(
            comp.retention(\.inlineCodeCount), 1.0
        )
    }

    func test_retention_zero_when_actual_emits_nothing() {
        let actual = CorpusMetrics(inlineCodeCount: 0)
        let reference = CorpusMetrics(inlineCodeCount: 100)
        let comp = CorpusComparison(
            bookStem: "x", actual: actual, reference: reference
        )
        XCTAssertEqual(
            comp.retention(\.inlineCodeCount), 0.0
        )
    }

    func test_retention_nil_when_reference_is_empty() {
        // No signal — both sides agree there's nothing to retain.
        let actual = CorpusMetrics(inlineCodeCount: 0)
        let reference = CorpusMetrics(inlineCodeCount: 0)
        let comp = CorpusComparison(
            bookStem: "x", actual: actual, reference: reference
        )
        XCTAssertNil(comp.retention(\.inlineCodeCount))
    }

    // MARK: - Jaccard

    func test_jaccard_returns_one_for_identical_word_sets() {
        let a = CorpusMetrics(uniqueWords: ["foo", "bar", "baz"])
        let r = CorpusMetrics(uniqueWords: ["foo", "bar", "baz"])
        let comp = CorpusComparison(bookStem: "x", actual: a, reference: r)
        XCTAssertEqual(comp.wordSetJaccard, 1.0, accuracy: 1e-9)
    }

    func test_jaccard_handles_partial_overlap() {
        let a = CorpusMetrics(uniqueWords: ["foo", "bar", "baz"])
        let r = CorpusMetrics(uniqueWords: ["bar", "baz", "qux"])
        let comp = CorpusComparison(bookStem: "x", actual: a, reference: r)
        // {bar, baz} ∩ {bar, baz, qux, foo} = 2; union = 4
        XCTAssertEqual(comp.wordSetJaccard, 0.5, accuracy: 1e-9)
    }

    func test_jaccard_returns_zero_for_disjoint_sets() {
        let a = CorpusMetrics(uniqueWords: ["foo"])
        let r = CorpusMetrics(uniqueWords: ["bar"])
        let comp = CorpusComparison(bookStem: "x", actual: a, reference: r)
        XCTAssertEqual(comp.wordSetJaccard, 0.0)
    }
}
