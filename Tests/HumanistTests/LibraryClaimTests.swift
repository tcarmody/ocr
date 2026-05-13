import XCTest
import Foundation
@testable import Humanist

/// Coverage for `LibraryStore`'s in-flight conversion claims —
/// the multi-Mac coordination primitive that prevents two Macs
/// sharing an iCloud library from running OCR on the same source
/// PDF at the same time.
@MainActor
final class LibraryClaimTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-claim-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    private func makeStore() -> LibraryStore {
        LibraryStore(storeURL: tempDir.appendingPathComponent("library.json"))
    }

    // MARK: - tryClaim

    func test_tryClaim_on_empty_store_returns_claimed() {
        let store = makeStore()
        let result = store.tryClaim(hash: "abc", hostName: "alice")
        XCTAssertEqual(result, .claimed)
        XCTAssertEqual(store.claims.count, 1)
        XCTAssertEqual(store.claims[0].sourceHash, "abc")
        XCTAssertEqual(store.claims[0].hostName, "alice")
    }

    func test_tryClaim_refreshes_self_claim() {
        // Same host re-claiming gets a fresh timestamp — useful
        // when a JobRunner restart re-enters the same job. The
        // result is still `.claimed`; only one row exists.
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 1100)
        _ = store.tryClaim(hash: "abc", hostName: "alice", now: t0)
        let result = store.tryClaim(hash: "abc", hostName: "alice", now: t1)
        XCTAssertEqual(result, .claimed)
        XCTAssertEqual(store.claims.count, 1)
        XCTAssertEqual(store.claims[0].claimedAt, t1)
    }

    func test_tryClaim_blocked_by_fresh_other_host() {
        let store = makeStore()
        let now = Date()
        _ = store.tryClaim(hash: "abc", hostName: "alice", now: now)
        let result = store.tryClaim(hash: "abc", hostName: "bob", now: now)
        guard case .heldByOther(let marker) = result else {
            return XCTFail("expected .heldByOther, got \(result)")
        }
        XCTAssertEqual(marker.hostName, "alice")
        XCTAssertEqual(store.claims.count, 1,
            "blocked claim must NOT add a second row")
    }

    func test_tryClaim_succeeds_over_stale_other_host() {
        let store = makeStore()
        let stale = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 5000)        // 4000s later
        _ = store.tryClaim(hash: "abc", hostName: "alice",
                           freshness: 60, now: stale)
        // 4000s gap >> 60s freshness — alice's claim is stale and
        // gets reaped. bob takes the now-free claim.
        let result = store.tryClaim(hash: "abc", hostName: "bob",
                                    freshness: 60, now: now)
        XCTAssertEqual(result, .claimed)
        XCTAssertEqual(store.claims.count, 1)
        XCTAssertEqual(store.claims[0].hostName, "bob")
    }

    func test_tryClaim_ignores_empty_hash_or_host() {
        let store = makeStore()
        XCTAssertEqual(store.tryClaim(hash: "", hostName: "alice"), .claimed)
        XCTAssertEqual(store.tryClaim(hash: "abc", hostName: ""), .claimed)
        XCTAssertEqual(store.claims.count, 0,
            "guard rails should not stamp empty-key claims")
    }

    // MARK: - releaseClaim

    func test_releaseClaim_removes_matching_row() {
        let store = makeStore()
        _ = store.tryClaim(hash: "abc", hostName: "alice")
        store.releaseClaim(hash: "abc", hostName: "alice")
        XCTAssertTrue(store.claims.isEmpty)
    }

    func test_releaseClaim_does_not_remove_other_host_or_other_hash() {
        let store = makeStore()
        _ = store.tryClaim(hash: "abc", hostName: "alice")
        _ = store.tryClaim(hash: "xyz", hostName: "alice")
        store.releaseClaim(hash: "abc", hostName: "bob")        // wrong host
        XCTAssertEqual(store.claims.count, 2)
        store.releaseClaim(hash: "qqq", hostName: "alice")      // wrong hash
        XCTAssertEqual(store.claims.count, 2)
    }

    func test_releaseClaim_is_idempotent() {
        let store = makeStore()
        _ = store.tryClaim(hash: "abc", hostName: "alice")
        store.releaseClaim(hash: "abc", hostName: "alice")
        store.releaseClaim(hash: "abc", hostName: "alice")
        XCTAssertTrue(store.claims.isEmpty)
    }

    // MARK: - pruneStaleClaims

    func test_pruneStaleClaims_drops_old_rows() {
        let store = makeStore()
        let stale = Date(timeIntervalSince1970: 1000)
        let fresh = Date(timeIntervalSince1970: 5000)
        _ = store.tryClaim(hash: "old", hostName: "alice", now: stale)
        _ = store.tryClaim(hash: "new", hostName: "alice", now: fresh)
        let dropped = store.pruneStaleClaims(freshness: 60, now: fresh)
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(store.claims.count, 1)
        XCTAssertEqual(store.claims[0].sourceHash, "new")
    }

    func test_pruneStaleClaims_zero_when_all_fresh() {
        let store = makeStore()
        let now = Date()
        _ = store.tryClaim(hash: "a", hostName: "alice", now: now)
        _ = store.tryClaim(hash: "b", hostName: "alice", now: now)
        XCTAssertEqual(
            store.pruneStaleClaims(freshness: 60, now: now), 0
        )
    }

    // MARK: - freshClaim query

    func test_freshClaim_finds_active_marker() {
        let store = makeStore()
        let now = Date()
        _ = store.tryClaim(hash: "abc", hostName: "alice", now: now)
        let claim = store.freshClaim(forSourceHash: "abc",
                                     freshness: 60, now: now)
        XCTAssertEqual(claim?.hostName, "alice")
    }

    func test_freshClaim_returns_nil_for_stale_marker() {
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 9000)        // 8000s later
        _ = store.tryClaim(hash: "abc", hostName: "alice",
                           freshness: 99999, now: t0)
        // Same row, query against a tighter freshness window.
        let claim = store.freshClaim(forSourceHash: "abc",
                                     freshness: 60, now: later)
        XCTAssertNil(claim)
    }

    // MARK: - Persistence

    func test_claims_round_trip_across_reopen() {
        let store = makeStore()
        let now = Date()
        _ = store.tryClaim(hash: "abc", hostName: "alice", now: now)
        _ = store.tryClaim(hash: "xyz", hostName: "alice", now: now)

        let reopened = makeStore()
        XCTAssertEqual(reopened.claims.count, 2)
        XCTAssertEqual(Set(reopened.claims.map(\.sourceHash)),
                       Set(["abc", "xyz"]))
    }

    func test_legacy_catalog_without_claims_field_loads_clean() throws {
        // Older catalog files (pre-Phase-D) had no `claims` field.
        // decodeIfPresent must default the in-memory array to empty
        // so the load doesn't fail.
        let storeURL = tempDir.appendingPathComponent("library.json")
        let legacy: [String: Any] = [
            "entries": [] as [[String: Any]],
            "collections": [] as [[String: Any]]
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: storeURL)

        let reopened = LibraryStore(storeURL: storeURL)
        XCTAssertEqual(reopened.claims.count, 0)
    }
}
