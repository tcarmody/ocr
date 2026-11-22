import XCTest
@testable import Pipeline

/// Post-processing for the on-device metadata extractor. The model
/// call itself isn't exercised here; these pin the filters that stop
/// placeholder and made-up values from reaching the book's metadata.
final class AppleFoundationModelMetadataExtractorTests: XCTestCase {

    typealias Result = ClaudeMetadataExtractor.Result
    typealias AFM = AppleFoundationModelMetadataExtractor

    static let frontMatter = """
        THE HUMANIST TRADITION
        Essays on Reading

        Maria Okafor and   Daniel
        Weiss

        Oxford University Press
        First published 1998. Reprinted 2004.
        ISBN 0-19-852663-6
        """

    // MARK: - Placeholder filter (shared with the Cloud path)

    func test_placeholder_words_become_nil() {
        for s in ["nil", "NULL", "None", "N/A", "unknown", "Not visible",
                  "\"nil\"", " nil. "] {
            XCTAssertNil(ClaudeMetadataExtractor.nilIfEmpty(s), s)
        }
    }

    func test_prompt_format_example_becomes_nil() {
        XCTAssertNil(ClaudeMetadataExtractor.nilIfEmpty(
            "FirstName LastName, OtherName OtherLastName"
        ))
        XCTAssertNil(ClaudeMetadataExtractor.nilIfEmpty("FirstName LastName"))
    }

    func test_real_values_containing_placeholder_words_survive() {
        XCTAssertEqual(
            ClaudeMetadataExtractor.nilIfEmpty("And Then There Were None"),
            "And Then There Were None"
        )
        XCTAssertEqual(
            ClaudeMetadataExtractor.nilIfEmpty("  The Unknown Masterpiece "),
            "The Unknown Masterpiece"
        )
    }

    // MARK: - Grounding

    func test_grounded_keeps_values_present_in_source() {
        let r = AFM.grounded(Result(
            title: "The Humanist Tradition",
            author: "Maria Okafor, Daniel Weiss",
            year: "1998",
            publisher: "Oxford University Press",
            isbn: "0198526636"
        ), in: Self.frontMatter)
        XCTAssertEqual(r.title, "The Humanist Tradition")  // case-insensitive
        XCTAssertEqual(r.author, "Maria Okafor, Daniel Weiss")  // across a line break
        XCTAssertEqual(r.year, "1998")
        XCTAssertEqual(r.publisher, "Oxford University Press")
        XCTAssertEqual(r.isbn, "0198526636")  // hyphens in the source
    }

    func test_grounded_drops_values_missing_from_source() {
        // What the on-device model returned for a page with no
        // author, year or publisher.
        let r = AFM.grounded(Result(
            title: "The Humanist",
            author: "Jane Smith",
            year: "2003",
            publisher: "Penguin",
            isbn: "9780140449136"
        ), in: Self.frontMatter)
        XCTAssertEqual(r.title, "The Humanist")
        XCTAssertNil(r.author)
        XCTAssertNil(r.year)
        XCTAssertNil(r.publisher)
        XCTAssertNil(r.isbn)
    }

    func test_grounded_author_needs_every_name() {
        let r = AFM.grounded(
            Result(author: "Maria Okafor and Someone Else"), in: Self.frontMatter
        )
        XCTAssertNil(r.author)
        let amp = AFM.grounded(
            Result(author: "Maria Okafor & Daniel Weiss"), in: Self.frontMatter
        )
        XCTAssertEqual(amp.author, "Maria Okafor & Daniel Weiss")
    }

    func test_grounded_year_must_be_a_standalone_number() {
        // "1998" is in the source; "999" only as part of it.
        XCTAssertEqual(AFM.grounded(Result(year: "2004"), in: Self.frontMatter).year, "2004")
        XCTAssertNil(AFM.grounded(Result(year: "1999"), in: Self.frontMatter).year)
        XCTAssertNil(AFM.grounded(Result(year: "9985"), in: "ISBN 0-19-852663-6 (19985)").year)
    }

    func test_grounded_matches_curly_quotes() {
        let r = AFM.grounded(
            Result(title: "Reader's Guide"), in: "The Reader\u{2019}s Guide, 2nd ed."
        )
        XCTAssertEqual(r.title, "Reader's Guide")
    }

    func test_prompt_has_no_copyable_sample_values() {
        XCTAssertFalse(AFM.instructions.contains("FirstName"))
        XCTAssertFalse(AFM.instructions.contains("\"2003\""))
    }
}
