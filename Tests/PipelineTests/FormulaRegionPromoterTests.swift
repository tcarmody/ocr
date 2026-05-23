import XCTest
import CoreGraphics
import Layout
import OCR
@testable import Pipeline

/// `FormulaRegionPromoter` (P-Math-Region-Detection): geometric +
/// text-pattern heuristics for promoting Surya's misclassified
/// `.text` / `.other` regions to `.formula` so the math extractor
/// fires on cropped page images instead of relying on Surya's lossy
/// text OCR.
final class FormulaRegionPromoterTests: XCTestCase {

    // MARK: - Helpers

    /// Build a typical body-text region — covers most of the page
    /// width (~ 70%), several lines tall, baseline for Tier 1
    /// comparison.
    private func bodyText(
        x: CGFloat = 0.14, y: CGFloat = 0.55,
        w: CGFloat = 0.72, h: CGFloat = 0.10,
        kind: LayoutRegion.Kind = .text,
        order: Int = 1
    ) -> LayoutRegion {
        LayoutRegion(
            kind: kind,
            box: CGRect(x: x, y: y, width: w, height: h),
            readingOrder: order, confidence: 0.99
        )
    }

    private func obs(
        _ text: String,
        x: CGFloat, y: CGFloat,
        w: CGFloat = 0.30, h: CGFloat = 0.02
    ) -> TextObservation {
        TextObservation(
            text: text, confidence: 1,
            box: CGRect(x: x, y: y, width: w, height: h),
            source: .surya
        )
    }

    // MARK: - Tier 1: geometric

    func test_geometric_promotes_narrow_centered_short_isolated_region() {
        // Page layout: top body paragraph, centered display equation,
        // bottom body paragraph. Display equation is ~40% page width,
        // centered, one line tall, isolated above and below.
        let regions = [
            bodyText(y: 0.70, h: 0.10, order: 1),
            LayoutRegion(
                kind: .text,
                box: CGRect(x: 0.30, y: 0.55, width: 0.40, height: 0.025),
                readingOrder: 2, confidence: 0.95
            ),
            bodyText(y: 0.30, h: 0.20, order: 3),
        ]
        let (out, diag) = FormulaRegionPromoter.promoteGeometric(
            regions: regions
        )
        XCTAssertEqual(out[1].kind, .formula)
        XCTAssertEqual(diag.promotions.count, 1)
        XCTAssertEqual(diag.promotions.first?.regionIndex, 1)
        XCTAssertEqual(diag.promotions.first?.tier, 1)
    }

    func test_geometric_does_not_promote_wide_body_paragraph() {
        // Full-width body paragraph — looks nothing like a display
        // equation. Should pass through unchanged.
        let regions = [bodyText(y: 0.50, h: 0.20, order: 1)]
        let (out, diag) = FormulaRegionPromoter.promoteGeometric(
            regions: regions
        )
        XCTAssertEqual(out[0].kind, .text)
        XCTAssertEqual(diag.promotions.count, 0)
    }

    func test_geometric_does_not_promote_tall_narrow_region() {
        // Narrow region but multi-line — could be a poem or
        // sidebar, not a display equation. Don't promote. The
        // region is 0.18 tall; with observations providing
        // per-line bbox heights of 0.02, that's 9 lines — well
        // past the 3-line ceiling.
        let regions = [
            bodyText(order: 1),
            LayoutRegion(
                kind: .text,
                box: CGRect(x: 0.30, y: 0.30, width: 0.40, height: 0.18),
                readingOrder: 2, confidence: 0.95
            ),
            bodyText(y: 0.80, order: 3),
        ]
        // Populate per-line observations so the line-height proxy
        // measures the actual line height (0.02), not the median
        // region height.
        let observations = (0..<5).map { i in
            obs(
                "line \(i)",
                x: 0.30, y: CGFloat(0.30 + 0.02 * Double(i)),
                w: 0.40, h: 0.02
            )
        }
        let (out, _) = FormulaRegionPromoter.promoteGeometric(
            regions: regions, observations: observations
        )
        XCTAssertEqual(out[1].kind, .text)
    }

    func test_geometric_does_not_promote_off_center_short_region() {
        // Narrow + short but left-aligned (asymmetry > 10%). Could
        // be a bullet item or column-edge text, not a display
        // equation.
        let regions = [
            bodyText(order: 1),
            LayoutRegion(
                kind: .text,
                box: CGRect(x: 0.14, y: 0.40, width: 0.30, height: 0.025),
                readingOrder: 2, confidence: 0.95
            ),
            bodyText(y: 0.80, order: 3),
        ]
        let (out, _) = FormulaRegionPromoter.promoteGeometric(
            regions: regions
        )
        XCTAssertEqual(out[1].kind, .text)
    }

