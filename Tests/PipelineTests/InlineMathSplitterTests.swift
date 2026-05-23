import XCTest
import Document
@testable import Pipeline

/// `InlineMathSplitter` rescues math-aware OCR output (Surya, etc.)
/// that emits inline `<math>…</math>` markup as part of recognized
/// text. Without this expansion the markup gets XML-escaped at the
/// writer and the reader sees literal `&lt;math&gt;` strings.
final class InlineMathSplitterTests: XCTestCase {

    // MARK: - No-op cases

    func test_run_without_math_returned_unchanged() {
        let run = InlineRun("plain text with no math here")
        let result = InlineMathSplitter.split(run)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "plain text with no math here")
        XCTAssertNil(result[0].rawXHTML)
    }

    func test_run_already_having_rawXHTML_returned_unchanged() {
        // PageXHTMLParser already captured `<math>` properly; don't
        // re-process and risk double-wrapping.
        let preserved = #"<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>"#
        let run = InlineRun("x", rawXHTML: preserved)
        let result = InlineMathSplitter.split(run)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].rawXHTML, preserved)
    }

    func test_unclosed_math_open_falls_back_to_original_text() {
        let run = InlineRun("see <math>t_m for the equation")
        let result = InlineMathSplitter.split(run)
        // No close → no valid split → return original.
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "see <math>t_m for the equation")
        XCTAssertNil(result[0].rawXHTML)
    }

    // MARK: - Single math span

    func test_single_inline_math_produces_three_runs() {
        let run = InlineRun("two time inputs <math>t_m</math> and t_f")
        let result = InlineMathSplitter.split(run)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].text, "two time inputs ")
        XCTAssertNil(result[0].rawXHTML)
        XCTAssertNotNil(result[1].rawXHTML)
        XCTAssertTrue(result[1].rawXHTML?.contains("<math") ?? false)
        XCTAssertTrue(result[1].rawXHTML?.contains("t_m") ?? false)
        XCTAssertEqual(result[2].text, " and t_f")
    }

    func test_canonical_xmlns_added_when_missing() {
        let run = InlineRun("see <math>t_m</math> here")
        let result = InlineMathSplitter.split(run)
        let mathRun = result.first { $0.rawXHTML != nil }
        XCTAssertNotNil(mathRun)
        XCTAssertTrue(
            mathRun?.rawXHTML?.contains(
                #"xmlns="http://www.w3.org/1998/Math/MathML""#
            ) ?? false,
            "expected canonical xmlns in: \(mathRun?.rawXHTML ?? "")"
        )
    }

    func test_existing_xmlns_not_duplicated() {
        let already = #"<math display="block" xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>"#
        let run = InlineRun("see \(already) here")
        let result = InlineMathSplitter.split(run)
        let mathRun = result.first { $0.rawXHTML != nil }
        let xmlnsCount = mathRun?.rawXHTML?.components(separatedBy: "xmlns=").count ?? 0
        // components.count for a string containing the search N times
        // is N+1; one xmlns = count 2.
        XCTAssertEqual(xmlnsCount, 2, "expected exactly one xmlns, got \(xmlnsCount - 1)")
    }

    // MARK: - Multiple math spans

    func test_multiple_math_spans_in_one_run() {
        let run = InlineRun(
            "the inputs <math>t_m</math> and <math>t_f</math> appear here"
        )
        let result = InlineMathSplitter.split(run)
        // text, math, text, math, text → 5 runs
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[0].text, "the inputs ")
        XCTAssertNotNil(result[1].rawXHTML)
        XCTAssertEqual(result[2].text, " and ")
        XCTAssertNotNil(result[3].rawXHTML)
        XCTAssertEqual(result[4].text, " appear here")
    }

    // MARK: - Emphasis / language preservation

    func test_emphasis_propagates_to_prefix_and_suffix_runs() {
        let run = InlineRun(
            "an italic <math>t_m</math> snippet",
            isItalic: true
        )
        let result = InlineMathSplitter.split(run)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result[0].isItalic)
        XCTAssertFalse(result[0].text.isEmpty)
        // Math run doesn't carry emphasis — the markup itself
        // owns styling.
        XCTAssertFalse(result[1].isItalic)
        XCTAssertTrue(result[2].isItalic)
    }

    func test_language_propagates_to_surrounding_runs() {
        let run = InlineRun(
            "λ value <math>λ_m</math> applies",
            language: BCP47("el"),
            isItalic: false
        )
        let result = InlineMathSplitter.split(run)
        XCTAssertEqual(result.first?.language, BCP47("el"))
        XCTAssertEqual(result.last?.language, BCP47("el"))
        XCTAssertNil(result.first { $0.rawXHTML != nil }?.language)
    }

    // MARK: - Plain-text fallback

    func test_plain_text_fallback_captures_math_inner_content() {
        let run = InlineRun("see <math>w_m/w_f</math> ratio")
        let result = InlineMathSplitter.split(run)
        let mathRun = result.first { $0.rawXHTML != nil }
        XCTAssertEqual(mathRun?.text, "w_m/w_f")
    }

    func test_empty_math_inner_gets_bracket_placeholder() {
        // Defensive: if a math element ends up empty after tag-
        // stripping, the fallback shouldn't be the empty string
        // (Markdown / .txt writers would emit nothing where math
        // existed).
        let run = InlineRun("see <math></math> here")
        let result = InlineMathSplitter.split(run)
        let mathRun = result.first { $0.rawXHTML != nil }
        XCTAssertEqual(mathRun?.text, "[math]")
    }

    // MARK: - Batch helper

    func test_split_on_array_expands_runs_in_place() {
        let runs = [
            InlineRun("first plain"),
            InlineRun("contains <math>x</math> markup"),
            InlineRun("last plain"),
        ]
        let result = InlineMathSplitter.split(runs)
        // 1 + 3 (split of middle) + 1 = 5
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[0].text, "first plain")
        XCTAssertEqual(result[1].text, "contains ")
        XCTAssertNotNil(result[2].rawXHTML)
        XCTAssertEqual(result[3].text, " markup")
        XCTAssertEqual(result[4].text, "last plain")
    }
}
