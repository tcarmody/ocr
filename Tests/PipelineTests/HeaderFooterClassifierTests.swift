import XCTest
import CoreGraphics
import OCR
@testable import Pipeline

final class HeaderFooterClassifierTests: XCTestCase {

    // MARK: - normalization helpers

    func test_normalize_collapses_digit_runs() {
        XCTAssertEqual(HeaderFooterClassifier.normalize("Chapter 3 — Foucault"),
                       "chapter # — foucault")
        XCTAssertEqual(HeaderFooterClassifier.normalize("Chapter 12 — Foucault"),
                       "chapter # — foucault")
    }

    func test_isPageNumberLike_arabic_and_roman() {
        XCTAssertTrue(HeaderFooterClassifier.isPageNumberLike("42"))
        XCTAssertTrue(HeaderFooterClassifier.isPageNumberLike("— 42 —"))
        XCTAssertTrue(HeaderFooterClassifier.isPageNumberLike("xiv"))
        XCTAssertTrue(HeaderFooterClassifier.isPageNumberLike("XII"))
        XCTAssertFalse(HeaderFooterClassifier.isPageNumberLike("42 introduction"))
        XCTAssertFalse(HeaderFooterClassifier.isPageNumberLike(""))
    }

    // MARK: - Rule 1: page-number drops