    func test_geometric_promotes_left_flush_numbered_equation() {
        // Equation-number signal-amplifier: left-flush region (not
        // centered) with `(N)` suffix gets promoted on the relaxed
        // path. Numbered display equations are typically left-flush
        // with the body column, right-aligned to the number.
        let regions = [
            bodyText(order: 1),
            LayoutRegion(
                kind: .text,
                box: CGRect(x: 0.14, y: 0.40, width: 0.40, height: 0.025),
                readingOrder: 2, confidence: 0.95
            ),
            bodyText(y: 0.80, order: 3),
        ]
        let observations = [
            obs("E = mc²       (1)", x: 0.14, y: 0.41, w: 0.40, h: 0.02),
        ]
        let (out, diag) = FormulaRegionPromoter.promoteGeometric(
            regions: regions, observations: observations
        )
        XCTAssertEqual(out[1].kind, .formula)
        XCTAssertEqual(diag.promotions.count, 1)
        let sigs = diag.promotions.first?.signals.joined(separator: ",") ?? ""
        XCTAssertTrue(sigs.contains("eq#"))
    }

    func test_geometric_rejects_centered_title_when_text_has_no_math_signal() {
        // Regression: title pages share the geometric profile of
        // display equations (narrow + centered + short + isolated).
        // Without the math-evidence gate, a chapter-opening
        // "by Gary S. Becker" / "A Theory of Marriage" region
        // promoted to .formula, the math extractor refused, and
        // reflow fell through to the figure-raster path — so the
        // title rendered as an embedded image of itself instead
        // of as text. The text-signal gate keeps geometric tier
        // honest when observations are populated.
        let regions = [
            bodyText(y: 0.70, h: 0.10, order: 1),
            LayoutRegion(
                kind: .text,
                box: CGRect(x: 0.30, y: 0.55, width: 0.40, height: 0.025),
                readingOrder: 2, confidence: 0.95
            ),
            bodyText(y: 0.30, h: 0.20, order: 3),
        ]
        let observations = [
            obs(
                "A Theory of Marriage",
                x: 0.30, y: 0.56, w: 0.40, h: 0.02
            ),
        ]
        let (out, _) = FormulaRegionPromoter.promoteGeometric(
            regions: regions, observations: observations
        )
        XCTAssertEqual(out[1].kind, .text,
            "title-page region with no math signal must not promote")
    }

    func test_geometric_only_promotes_text_and_other_kinds() {
        // A `.sectionHeader` with display-equation geometry must
        // NOT promote — section headers carry real structural
        // intent we don't want to erase.
        let regions = [
            bodyText(order: 1),
            LayoutRegion(
                kind: .sectionHeader,
                box: CGRect(x: 0.30, y: 0.50, width: 0.40, height: 0.025),
                readingOrder: 2, confidence: 0.95
            ),
            bodyText(y: 0.80, order: 3),
        ]
        let (out, _) = FormulaRegionPromoter.promoteGeometric(
            regions: regions
        )
        XCTAssertEqual(out[1].kind, .sectionHeader)
    }

    // MARK: - Tier 2: text-pattern

    func test_text_promotes_region_dominated_by_inline_math_markup() {
        // Surya math-aware OCR emits <math>...</math> spans inline.
        // When density ≥ 60%, the region is mostly math regardless
        // of geometry — promote.
        let regions = [bodyText()]
        let mathHeavy = "<math>w_m</math> > <math>w_f</math> and if <math>MP_{t_f} \\geq MP_{t_m}</math>"
        let observations = [
            obs(mathHeavy, x: 0.14, y: 0.56, w: 0.72, h: 0.02),
        ]
        let (out, diag) = FormulaRegionPromoter.promoteByText(
            regions: regions, observations: observations
        )
        XCTAssertEqual(out[0].kind, .formula)
        XCTAssertEqual(diag.promotions.first?.tier, 2)
        let sigs = diag.promotions.first?.signals.joined(separator: ",") ?? ""
        XCTAssertTrue(sigs.contains("mathML"))
    }

    func test_text_promotes_single_line_latex_equation() {
        // Single-line, contains `=`, ≤ 5 prose words, has LaTeX
        // operator. Display equation rendered as broken text.
        let regions = [bodyText()]
        let observations = [
            obs(#"\sum_{i=1}^{n} x_i = \mu"#,
                x: 0.30, y: 0.56, w: 0.40, h: 0.02),
        ]
        let (out, diag) = FormulaRegionPromoter.promoteByText(
            regions: regions, observations: observations
        )
        XCTAssertEqual(out[0].kind, .formula)
        let sigs = diag.promotions.first?.signals.joined(separator: ",") ?? ""
        XCTAssertTrue(sigs.contains("latexOp"))
    }

