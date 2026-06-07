import XCTest
@testable import Humanist

/// Pins the stable-key contract: a book's marks key off its identity
/// (so editor saves, which change the content hash, don't orphan them)
/// and fall back to the content hash only when there's no identifier.
final class AnnotationKeyTests: XCTestCase {

    func test_uses_book_identifier_when_present() {
        let key = AnnotationKey.resolve(
            bookID: "urn:uuid:wittgenstein-pi-4e-combined",
            contentHash: "deadbeef"
        )
        XCTAssertTrue(key.hasPrefix("id-"), key)
        XCTAssertNotEqual(key, "deadbeef")
    }

    func test_identifier_key_is_stable_across_content_hash_changes() {
        // Same book identity, different file bytes (an editor save) ⇒
        // same key. This is the whole point of the fix.
        let a = AnnotationKey.resolve(bookID: "urn:uuid:x", contentHash: "hash-v1")
        let b = AnnotationKey.resolve(bookID: "urn:uuid:x", contentHash: "hash-v2")
        XCTAssertEqual(a, b)
    }

    func test_different_identifiers_yield_different_keys() {
        let a = AnnotationKey.resolve(bookID: "urn:uuid:a", contentHash: "h")
        let b = AnnotationKey.resolve(bookID: "urn:uuid:b", contentHash: "h")
        XCTAssertNotEqual(a, b)
    }

    func test_falls_back_to_content_hash_without_identifier() {
        XCTAssertEqual(
            AnnotationKey.resolve(bookID: nil, contentHash: "abc123"),
            "abc123"
        )
        XCTAssertEqual(
            AnnotationKey.resolve(bookID: "   ", contentHash: "abc123"),
            "abc123"
        )
    }
}
