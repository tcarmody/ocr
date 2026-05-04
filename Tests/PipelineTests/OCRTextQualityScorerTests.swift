import XCTest
@testable import Pipeline

final class OCRTextQualityScorerTests: XCTestCase {

    private let scorer = OCRTextQualityScorer()

    func test_clean_prose_scores_above_floor() throws {
        // Two sentences of normal English prose.
        let text = """
            The discourse of the eighteenth century took for granted certain
            assumptions about the nature of writing and reading. To question
            these assumptions, one had to step outside the institution of
            literature itself.
            """
        let s = try XCTUnwrap(scorer.score(text: text))
        XCTAssertGreaterThan(s.combined, 0.7,
            "clean prose should score well above the 0.5 floor; got \(s.combined)")
        XCTAssertLessThan(s.singleCharWordRatio, 0.1)
        XCTAssertLessThan(s.longWordRatio, 0.05)
    }

    func test_words_split_apart_drops_score() throws {
        // What over-aggressive OCR splitting looks like.
        let text = "Th is i s w h at h app ens w h en wo rds g et s pl it ap art b y th e en gi ne ."
        let s = try XCTUnwrap(scorer.score(text: text))
        XCTAssertLessThan(s.combined, 0.5,
            "split-apart words should fall below the floor; got \(s.combined)")
        XCTAssertGreaterThan(s.singleCharWordRatio, 0.2)
    }

    func test_words_run_together_drops_score() throws {
        // What missing-spaces OCR looks like — long concatenated
        // tokens mixed with real-looking ones.
        let text = """
            thisiswhathappenswhenwordsruntogetherinasinglepageofverydensetext
            and another runoftextwithnoseparatorsbetweenwords appears
            yetanotherrunoftextverylongindeedwithnospacingatall in the
            same andoneverymorerunofcompactedtextrightthere paragraph
            """
        let s = try XCTUnwrap(scorer.score(text: text))
        XCTAssertLessThan(s.combined, 0.5,
            "run-together words should fall below the floor; got \(s.combined)")
        XCTAssertGreaterThan(s.longWordRatio, 0.2)
    }

    /// Pure random-letter gibberish doesn't reliably trigger the
    /// scorer because `NLLanguageRecognizer` still picks *some*
    /// language for random consonant runs (often with surprising
    /// confidence). Documenting the gap; a dictionary-hit-rate
    /// signal would close it but needs shipping frequency lists.
    func test_pure_letter_gibberish_is_a_known_blind_spot() throws {
        let text = "xqz fpw mzr btvr gpkj nzqx wlmq vxbz frmt qpzn xkvr btmq gpwz nlqx"
        let s = try XCTUnwrap(scorer.score(text: text))
        // No assertion on `combined` — current scorer doesn't catch it.
        // We at least confirm it scored (i.e. crossed the min-words bar).
        XCTAssertEqual(s.totalWords, 14)
    }

    func test_short_regions_return_nil() {
        // Caption-length text — too short to score reliably.
        XCTAssertNil(scorer.score(text: "Figure 3."))
        XCTAssertNil(scorer.score(text: ""))
        XCTAssertNil(scorer.score(text: "One two three four five six seven"))
    }
}
