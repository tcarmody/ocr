import XCTest
@testable import EPUB

/// Coverage for `Slug.fromHeading` — the filename-slug helper used
/// by R-Content-Aware-Rename (manual rename command + future
/// auto-on-split path). Each test pins one rule from the slug
/// spec; together they pin the contract.
final class SlugTests: XCTestCase {

    // MARK: - Happy path

    func test_basic_words_become_hyphenated() {
        XCTAssertEqual(
            Slug.fromHeading("On the Program of the Coming Philosophy"),
            "On-the-Program-of-the-Coming-Philosophy"
        )
    }

    func test_single_word_passes_through_unchanged() {
        XCTAssertEqual(Slug.fromHeading("Introduction"), "Introduction")
    }

    func test_preserves_letter_case() {
        // Slug doesn't force lowercase — the user might want the
        // case the heading was set in. The existing rename UI
        // accepts mixed-case basenames.
        XCTAssertEqual(Slug.fromHeading("OCR Pipeline"), "OCR-Pipeline")
    }

    // MARK: - HTML / entities

    func test_strips_html_tags() {
        XCTAssertEqual(
            Slug.fromHeading("<em>The</em> Mirror <strong>Stage</strong>"),
            "The-Mirror-Stage"
        )
    }

    func test_decodes_basic_html_entities() {
        // &amp; decodes to '&'; the whitelist filter drops it; the
        // hyphen-collapse step merges the surrounding "Cats-" and
        // "-Dogs" into "Cats-Dogs".
        XCTAssertEqual(
            Slug.fromHeading("Cats &amp; Dogs"),
            "Cats-Dogs"
        )
        XCTAssertEqual(
            Slug.fromHeading("Title &nbsp; Subtitle"),
            "Title-Subtitle"
        )
    }

    func test_decodes_apostrophe_entities_then_strips() {
        // &apos; / &#39; decode to ', which we then drop. The
        // result reads cleanly without URL encoding noise.
        XCTAssertEqual(
            Slug.fromHeading("Kafka&apos;s Trial"),
            "Kafkas-Trial"
        )
        XCTAssertEqual(
            Slug.fromHeading("It&#39;s a Title"),
            "Its-a-Title"
        )
    }

    // MARK: - Filesystem-breaking characters

    func test_strips_path_separators_and_meta_chars() {
        XCTAssertEqual(
            Slug.fromHeading("Yes/No: A Question?"),
            "YesNo-A-Question"
        )
    }

    func test_strips_pipe_and_glob_chars() {
        XCTAssertEqual(
            Slug.fromHeading("Mr. Smith | Star * Glob"),
            "Mr.-Smith-Star-Glob"
        )
    }

    // MARK: - Apostrophes + smart quotes

    func test_strips_curly_quotes_and_apostrophes() {
        XCTAssertEqual(
            Slug.fromHeading("\u{201C}On the Concept of History\u{201D}"),
            "On-the-Concept-of-History"
        )
        XCTAssertEqual(
            Slug.fromHeading("Lacan\u{2019}s Mirror"),
            "Lacans-Mirror"
        )
    }

    // MARK: - Whitespace collapse

    func test_collapses_tabs_and_newlines_to_hyphens() {
        XCTAssertEqual(
            Slug.fromHeading("Title\twith\ntabs\nand\nnewlines"),
            "Title-with-tabs-and-newlines"
        )
    }

    func test_collapses_internal_whitespace_runs() {
        XCTAssertEqual(
            Slug.fromHeading("Spaces      with         padding"),
            "Spaces-with-padding"
        )
    }

    func test_collapses_consecutive_hyphens_from_adjacent_stripped_punctuation() {
        // "Part I — The Method" → whitespace becomes hyphens
        // ("Part-I-—-The-Method") → em-dash gets dropped by the
        // whitelist filter → consecutive hyphens collapse →
        // "Part-I-The-Method".
        XCTAssertEqual(
            Slug.fromHeading("Part I \u{2014} The Method"),
            "Part-I-The-Method"
        )
        XCTAssertEqual(
            Slug.fromHeading("Cats & Dogs"),
            "Cats-Dogs",
            "ampersand drops; surrounding hyphens collapse"
        )
    }

    // MARK: - Trimming

    func test_trims_leading_and_trailing_hyphens() {
        // Pathological input where the heading was set up with
        // stripped punctuation flanking the actual title.
        XCTAssertEqual(
            Slug.fromHeading("   On Method   "),
            "On-Method"
        )
    }

    // MARK: - Empty results

    func test_returns_nil_for_empty_input() {
        XCTAssertNil(Slug.fromHeading(""))
    }

    func test_returns_nil_for_punctuation_only_heading() {
        XCTAssertNil(Slug.fromHeading("///\"\\\":?"))
    }

    func test_returns_nil_for_tags_only_heading() {
        XCTAssertNil(Slug.fromHeading("<em></em><strong></strong>"))
    }

    func test_returns_nil_for_whitespace_only_heading() {
        XCTAssertNil(Slug.fromHeading("   \t\n  "))
    }

    // MARK: - Length cap

    func test_truncates_long_input_at_hyphen_boundary() {
        // 100-word heading. Slug truncates at last hyphen ≤ 80 chars.
        let longTitle = (0..<20).map { "word\($0)" }.joined(separator: " ")
        let slug = Slug.fromHeading(longTitle)!
        XCTAssertLessThanOrEqual(slug.count, Slug.maxLength)
        // Truncated cleanly at a hyphen — not mid-word — so the
        // last character is a letter / digit, not a hyphen.
        XCTAssertFalse(slug.hasSuffix("-"))
        XCTAssertTrue(slug.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
    }

    func test_truncates_single_huge_word_with_hard_cut() {
        // No hyphens to truncate at — falls through to hard cut.
        let huge = String(repeating: "a", count: 200)
        let slug = Slug.fromHeading(huge)!
        XCTAssertEqual(slug.count, Slug.maxLength)
    }
}