    func test_text_promotes_equation_number_with_math_symbols() {
        // Region ending in `(3.4)` AND containing math symbols.
        let regions = [bodyText()]
        let observations = [
            obs("Z = α + β x + ε    (3.4)",
                x: 0.30, y: 0.56, w: 0.40, h: 0.02),
        ]
        let (out, diag) = FormulaRegionPromoter.promoteByText(
            regions: regions, observations: observations
        )
        XCTAssertEqual(out[0].kind, .formula)
        let sigs = diag.promotions.first?.signals.joined(separator: ",") ?? ""
        XCTAssertTrue(sigs.contains("eq#"))
        XCTAssertTrue(sigs.contains("symbols"))
    }

    func test_text_does_not_promote_plain_prose_paragraph() {
        // Real body prose — no math markup, no LaTeX, no equation
        // number, multiple prose words. Pass through unchanged.
        let regions = [bodyText()]
        let observations = [
            obs("The economic theory of marriage assumes voluntary participation by both parties.",
                x: 0.14, y: 0.56, w: 0.72, h: 0.02),
        ]
        let (out, diag) = FormulaRegionPromoter.promoteByText(
            regions: regions, observations: observations
        )
        XCTAssertEqual(out[0].kind, .text)
        XCTAssertEqual(diag.promotions.count, 0)
    }

    func test_text_does_not_promote_prose_with_one_math_fragment() {
        // Mostly prose with one `<math>` fragment — < 60% density.
        // This is the case `InlineMathSplitter` handles
        // (inline-math-in-prose); not a display-equation promotion.
        let regions = [bodyText()]
        let mostlyProse = "The variable <math>x_i</math> represents household income, with substantial cross-population variance and well-documented heteroskedasticity."
        let observations = [
            obs(mostlyProse, x: 0.14, y: 0.56, w: 0.72, h: 0.02),
        ]
        let (out, _) = FormulaRegionPromoter.promoteByText(
            regions: regions, observations: observations
        )
        XCTAssertEqual(out[0].kind, .text)
    }

    func test_text_does_not_promote_section_header_with_math_markup() {
        // Even if a heading contains `<math>` markup, don't strip
        // its structural intent. Same posture as Tier 1.
        let regions = [
            LayoutRegion(
                kind: .sectionHeader,
                box: CGRect(x: 0.14, y: 0.50, width: 0.40, height: 0.025),
                readingOrder: 1, confidence: 0.95
            ),
        ]
        let observations = [
            obs("3. The <math>w_m/w_f</math> Ratio",
                x: 0.14, y: 0.51, w: 0.40, h: 0.02),
        ]
        let (out, _) = FormulaRegionPromoter.promoteByText(
            regions: regions, observations: observations
        )
        XCTAssertEqual(out[0].kind, .sectionHeader)
    }

    // MARK: - Pure helpers

    func test_equation_number_match_accepts_common_patterns() {
        XCTAssertEqual(
            FormulaRegionPromoter.equationNumberMatch("E = mc² (1)"), "(1)"
        )
        XCTAssertEqual(
            FormulaRegionPromoter.equationNumberMatch("y = ax + b (3.4)"), "(3.4)"
        )
        XCTAssertEqual(
            FormulaRegionPromoter.equationNumberMatch("Lemma A.1 holds (A.2)"), "(A.2)"
        )
        XCTAssertEqual(
            FormulaRegionPromoter.equationNumberMatch("see eq (3.4a)"), "(3.4a)"
        )
    }

    func test_equation_number_match_rejects_non_equation_parens() {
        XCTAssertNil(
            FormulaRegionPromoter.equationNumberMatch("(Foucault 1971)")
        )
        XCTAssertNil(
            FormulaRegionPromoter.equationNumberMatch("text ending with no paren")
        )
        XCTAssertNil(
            FormulaRegionPromoter.equationNumberMatch("(see below)")
        )
    }

    func test_count_prose_words_strips_math_markup() {
        // <math>...</math> innards are NOT prose tokens.
        let text = "the variable <math>x_i</math> represents household income"
        // Expected prose tokens: the, variable, represents, household,
        // income → 5
        let count = FormulaRegionPromoter.countProseWords(in: text)
        XCTAssertEqual(count, 5)
    }
}
