import XCTest
import CoreGraphics
import Document
import Layout
import OCR
@testable import Pipeline

/// Tests `RegionAwareReflow.promoteTypographicHeadings` — the per-page
/// pass that promotes `.text` regions to `.title` / `.sectionHeader`
/// when their geometry + content read as a heading even though Surya
/// labeled them as body. Companion to the cross-page recurrence pass:
/// catches one-off chapter openers and section breaks that don't
/// repeat across pages.
final class RegionAwareReflowTypographicTests: XCTestCase {

    // Page coordinates: y=0 bottom, y=1 top. (matches Surya output)

    /// Chapter opener — large centered all-caps line at the top of
    /// a page. Should promote.
    func test_centered_large_text_promotes_to_section_header() {
        // Body region: full-width text with body-sized observations.
        let bodyHeights: CGFloat = 0.020
        let bodyRegion = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.50),
            readingOrder: 1, confidence: 1.0
        )
        // Synthesize ten body observations to give a stable median.
        var observations: [TextObservation] = (0..<10).map { i in
            TextObservation(
                text: "body line \(i + 1)",
                confidence: 1.0,
                box: CGRect(
                    x: 0.10, y: 0.55 - CGFloat(i) * 0.04,
                    width: 0.80, height: bodyHeights
                ),
                source: .vision
            )
        }
        // Heading region: short, centered (midX = 0.5), narrow
        // (width = 0.30 vs body's 0.80), and ~2× the body height.
        let headingRegion = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.35, y: 0.85, width: 0.30, height: 0.05),
            readingOrder: 0, confidence: 1.0
        )
        observations.append(TextObservation(
            text: "Chapter Three",
            confidence: 1.0,
            // ×1.5 — clears the 1.4× larger-font gate but stays
            // below the 1.8× title threshold, so it lands as
            // sectionHeader.
            box: CGRect(x: 0.35, y: 0.86, width: 0.30, height: bodyHeights * 1.5),
            source: .vision
        ))

        let (out, decisions) = RegionAwareReflow.promoteTypographicHeadings(
            regions: [headingRegion, bodyRegion],
            observations: observations
        )
        XCTAssertEqual(out[0].kind, .sectionHeader)
        XCTAssertEqual(out[1].kind, .text)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertTrue(decisions[0].isCentered)
    }

    /// All-caps short text — should promote even when not perfectly
    /// centered, since the all-caps signal alone fires the heuristic.
    func test_all_caps_text_promotes_even_off_center() {
        let bodyHeights: CGFloat = 0.020
        let bodyRegion = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.50),
            readingOrder: 1, confidence: 1.0
        )
        var observations: [TextObservation] = (0..<10).map { i in
            TextObservation(
                text: "body line \(i + 1)",
                confidence: 1.0,
                box: CGRect(
                    x: 0.10, y: 0.55 - CGFloat(i) * 0.04,
                    width: 0.80, height: bodyHeights
                ),
                source: .vision
            )
        }
        // Heading: left-aligned, all-caps, larger font.
        let heading = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.85, width: 0.40, height: 0.05),
            readingOrder: 0, confidence: 1.0
        )
        observations.append(TextObservation(
            text: "PART II: THE INQUIRY",
            confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.86, width: 0.40, height: bodyHeights * 1.6),
            source: .vision
        ))

        let (out, decisions) = RegionAwareReflow.promoteTypographicHeadings(
            regions: [heading, bodyRegion],
            observations: observations
        )
        XCTAssertEqual(out[0].kind, .sectionHeader)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertTrue(decisions[0].isAllCaps)
    }

    /// Centered short text at body font size — should NOT promote.
    /// (e.g. a centered single-line quote — common but not a heading.)
    func test_centered_at_body_size_does_not_promote() {
        let bodyHeights: CGFloat = 0.020
        var observations: [TextObservation] = (0..<10).map { i in
            TextObservation(
                text: "body line \(i + 1)",
                confidence: 1.0,
                box: CGRect(
                    x: 0.10, y: 0.55 - CGFloat(i) * 0.04,
                    width: 0.80, height: bodyHeights
                ),
                source: .vision
            )
        }
        let centeredQuote = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.35, y: 0.85, width: 0.30, height: 0.04),
            readingOrder: 0, confidence: 1.0
        )
        observations.append(TextObservation(
            text: "A short centered quote",
            confidence: 1.0,
            // Same height as body — fails the larger-font signal.
            box: CGRect(x: 0.35, y: 0.86, width: 0.30, height: bodyHeights),
            source: .vision
        ))

        let (out, decisions) = RegionAwareReflow.promoteTypographicHeadings(
            regions: [centeredQuote],
            observations: observations
        )
        XCTAssertEqual(out[0].kind, .text)
        XCTAssertTrue(decisions.isEmpty)
    }

    /// Italic text — must NOT trigger promotion. Italics are inline
    /// emphasis, not heading semantics. (Per user feedback during
    /// the design discussion.)
    func test_italic_does_not_promote() {
        // We don't model italic detection from local observations
        // today — the only signals are bbox geometry + text content.
        // Confirm a body-sized italicized-looking line doesn't fire
        // any of the heading signals.
        let bodyHeights: CGFloat = 0.020
        var observations: [TextObservation] = (0..<10).map { i in
            TextObservation(
                text: "body line \(i + 1)",
                confidence: 1.0,
                box: CGRect(
                    x: 0.10, y: 0.55 - CGFloat(i) * 0.04,
                    width: 0.80, height: bodyHeights
                ),
                source: .vision
            )
        }
        let italicLine = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.10, y: 0.85, width: 0.80, height: 0.04),
            readingOrder: 0, confidence: 1.0
        )
        observations.append(TextObservation(
            text: "but I have always believed",
            confidence: 1.0,
            box: CGRect(x: 0.10, y: 0.86, width: 0.80, height: bodyHeights),
            source: .vision
        ))

        let (out, decisions) = RegionAwareReflow.promoteTypographicHeadings(
            regions: [italicLine],
            observations: observations
        )
        XCTAssertEqual(out[0].kind, .text)
        XCTAssertTrue(decisions.isEmpty)
    }

    /// Long text — even if larger and centered, > 80 chars is body-
    /// length, not a heading. Should not promote.
    func test_long_text_does_not_promote() {
        let bodyHeights: CGFloat = 0.020
        var observations: [TextObservation] = (0..<10).map { i in
            TextObservation(
                text: "body \(i + 1)",
                confidence: 1.0,
                box: CGRect(
                    x: 0.10, y: 0.55 - CGFloat(i) * 0.04,
                    width: 0.80, height: bodyHeights
                ),
                source: .vision
            )
        }
        let longRegion = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.35, y: 0.85, width: 0.30, height: 0.05),
            readingOrder: 0, confidence: 1.0
        )
        observations.append(TextObservation(
            text: String(repeating: "ABCDEFGHIJ ", count: 12),  // > 80 chars
            confidence: 1.0,
            box: CGRect(x: 0.35, y: 0.86, width: 0.30, height: bodyHeights * 2),
            source: .vision
        ))

        let (out, _) = RegionAwareReflow.promoteTypographicHeadings(
            regions: [longRegion],
            observations: observations
        )
        XCTAssertEqual(out[0].kind, .text)
    }

    /// Already-`.title` regions: no-op — promotion only operates on
    /// `.text`, doesn't touch what Surya already classified.
    func test_already_a_title_is_left_alone() {
        let bodyHeights: CGFloat = 0.020
        var observations: [TextObservation] = (0..<10).map { i in
            TextObservation(
                text: "body \(i + 1)",
                confidence: 1.0,
                box: CGRect(
                    x: 0.10, y: 0.55 - CGFloat(i) * 0.04,
                    width: 0.80, height: bodyHeights
                ),
                source: .vision
            )
        }
        let alreadyTitle = LayoutRegion(
            kind: .title,
            box: CGRect(x: 0.35, y: 0.85, width: 0.30, height: 0.05),
            readingOrder: 0, confidence: 1.0
        )
        observations.append(TextObservation(
            text: "CHAPTER 7",
            confidence: 1.0,
            box: CGRect(x: 0.35, y: 0.86, width: 0.30, height: bodyHeights * 2),
            source: .vision
        ))
        let (out, decisions) = RegionAwareReflow.promoteTypographicHeadings(
            regions: [alreadyTitle],
            observations: observations
        )
        XCTAssertEqual(out[0].kind, .title)
        XCTAssertTrue(decisions.isEmpty)
    }

    /// Very-tall heading (1.8× page median) → promote to `.title`,
    /// not `.sectionHeader`.
    func test_very_tall_heading_promotes_to_title() {
        let bodyHeights: CGFloat = 0.020
        var observations: [TextObservation] = (0..<10).map { i in
            TextObservation(
                text: "body \(i + 1)",
                confidence: 1.0,
                box: CGRect(
                    x: 0.10, y: 0.55 - CGFloat(i) * 0.04,
                    width: 0.80, height: bodyHeights
                ),
                source: .vision
            )
        }
        let bigHeading = LayoutRegion(
            kind: .text,
            box: CGRect(x: 0.35, y: 0.85, width: 0.30, height: 0.08),
            readingOrder: 0, confidence: 1.0
        )
        observations.append(TextObservation(
            text: "INTRODUCTION",
            confidence: 1.0,
            box: CGRect(x: 0.35, y: 0.86, width: 0.30, height: bodyHeights * 2.2),
            source: .vision
        ))
        let (out, _) = RegionAwareReflow.promoteTypographicHeadings(
            regions: [bigHeading],
            observations: observations
        )
        XCTAssertEqual(out[0].kind, .title)
    }
}
