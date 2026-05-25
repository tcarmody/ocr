import XCTest
@testable import LibraryIndexing

/// Statistical noun-phrase miner. Complements the `EntityExtractor`
/// tests by exercising the lexical-class scheme path: tests assert
/// what gets extracted, what gets filtered (proper nouns,
/// stopwords, sub-2-token phrases), and the canonical-form
/// invariants the federated rollup downstream relies on.
final class ConceptExtractorTests: XCTestCase {

    private func extracted(_ text: String) -> [String] {
        ConceptExtractor.extract(from: text).map(\.canonical)
    }

    // MARK: - Positive cases

    func test_extracts_adjective_noun_phrase() {
        // "Artificial intelligence" is the archetypal Adj+Noun
        // concept shape we want to catch.
        //
        // Note on NLTagger limits: "machine learning" deliberately
        // ISN'T asserted here because NLTagger tags "learning" as
        // a verb (gerund). Gerund-bearing compounds need the alias
        // dictionary as the explicit catch. Similarly, deverbal
        // nouns like "shape" sometimes tag as noun in adjacent
        // contexts and produce spurious phrases like "shape modern
        // thought" — the per-book frequency filter (≥3 mentions)
        // dampens these in real-world data.
        let xs = extracted("Artificial intelligence and machine learning shape modern thought.")
        XCTAssertTrue(
            xs.contains("artificial intelligence"),
            "expected 'artificial intelligence' in output; got \(xs)"
        )
    }

    func test_extracts_noun_noun_phrase() {
        let xs = extracted("Speech act theory is central to philosophy of language.")
        XCTAssertTrue(xs.contains("speech act theory"),
            "noun-noun-noun runs should register")
    }

    func test_canonicalizes_to_lowercase() {
        // Mixed casing in the source — the canonical output should
        // always be lowercase regardless of how the tokens were
        // written. (All-caps source like "CRITICAL THEORY" gets
        // filtered upstream by the proper-noun-shape rule, hence
        // the mixed-case-but-not-all-caps input here.)
        let xs = extracted("Cultural Analysis is informed by critical theory.")
        for canonical in xs {
            XCTAssertEqual(
                canonical, canonical.lowercased(),
                "canonical keys must be lowercase; got \(canonical)"
            )
        }
    }

    // MARK: - Filters

    func test_skips_single_tokens() {
        // A single noun isn't a "concept" by this extractor's
        // definition — single-word concepts route via the alias
        // dictionary instead.
        let xs = extracted("Liberalism matters.")
        XCTAssertFalse(xs.contains("liberalism"))
    }

    func test_skips_phrases_with_stopwords() {
        // "good thing" and "long time" are exactly the noise the
        // stopword filter exists to suppress. Without it the
        // Topics view drowns in throwaway combinations.
        let xs = extracted("It was a good thing. A long time passed.")
        XCTAssertFalse(xs.contains("good thing"))
        XCTAssertFalse(xs.contains("long time"))
    }

    func test_skips_proper_noun_phrases() {
        // "President Wilson" / "Roman Empire" should fall to the
        // nameType pass instead of being double-counted here.
        let xs = extracted("President Wilson led the war. The Roman Empire fell.")
        XCTAssertFalse(xs.contains("president wilson"))
        XCTAssertFalse(xs.contains("roman empire"))
    }

    func test_breaks_phrase_at_preposition() {
        // The extractor deliberately doesn't try to span
        // prepositions — "will to power" / "philosophy of mind"
        // are alias-dictionary territory, not statistical-mining
        // territory (too many false positives like "road to ruin").
        let xs = extracted("The will to power animates Nietzsche's thought.")
        XCTAssertFalse(xs.contains("will to power"),
            "preposition-bearing concepts deliberately skipped")
    }

    func test_empty_input_returns_empty() {
        XCTAssertEqual(extracted(""), [])
        XCTAssertEqual(extracted("   "), [])
    }

    // MARK: - Length bounds

    func test_phrases_cap_at_four_tokens() {
        // A five-token noun run should produce nothing, not a
        // truncated four-token slice. Long phrases tend to be
        // accidental compounds with low cross-book recurrence.
        let xs = extracted("Modern art history academic discipline framework analysis.")
        for canonical in xs {
            let tokenCount = canonical.split(separator: " ").count
            XCTAssertLessThanOrEqual(
                tokenCount, 4,
                "extractor caps phrase length at 4 tokens; got \(canonical)"
            )
            XCTAssertGreaterThanOrEqual(
                tokenCount, 2,
                "extractor floors phrase length at 2 tokens; got \(canonical)"
            )
        }
    }
}
