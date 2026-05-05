import XCTest
@testable import AI

/// `AISettingsStore` round-trips settings through `UserDefaults`
/// using a per-test suite to avoid leaking across runs or polluting
/// the user's standard defaults.
final class AISettingsTests: XCTestCase {

    private func makeStore() -> (AISettingsStore, UserDefaults, String) {
        let suiteName = "humanist.ai-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let key = "settings"
        let store = AISettingsStore(defaults: defaults, key: key)
        return (store, defaults, suiteName)
    }

    private func clean(_ defaults: UserDefaults, _ suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_load_returns_defaults_when_nothing_stored() {
        let (store, defaults, suite) = makeStore()
        defer { clean(defaults, suite) }
        let s = store.load()
        XCTAssertEqual(s.processingMode, .privateLocal)
        XCTAssertEqual(s.perBookCallCap, 200)
        XCTAssertTrue(s.cloudFeatures.hardRegionOCR)
        XCTAssertTrue(s.cloudFeatures.tableExtraction)
        XCTAssertFalse(s.cloudFeatures.postOCRCleanup)
        XCTAssertFalse(s.cloudFeatures.semanticClassification)
        XCTAssertFalse(s.cloudFeatures.tocParsing)
    }

    func test_save_then_load_round_trips() {
        let (store, defaults, suite) = makeStore()
        defer { clean(defaults, suite) }
        let original = AISettings(
            processingMode: .cloud,
            cloudFeatures: AISettings.CloudFeatures(
                hardRegionOCR: false,
                tableExtraction: true,
                postOCRCleanup: true,
                semanticClassification: false,
                tocParsing: true
            ),
            perBookCallCap: 50
        )
        store.save(original)
        let loaded = store.load()
        XCTAssertEqual(loaded, original)
    }

    func test_reset_restores_defaults() {
        let (store, defaults, suite) = makeStore()
        defer { clean(defaults, suite) }
        store.save(AISettings(processingMode: .cloud, perBookCallCap: 1))
        store.reset()
        let loaded = store.load()
        XCTAssertEqual(loaded.processingMode, .privateLocal)
        XCTAssertEqual(loaded.perBookCallCap, 200)
    }

    func test_corrupt_payload_falls_back_to_defaults() {
        let (store, defaults, suite) = makeStore()
        defer { clean(defaults, suite) }
        defaults.set(Data("not json".utf8), forKey: "settings")
        let loaded = store.load()
        XCTAssertEqual(loaded.processingMode, .privateLocal)
    }
}

/// Default `ProcessingMode` should be private — first-launch must
/// not require any setup before the user can convert a book.
final class ProcessingModeTests: XCTestCase {
    func test_default_settings_start_in_private_mode() {
        XCTAssertEqual(AISettings().processingMode, .privateLocal)
    }
}