    func test_drops_page_numbers_in_top_or_bottom_zone() {
        let bodies = [
            "the first page contains its own unique paragraph",
            "the second page covers a different topic entirely",
            "the third page introduces yet another subject",
            "the fourth page concludes with a final argument",
        ]
        let pages: [PageObservations] = (0..<4).map { i in
            PageObservations(
                pageIndex: i,
                pageBounds: CGSize(width: 612, height: 792),
                observations: [
                    obs(bodies[i], at: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.02)),
                    obs(String(i + 1), at: CGRect(x: 0.5, y: 0.04, width: 0.05, height: 0.02)),
                ]
            )
        }
        let drop = HeaderFooterClassifier().classify(pages)
        for i in 0..<4 {
            XCTAssertTrue(drop.contains(.init(pageIndex: i, observationIndex: 1)),
                          "Page number on page \(i) should be dropped")
            XCTAssertFalse(drop.contains(.init(pageIndex: i, observationIndex: 0)),
                           "Unique body text on page \(i) should be kept")
        }
    }

    func test_drops_short_text_containing_digit_in_zone() {
        // "p. 12" / "page 5" — short, in zone, has digit. Body text is
        // unique per page so it doesn't trip the recurrence rule.
        let bodyWords = ["alpha bravo charlie", "delta echo foxtrot",
                         "golf hotel india", "juliet kilo lima",
                         "mike november oscar"]
        let bodies = bodyWords
        let pages: [PageObservations] = (0..<5).map { i in
            PageObservations(
                pageIndex: i,
                pageBounds: CGSize(width: 612, height: 792),
                observations: [
                    obs("p. \(i + 1)", at: CGRect(x: 0.5, y: 0.04, width: 0.06, height: 0.02)),
                    obs(bodies[i], at: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.02)),
                ]
            )
        }
        let drop = HeaderFooterClassifier().classify(pages)
        for i in 0..<5 {
            XCTAssertTrue(drop.contains(.init(pageIndex: i, observationIndex: 0)),
                          "Short 'p. N' in footer zone should be dropped on page \(i)")
            XCTAssertFalse(drop.contains(.init(pageIndex: i, observationIndex: 1)),
                           "Unique body text should be kept on page \(i)")
        }
    }

    func test_does_not_drop_page_numbers_in_body_region() {
        // A bare "42" sitting in the middle of the page — could be a
        // legitimate body number, not a page number. Should NOT be dropped.
        let pages: [PageObservations] = (0..<5).map { i in
            PageObservations(
                pageIndex: i,
                pageBounds: CGSize(width: 612, height: 792),
                observations: [
                    obs("42", at: CGRect(x: 0.5, y: 0.50, width: 0.05, height: 0.02)),
                ]
            )
        }
        let drop = HeaderFooterClassifier().classify(pages)
        for i in 0..<5 {
            XCTAssertFalse(drop.contains(.init(pageIndex: i, observationIndex: 0)),
                           "Bare digit in body region should not be classified as page number on page \(i)")
        }
    }

    // MARK: - Rule 2: position-clustered recurrence

    func test_drops_running_head_recurring_at_same_y_band_across_pages() {
        // 5 pages, each with a running head whose page number differs.
        // After digit-collapse normalization, all five running heads
        // share the same key. Body text is genuinely unique per page.
        let bodies = [
            "alpha bravo charlie delta",
            "echo foxtrot golf hotel",
            "india juliet kilo lima",
            "mike november oscar papa",
            "quebec romeo sierra tango",
        ]
        let pages: [PageObservations] = (0..<5).map { i in
            PageObservations(
                pageIndex: i,
                pageBounds: CGSize(width: 612, height: 792),
                observations: [
                    obs("\(304 + i) Ethics: Subjectivity and Truth",
                        at: CGRect(x: 0.1, y: 0.93, width: 0.5, height: 0.02)),
                    obs(bodies[i],
                        at: CGRect(x: 0.1, y: 0.50, width: 0.6, height: 0.02)),
                ]
            )
        }
        let drop = HeaderFooterClassifier().classify(pages)
        for i in 0..<5 {
            XCTAssertTrue(drop.contains(.init(pageIndex: i, observationIndex: 0)),
                          "Running head with embedded page number should be dropped on page \(i)")
            XCTAssertFalse(drop.contains(.init(pageIndex: i, observationIndex: 1)),
                           "Unique body text should be kept on page \(i)")
        }
    }

    func test_position_clustering_works_anywhere_on_page() {
        // Running head at y=0.78 — outside the 20% top zone (zone is
        // y > 0.80). Recurrence on 5 pages at the same y band → drop.
        // Each page gets unique body content so only the running head
        // clusters across pages.
        let bodyWords: [[String]] = [
            ["alpha","bravo","charlie","delta","echo","foxtrot","golf","hotel"],
            ["india","juliet","kilo","lima","mike","november","oscar","papa"],
            ["quebec","romeo","sierra","tango","uniform","victor","whiskey","xray"],
            ["yankee","zulu","one","two","three","four","five","six"],
            ["seven","eight","nine","ten","eleven","twelve","thirteen","fourteen"],
        ]
        let pages: [PageObservations] = (0..<5).map { i in
            var obsList: [TextObservation] = [
                obs("Foucault — Enlightenment",
                    at: CGRect(x: 0.1, y: 0.78, width: 0.5, height: 0.025)),
            ]
            for j in 0..<8 {
                obsList.append(obs(
                    bodyWords[i][j],
                    at: CGRect(x: 0.1, y: 0.65 - CGFloat(j) * 0.05, width: 0.8, height: 0.025)
                ))
            }
            return PageObservations(
                pageIndex: i, pageBounds: .init(width: 612, height: 792), observations: obsList
            )
        }
        let drop = HeaderFooterClassifier().classify(pages)
        for i in 0..<5 {
            XCTAssertTrue(drop.contains(.init(pageIndex: i, observationIndex: 0)),
                          "Recurring text at consistent y should be dropped regardless of zone (page \(i))")
        }
    }

    func test_keeps_unique_text_that_does_not_recur() {
        // Title page with unique header text — should not be dropped.
        let unique = obs("BOOK TITLE", at: CGRect(x: 0.1, y: 0.93, width: 0.4, height: 0.04))
        let pages: [PageObservations] = [
            PageObservations(pageIndex: 0, pageBounds: .init(width: 612, height: 792), observations: [unique]),
            PageObservations(pageIndex: 1, pageBounds: .init(width: 612, height: 792), observations: [
                obs("Chapter 1", at: CGRect(x: 0.1, y: 0.93, width: 0.2, height: 0.02))
            ]),
            PageObservations(pageIndex: 2, pageBounds: .init(width: 612, height: 792), observations: [
                obs("Chapter 2", at: CGRect(x: 0.1, y: 0.93, width: 0.2, height: 0.02))
            ]),
        ]
        let drop = HeaderFooterClassifier().classify(pages)
        XCTAssertFalse(drop.contains(.init(pageIndex: 0, observationIndex: 0)),
                       "Unique title-page header should NOT be dropped")
    }

    func test_does_not_cluster_body_text_across_pages_at_different_y_bands() {
        // Same phrase appears on multiple pages but at different
        // vertical positions (not a header/footer pattern). Should NOT
        // cluster — y-band mismatch.
        let pages: [PageObservations] = [
            PageObservations(pageIndex: 0, pageBounds: .init(width: 612, height: 792), observations: [
                obs("recurring phrase in body", at: CGRect(x: 0.1, y: 0.30, width: 0.6, height: 0.025))
            ]),
            PageObservations(pageIndex: 1, pageBounds: .init(width: 612, height: 792), observations: [
                obs("recurring phrase in body", at: CGRect(x: 0.1, y: 0.55, width: 0.6, height: 0.025))
            ]),
            PageObservations(pageIndex: 2, pageBounds: .init(width: 612, height: 792), observations: [
                obs("recurring phrase in body", at: CGRect(x: 0.1, y: 0.70, width: 0.6, height: 0.025))
            ]),
        ]
        let drop = HeaderFooterClassifier().classify(pages)
        for i in 0..<3 {
            XCTAssertFalse(drop.contains(.init(pageIndex: i, observationIndex: 0)),
                           "Body text at varying y positions should not cluster (page \(i))")
        }
    }

    // MARK: - Rule 3: footnote drop

    func test_drops_footnote_starting_with_asterisk_in_lower_zone() {
        // Single-page document with a footnote at the bottom. Even
        // below the recurrence threshold, Rule 3 should fire.
        let pages: [PageObservations] = [
            PageObservations(
                pageIndex: 0,
                pageBounds: .init(width: 612, height: 792),
                observations: [
                    obs("body line one of the page",
                        at: CGRect(x: 0.1, y: 0.7, width: 0.7, height: 0.025)),
                    obs("body line two of the page",
                        at: CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.025)),
                    obs("*This translation, by Catherine Porter, has been amended.",
                        at: CGRect(x: 0.1, y: 0.20, width: 0.7, height: 0.020)),
                ]
            )
        ]
        let drop = HeaderFooterClassifier().classify(pages)
        XCTAssertTrue(drop.contains(.init(pageIndex: 0, observationIndex: 2)),
                      "Footnote starting with * in lower zone should be dropped")
        XCTAssertFalse(drop.contains(.init(pageIndex: 0, observationIndex: 0)))
        XCTAssertFalse(drop.contains(.init(pageIndex: 0, observationIndex: 1)))
    }

    func test_footnote_drop_cascades_to_observations_below_marker() {
        // Multi-line footnote: marker on the first footnote line, body
        // continues for several more lines below. Drop everything below
        // the marker on this page.
        let pages: [PageObservations] = [
            PageObservations(
                pageIndex: 0,
                pageBounds: .init(width: 612, height: 792),
                observations: [
                    obs("body content above the footnote",
                        at: CGRect(x: 0.1, y: 0.50, width: 0.7, height: 0.025)),
                    obs("*A long footnote that spans",
                        at: CGRect(x: 0.1, y: 0.20, width: 0.7, height: 0.020)),
                    obs("multiple lines of small print",
                        at: CGRect(x: 0.1, y: 0.16, width: 0.7, height: 0.020)),
                    obs("and concludes with this remark.",
                        at: CGRect(x: 0.1, y: 0.12, width: 0.7, height: 0.020)),
                ]
            )
        ]
        let drop = HeaderFooterClassifier().classify(pages)
        XCTAssertFalse(drop.contains(.init(pageIndex: 0, observationIndex: 0)),
                       "Body above the footnote stays")
        XCTAssertTrue(drop.contains(.init(pageIndex: 0, observationIndex: 1)),
                      "Footnote marker line dropped")
        XCTAssertTrue(drop.contains(.init(pageIndex: 0, observationIndex: 2)),
                      "Footnote continuation line 1 dropped")
        XCTAssertTrue(drop.contains(.init(pageIndex: 0, observationIndex: 3)),
                      "Footnote continuation line 2 dropped")
    }

    func test_does_not_drop_asterisk_starts_in_body_zone() {
        // An asterisk-starting line that's high on the page (body zone)
        // is not a footnote — leave it.
        let pages: [PageObservations] = [
            PageObservations(
                pageIndex: 0,
                pageBounds: .init(width: 612, height: 792),
                observations: [
                    obs("*starred body emphasis at top of page",
                        at: CGRect(x: 0.1, y: 0.80, width: 0.7, height: 0.025)),
                    obs("more body text",
                        at: CGRect(x: 0.1, y: 0.50, width: 0.7, height: 0.025)),
                ]
            )
        ]
        let drop = HeaderFooterClassifier().classify(pages)
        XCTAssertFalse(drop.contains(.init(pageIndex: 0, observationIndex: 0)),
                       "Asterisk in body zone should not trigger footnote drop")
    }

    // MARK: - short corpus

    func test_short_corpus_only_drops_pure_page_numbers() {
        let pages: [PageObservations] = [
            PageObservations(pageIndex: 0, pageBounds: .init(width: 612, height: 792), observations: [
                obs("Running Head", at: CGRect(x: 0.1, y: 0.95, width: 0.3, height: 0.02)),
                obs("1", at: CGRect(x: 0.5, y: 0.04, width: 0.02, height: 0.02)),
            ]),
            PageObservations(pageIndex: 1, pageBounds: .init(width: 612, height: 792), observations: [
                obs("Running Head", at: CGRect(x: 0.1, y: 0.95, width: 0.3, height: 0.02)),
                obs("2", at: CGRect(x: 0.5, y: 0.04, width: 0.02, height: 0.02)),
            ]),
        ]
        let drop = HeaderFooterClassifier().classify(pages)
        XCTAssertTrue(drop.contains(.init(pageIndex: 0, observationIndex: 1)))
        XCTAssertTrue(drop.contains(.init(pageIndex: 1, observationIndex: 1)))
        XCTAssertFalse(drop.contains(.init(pageIndex: 0, observationIndex: 0)),
                       "Below recurrence threshold — running head stays")
    }

    // MARK: helper
    private func obs(_ text: String, at box: CGRect) -> TextObservation {
        TextObservation(text: text, confidence: 0.95, box: box)
    }
}
