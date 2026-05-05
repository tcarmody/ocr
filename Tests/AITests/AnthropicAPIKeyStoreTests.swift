import XCTest
@testable import AI

/// Round-trip tests for the keychain-backed `AnthropicAPIKeyStore`.
/// Each test uses a per-test service name so they don't collide with
/// the production keychain item or with each other.
final class AnthropicAPIKeyStoreTests: XCTestCase {

    private func makeStore(_ name: String = #function) -> AnthropicAPIKeyStore {
        // Sanitize the test name so the service string is keychain-safe
        // (no parens, spaces).
        let sanitized = name
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "_")
        return AnthropicAPIKeyStore(
            service: "humanist.ai-tests.\(sanitized).\(UUID().uuidString)",
            account: "default"
        )
    }

    func test_read_returns_nil_when_no_key_set() {
        let store = makeStore()
        XCTAssertNil(store.read())
        XCTAssertFalse(store.hasKey)
    }

    func test_write_then_read_round_trips_value() throws {
        let store = makeStore()
        try store.write("sk-ant-test-1234567890")
        XCTAssertEqual(store.read(), "sk-ant-test-1234567890")
        XCTAssertTrue(store.hasKey)
        try store.delete()
    }

    func test_write_overwrites_existing_value() throws {
        let store = makeStore()
        try store.write("first")
        try store.write("second")
        XCTAssertEqual(store.read(), "second", "second write should replace, not duplicate")
        try store.delete()
    }

    func test_delete_removes_key() throws {
        let store = makeStore()
        try store.write("to-delete")
        try store.delete()
        XCTAssertNil(store.read())
        XCTAssertFalse(store.hasKey)
    }

    func test_delete_when_no_key_is_noop() throws {
        let store = makeStore()
        try store.delete()  // should not throw
    }

    func test_isolated_service_names_dont_share_state() throws {
        let storeA = AnthropicAPIKeyStore(
            service: "humanist.ai-tests.iso.A.\(UUID().uuidString)"
        )
        let storeB = AnthropicAPIKeyStore(
            service: "humanist.ai-tests.iso.B.\(UUID().uuidString)"
        )
        try storeA.write("A-only")
        XCTAssertEqual(storeA.read(), "A-only")
        XCTAssertNil(storeB.read(), "stores with distinct service names should be isolated")
        try storeA.delete()
    }
}
