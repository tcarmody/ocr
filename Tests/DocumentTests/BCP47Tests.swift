import XCTest
@testable import Document

final class BCP47Tests: XCTestCase {

    func test_constants_have_expected_raw_values() {
        XCTAssertEqual(BCP47.en.rawValue, "en")
        XCTAssertEqual(BCP47.grc.rawValue, "grc")
        XCTAssertEqual(BCP47.la.rawValue, "la")
        XCTAssertEqual(BCP47.grcKoine.rawValue, "grc-x-koine")
        XCTAssertEqual(BCP47.laMedieval.rawValue, "la-x-medieval")
    }

    func test_string_literal_initialization() {
        let lang: BCP47 = "syr"
        XCTAssertEqual(lang.rawValue, "syr")
    }

    func test_equality_and_hashable() {
        let set: Set<BCP47> = [.en, .grc, "en"]
        XCTAssertEqual(set.count, 2)
    }
}
