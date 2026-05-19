import XCTest
@testable import Humanist

/// R-Reader. `ReadingPositionStore` writes positions to a
/// per-hash JSON file in Application Support. Tests assert
/// the round-trip plus the cache-miss / corrupt-file paths.
final class ReadingPositionStoreTests: XCTestCase {

    /// Use a unique hash per test so writes don't collide
    /// across runs of the suite (the store writes into real
    /// Application Support — we don't sandbox).
    private func uniqueHash() -> String {
        "test-" + UUID().uuidString
    }

    /// Best-effort cleanup of stored positions written during
    /// the test. Failures are silent — tearDown shouldn't crash
    /// if the file was already removed.
    private func cleanup(_ hash: String) {
        if let url = ReadingPositionStore.fileURL(forContentHash: hash) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func test_save_then_load_roundtrip() {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        let original = ReadingPosition(
            contentHash: hash,
            spineIndex: 7,
            scrollFraction: 0.42,
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        ReadingPositionStore.save(original)
        guard let loaded = ReadingPositionStore.load(
            forContentHash: hash
        ) else {
            XCTFail("expected stored position to load")
            return
        }
        XCTAssertEqual(loaded.spineIndex, 7)
        XCTAssertEqual(loaded.scrollFraction, 0.42, accuracy: 0.001)
        XCTAssertEqual(loaded.contentHash, hash)
    }

    func test_load_returns_nil_for_missing_hash() {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        XCTAssertNil(ReadingPositionStore.load(forContentHash: hash))
    }

    func test_save_overwrites_existing_record() {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        ReadingPositionStore.save(ReadingPosition(
            contentHash: hash, spineIndex: 3
        ))
        ReadingPositionStore.save(ReadingPosition(
            contentHash: hash, spineIndex: 12
        ))
        XCTAssertEqual(
            ReadingPositionStore.load(forContentHash: hash)?.spineIndex, 12
        )
    }

    func test_load_returns_nil_on_corrupt_file() throws {
        let hash = uniqueHash()
        defer { cleanup(hash) }
        guard let url = ReadingPositionStore.fileURL(
            forContentHash: hash
        ) else {
            XCTFail("expected fileURL to be reachable")
            return
        }
        try "this is not json".write(
            to: url, atomically: true, encoding: .utf8
        )
        // Corrupt sidecar shouldn't crash the reader on open —
        // load returns nil and the reader starts at spine 0.
        XCTAssertNil(ReadingPositionStore.load(forContentHash: hash))
    }
}
