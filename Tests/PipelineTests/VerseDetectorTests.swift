import XCTest
import Document
import OCR
@testable import Pipeline

/// P-Verse-Layout. The detector must be conservatively biased
/// toward "this is prose" — false positives on academic prose
/// would garble whole chapters. Tests cover both the verse-
/// recognition path on synthesized Pound-shaped input and the
/// rejection path on multiple flavors of prose-shaped input.
final class VerseDetectorTests: XCTestCase {

    // MARK: - Positive cases

    func test_detects_pound_shaped_verse() {
        // Six lines that mimic the sample Canto page: ragged
        // right margin, irregular leading indents, no
        // line-terminal punctuation pattern, mean line shorter
        // than region width.
        let region = CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.40)
        let observations: [TextObservation] = [
            line(text: "Click of the hooves, through garbage,",
                 atY: 0.48, leadingX: 0.05, width: 0.55),
            line(text: "Clutching the greasy stone",
                 atY: 0.43, leadingX: 0.05, width: 0.35),
            line(text: "Slander is up betimes",
                 atY: 0.38, leadingX: 0.05, width: 0.30),
            line(text: "But Varchi of Florence",
                 atY: 0.33, leadingX: 0.20, width: 0.40),
            line(text: "Steeped in a different year",
                 atY: 0.28, leadingX: 0.05, width: 0.45),
            line(text: "And the cloak floated",
                 atY: 0.23, leadingX: 0.30, width: 0.30),
        ]
        let verdict = VerseDetector.detect(
            observations: observations, regionBox: region
        )
        XCTAssertNotNil(verdict, "Pound-shaped input should detect as verse")
        XCTAssertEqual(verdict?.lines.count, 6)
        // Indented line ("But Varchi") should land in a non-zero
        // bucket; flush-left lines should be bucket 0.
        let buckets = verdict?.lines.map(\.indent) ?? []
        XCTAssertEqual(buckets[0], 0, "flush-left line is bucket 0")
        XCTAssertGreaterThan(buckets[3], 0, "indented line is past bucket 0")
    }

    func test_detects_verse_with_greek_fragment() {
        // Mixed-script line: detector should split into a Latin
        // run + a Greek run with lang="grc".
        let region = CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.40)
        let observations: [TextObservation] = [
            line(text: "Click of the hooves",
                 atY: 0.48, leadingX: 0.05, width: 0.35),
            line(text: "Clutching the greasy stone",
                 atY: 0.43, leadingX: 0.05, width: 0.35),
            line(text: "Slander is up betimes",
                 atY: 0.38, leadingX: 0.05, width: 0.30),
            line(text: "Then Σίγα μαλ αὖθις δευτέραν",
                 atY: 0.33, leadingX: 0.20, width: 0.55),
            line(text: "Whether for love of Florence",
                 atY: 0.28, leadingX: 0.20, width: 0.40),
        ]
        let verdict = VerseDetector.detect(
            observations: observations, regionBox: region
        )
        XCTAssertNotNil(verdict)
        // The mixed line should have at least 2 runs — one Latin,
        // one Greek with language tag.
        let mixedLine = verdict?.lines[3]
        XCTAssertNotNil(mixedLine)
        let langs = mixedLine?.runs.compactMap(\.language) ?? []
        XCTAssertTrue(
            langs.contains(BCP47("grc")),
            "Greek codepoints should produce a lang=\"grc\" run"
        )
    }

    // MARK: - Negative cases

    func test_rejects_full_width_prose() {
        // 8 lines of prose-shaped observations: each line reaches
        // the right margin, leading-x is uniform, terminal
        // punctuation present.
        let region = CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.50)
        var observations: [TextObservation] = []
        for i in 0..<8 {
            let y = 0.55 - CGFloat(i) * 0.05
            let isLast = (i == 7)
            observations.append(line(
                text: isLast
                    ? "It was the best of times, it was the worst."
                    : "It was the best of times, it was the worst of",
                atY: y, leadingX: 0.05, width: 0.85
            ))
        }
        XCTAssertNil(
            VerseDetector.detect(
                observations: observations, regionBox: region
            ),
            "Full-width prose must not detect as verse"
        )
    }

    func test_rejects_short_region_with_few_lines() {
        // 3 lines — below the minimum count. Should reject even
        // if every other signal screams "verse."
        let region = CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.20)
        let observations: [TextObservation] = [
            line(text: "Roses are red",
                 atY: 0.25, leadingX: 0.05, width: 0.20),
            line(text: "Violets are blue",
                 atY: 0.20, leadingX: 0.30, width: 0.25),
            line(text: "Pithy and short",
                 atY: 0.15, leadingX: 0.05, width: 0.20),
        ]
        XCTAssertNil(VerseDetector.detect(
            observations: observations, regionBox: region
        ))
    }

    func test_rejects_prose_with_first_line_indent() {
        // 6 lines where only the first is indented (a common
        // prose pattern). Indent-variance signal will fail.
        let region = CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.40)
        var observations: [TextObservation] = []
        for i in 0..<6 {
            let y = 0.50 - CGFloat(i) * 0.05
            let lead: CGFloat = i == 0 ? 0.10 : 0.05
            observations.append(line(
                text: "Lorem ipsum dolor sit amet consectetur",
                atY: y, leadingX: lead, width: 0.85 - (lead - 0.05)
            ))
        }
        XCTAssertNil(VerseDetector.detect(
            observations: observations, regionBox: region
        ))
    }

    // MARK: - Indent quantization

    func test_indent_quantization_buckets() {
        // Flush-left → 0.
        XCTAssertEqual(VerseDetector.quantizeIndent(fraction: 0.0), 0)
        XCTAssertEqual(VerseDetector.quantizeIndent(fraction: 0.04), 0)
        // Mid-region → non-zero bucket; high end → 8.
        XCTAssertGreaterThan(
            VerseDetector.quantizeIndent(fraction: 0.30), 0
        )
        XCTAssertEqual(VerseDetector.quantizeIndent(fraction: 1.00), 8)
        // Clamp at the boundary.
        XCTAssertEqual(VerseDetector.quantizeIndent(fraction: 1.50), 8)
    }

    // MARK: - Helpers

    /// Mint a synthetic TextObservation that places the given
    /// text at `(leadingX, atY)` with the given `width` in
    /// normalized coords. y is the line's midY; height is fixed.
    private func line(
        text: String, atY: CGFloat, leadingX: CGFloat, width: CGFloat
    ) -> TextObservation {
        let h: CGFloat = 0.03
        return TextObservation(
            text: text,
            confidence: 0.95,
            box: CGRect(
                x: leadingX, y: atY - h / 2,
                width: width, height: h
            )
        )
    }
}
