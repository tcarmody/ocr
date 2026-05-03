import XCTest
@testable import Pipeline

final class DehyphenationTests: XCTestCase {

    func test_softHyphen_lowercase_is_dehyphenated() {
        XCTAssertEqual(Dehyphenation.join("Men-", "delssohn"), "Mendelssohn")
    }

    func test_hyphen_then_uppercase_keeps_hyphen() {
        // Compound word: "Anglo-Saxon" — uppercase next char keeps the hyphen.
        XCTAssertEqual(Dehyphenation.join("Anglo-", "Saxon"), "Anglo- Saxon")
    }

    func test_no_hyphen_joins_with_space() {
        XCTAssertEqual(Dehyphenation.join("Hello", "world"), "Hello world")
    }

    func test_trailing_whitespace_is_handled() {
        XCTAssertEqual(Dehyphenation.join("Men-  ", "  delssohn"), "Mendelssohn")
    }

    func test_hyphen_after_non_letter_is_kept() {
        // "1-" is a list/figure marker, not a soft hyphen — keep with space.
        XCTAssertEqual(Dehyphenation.join("1-", "introduction"), "1- introduction")
    }

    func test_empty_input_is_safe() {
        XCTAssertEqual(Dehyphenation.join("", "foo"), "foo")
        XCTAssertEqual(Dehyphenation.join("foo", ""), "foo")
    }
}
