import XCTest
import CoreGraphics
import Document
import Layout
import OCR
@testable import Pipeline

final class FootnoteLinkerTests: XCTestCase {

    // MARK: - splitMarkerAndBody

    func test_splitMarker_numeric_with_period() {
        let r = FootnoteLinker.splitMarkerAndBody("1. Foucault writes that...")
        XCTAssertEqual(r?.marker, "1")
        XCTAssertEqual(r?.body, "Foucault writes that...")
    }

    func test_splitMarker_numeric_with_paren() {
        let r = FootnoteLinker.splitMarkerAndBody("12) See above.")
        XCTAssertEqual(r?.marker, "12")
        XCTAssertEqual(r?.body, "See above.")
    }

    func test_splitMarker_numeric_with_space() {
        let r = FootnoteLinker.splitMarkerAndBody("3 Cf. Discipline and Punish, p. 47.")
        XCTAssertEqual(r?.marker, "3")
        XCTAssertEqual(r?.body, "Cf. Discipline and Punish, p. 47.")
    }

    func test_splitMarker_unpunctuated_with_capital_body() {
        // OCR sometimes drops the period after the marker.
        let r = FootnoteLinker.splitMarkerAndBody("5Foucault writes...")
        XCTAssertEqual(r?.marker, "5")
        XCTAssertEqual(r?.body, "Foucault writes...")
    }

    func test_splitMarker_symbolic_dagger() {
        let r = FootnoteLinker.splitMarkerAndBody("† See note above.")
        XCTAssertEqual(r?.marker, "†")
        XCTAssertEqual(r?.body, "See note above.")
    }

    func test_splitMarker_no_marker_returns_nil() {
        let r = FootnoteLinker.splitMarkerAndBody("Just some prose with no leading marker.")
        XCTAssertNil(r)
    }

    func test_splitMarker_runaway_digits_rejected() {
        // 4-digit "marker" looks like a year or page number.
        let r = FootnoteLinker.splitMarkerAndBody("1968. The Foucault lecture.")
        XCTAssertNil(r)
    }

    // MARK: - splice

    private func parsed(_ marker: String, page: Int = 3, body: String = "...") -> FootnoteLinker.Parsed {
        FootnoteLinker.Parsed(marker: marker, body: body, id: "fn-p\(page)-\(marker)")
    }

    func test_splice_no_footnotes_returns_text_unchanged() {
        let runs = FootnoteLinker.splice(text: "Plain prose.", footnotes: [])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "Plain prose.")
        XCTAssertNil(runs[0].noterefId)
    }

    func test_splice_inserts_noteref_after_word_punct() {
        let runs = FootnoteLinker.splice(
            text: "He critiques knowledge.3 Then he moves on.",
            footnotes: [parsed("3")]
        )
        // Expect: ["He critiques knowledge.", "3"(noteref), " Then he moves on."]
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].text, "He critiques knowledge.")
        XCTAssertNil(runs[0].noterefId)
        XCTAssertEqual(runs[1].text, "3")
        XCTAssertEqual(runs[1].noterefId, "fn-p3-3")
        XCTAssertEqual(runs[2].text, " Then he moves on.")
    }

    func test_splice_attached_to_word_no_punct() {
        let runs = FootnoteLinker.splice(
            text: "discourse5 followed by more text.",
            footnotes: [parsed("5")]
        )
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].text, "discourse")
        XCTAssertEqual(runs[1].text, "5")
        XCTAssertEqual(runs[1].noterefId, "fn-p3-5")
        XCTAssertEqual(runs[2].text, " followed by more text.")
    }

    func test_splice_skips_year_when_marker_is_substring() {
        // Marker "8" must not match the "8" inside "1968".
        let runs = FootnoteLinker.splice(
            text: "Foucault gave a lecture in 1968 about discipline.",
            footnotes: [parsed("8")]
        )
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "Foucault gave a lecture in 1968 about discipline.")
    }

    func test_splice_skips_page_reference() {
        // Marker "1" with " 1 " in "page 1 above" — preceded by space, no match.
        let runs = FootnoteLinker.splice(
            text: "See page 1 above.",
            footnotes: [parsed("1")]
        )
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "See page 1 above.")
    }

    func test_splice_does_not_match_digit_followed_by_digit() {
        // Marker "1" must not match the leading "1" in "12".
        let runs = FootnoteLinker.splice(
            text: "discourse12 word.",
            footnotes: [parsed("1")]
        )
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "discourse12 word.")
    }

    func test_splice_longer_marker_wins_when_both_exist() {
        // "11" should win over "1" when both are valid footnotes on
        // the page and "11" appears in body text.
        let runs = FootnoteLinker.splice(
            text: "discourse11 followed by other text.",
            footnotes: [parsed("1"), parsed("11")]
        )
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[1].text, "11")
        XCTAssertEqual(runs[1].noterefId, "fn-p3-11")
    }

    func test_splice_multiple_markers_in_one_paragraph() {
        let runs = FootnoteLinker.splice(
            text: "First claim.1 Second claim,2 third claim.3",
            footnotes: [parsed("1"), parsed("2"), parsed("3")]
        )
        let noterefs = runs.compactMap { $0.noterefId }
        XCTAssertEqual(noterefs, ["fn-p3-1", "fn-p3-2", "fn-p3-3"])
    }

    // MARK: - end-to-end parseFootnotes

    func test_parseFootnotes_picks_up_footnote_region_only() {
        // Two regions: a body region and a footnote region. Only the
        // footnote should appear in the output, parsed with marker "1".
        let bodyRegion = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.5),
            readingOrder: 0,
            confidence: 0.95
        )
        let footnoteRegion = LayoutRegion(
            kind: .footnote,
            box: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.1),
            readingOrder: 1,
            confidence: 0.95
        )
        let bodyObs = TextObservation(
            text: "Body text here.", confidence: 0.95,
            box: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.02),
            source: .vision
        )
        let footnoteObs = TextObservation(
            text: "1. Cf. Discipline and Punish.", confidence: 0.95,
            box: CGRect(x: 0.1, y: 0.08, width: 0.8, height: 0.02),
            source: .vision
        )
        let parsed = FootnoteLinker.parseFootnotes(
            pageIndex: 7,
            observations: [bodyObs, footnoteObs],
            regions: [bodyRegion, footnoteRegion]
        )
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].marker, "1")
        XCTAssertEqual(parsed[0].id, "fn-p7-1")
        XCTAssertEqual(parsed[0].body, "Cf. Discipline and Punish.")
    }
}
