import XCTest
@testable import Humanist

/// R-Library-Dedupe truncation defense for
/// `EPUBImporter.truncateStemIfNeeded`. The clamp only fires when
/// the stem exceeds 200 UTF-8 bytes, so most real-world cases
/// pass through untouched; tests focus on the boundary and on the
/// deterministic suffix shape.
final class EPUBImporterTruncateTests: XCTestCase {

    func test_short_stem_passes_through_unchanged() {
        let stem = "Discipline and Punish"
        XCTAssertEqual(EPUBImporter.truncateStemIfNeeded(stem), stem)
    }

    func test_200_byte_stem_is_at_the_boundary_and_passes_through() {
        let stem = String(repeating: "a", count: 200)
        XCTAssertEqual(stem.utf8.count, 200)
        XCTAssertEqual(EPUBImporter.truncateStemIfNeeded(stem), stem)
    }

    func test_201_byte_stem_is_truncated_to_at_most_200_bytes() {
        let stem = String(repeating: "a", count: 201)
        let result = EPUBImporter.truncateStemIfNeeded(stem)
        XCTAssertLessThanOrEqual(result.utf8.count, 200)
        XCTAssertTrue(result.contains("~"))
    }

    func test_truncation_is_deterministic() {
        // Same input → same suffix. Two callers receive identical
        // truncated stems so the destination URL is stable.
        let stem = String(repeating: "x", count: 500)
        let a = EPUBImporter.truncateStemIfNeeded(stem)
        let b = EPUBImporter.truncateStemIfNeeded(stem)
        XCTAssertEqual(a, b)
    }

    func test_different_stems_produce_different_suffixes() {
        // Distinct sources that share the same truncated head must
        // still produce distinct truncated stems via the hash tail.
        let prefix = String(repeating: "z", count: 250)
        let stemA = prefix + "_alpha"
        let stemB = prefix + "_beta"
        let a = EPUBImporter.truncateStemIfNeeded(stemA)
        let b = EPUBImporter.truncateStemIfNeeded(stemB)
        XCTAssertNotEqual(a, b)
    }

    func test_truncated_stem_ends_with_eight_hex_chars_after_tilde() {
        let stem = String(repeating: "q", count: 300)
        let result = EPUBImporter.truncateStemIfNeeded(stem)
        guard let tildeRange = result.range(of: "~", options: .backwards) else {
            return XCTFail("Truncated stem should contain a `~` separator")
        }
        let suffix = result[tildeRange.upperBound...]
        XCTAssertEqual(suffix.count, 8)
        let hexCharset = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertNil(suffix.rangeOfCharacter(from: hexCharset.inverted))
    }

    func test_unicode_stem_truncates_without_slicing_codepoints() {
        // Repeated ✿ (U+273F, 3 UTF-8 bytes) builds a stem we know
        // will overflow. The truncator removes whole Characters,
        // so the result must be valid UTF-8 even after trimming.
        let stem = String(repeating: "✿", count: 100)
        XCTAssertGreaterThan(stem.utf8.count, 200)
        let result = EPUBImporter.truncateStemIfNeeded(stem)
        XCTAssertLessThanOrEqual(result.utf8.count, 200)
        // Round-tripping through Data confirms the bytes form a
        // legal UTF-8 string.
        let roundTrip = String(data: Data(result.utf8), encoding: .utf8)
        XCTAssertEqual(result, roundTrip)
    }
}
