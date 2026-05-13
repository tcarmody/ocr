import XCTest
@testable import Humanist

/// U-Splitview-Frame-Clamp coverage. The clamp is screen-size
/// driven, so every test uses an isolated `UserDefaults` suite +
/// injected `screenSizes` to stay independent of the host
/// machine's actual displays.
final class SplitViewFrameClampTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SplitViewFrameClampTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - frameExceedsLimit

    func testFrameExceedsLimit_withinBounds_returnsFalse() {
        XCTAssertFalse(
            SplitViewFrameClamp.frameExceedsLimit(
                "0.000000, 0.000000, 228.000000, 886.000000, NO, NO",
                limit: 3024
            )
        )
    }

    func testFrameExceedsLimit_widthExceeds_returnsTrue() {
        XCTAssertTrue(
            SplitViewFrameClamp.frameExceedsLimit(
                "0.000000, 0.000000, 5198.000000, 886.000000, NO, NO",
                limit: 3024
            )
        )
    }

    func testFrameExceedsLimit_heightExceeds_returnsTrue() {
        XCTAssertTrue(
            SplitViewFrameClamp.frameExceedsLimit(
                "0.000000, 0.000000, 228.000000, 10957.000000, NO, NO",
                limit: 3024
            )
        )
    }

    func testFrameExceedsLimit_malformed_returnsFalse() {
        // Too few fields, non-numeric width/height — both are
        // treated as "can't tell, leave alone" so a parser shift
        // in a future macOS doesn't wipe everyone's split views.
        XCTAssertFalse(
            SplitViewFrameClamp.frameExceedsLimit("garbage", limit: 3024)
        )
        XCTAssertFalse(
            SplitViewFrameClamp.frameExceedsLimit(
                "0, 0, notanumber, 100, NO, NO",
                limit: 3024
            )
        )
    }

    // MARK: - clampCorruptFrames

    func testClamp_dropsKeyWhenAnySubviewExceedsLimit() {
        let key = "NSSplitView Subview Frames editor-AppWindow-1, SidebarNavigationSplitView"
        defaults.set(
            [
                "0.000000, 0.000000, 5198.000000, 886.000000, NO, NO",
                "0.000000, 0.000000, 1512.000000, 886.000000, NO, NO"
            ],
            forKey: key
        )

        let removed = SplitViewFrameClamp.clampCorruptFrames(
            in: defaults,
            screenSizes: [CGSize(width: 1512, height: 982)]
        )

        XCTAssertEqual(removed, [key])
        XCTAssertNil(defaults.array(forKey: key))
    }

    func testClamp_leavesSaneKeysIntact() {
        let key = "NSSplitView Subview Frames editor-AppWindow-1, SidebarNavigationSplitView"
        let frames = [
            "0.000000, 0.000000, 228.000000, 886.000000, NO, NO",
            "0.000000, 0.000000, 1284.000000, 886.000000, NO, NO"
        ]
        defaults.set(frames, forKey: key)

        let removed = SplitViewFrameClamp.clampCorruptFrames(
            in: defaults,
            screenSizes: [CGSize(width: 1512, height: 982)]
        )

        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(defaults.array(forKey: key) as? [String], frames)
    }

    func testClamp_walksMultipleKeysAndReportsAllRemovals() {
        let goodKey = "NSSplitView Subview Frames good-AppWindow-1, NavSplit"
        let badKey1 = "NSSplitView Subview Frames editor-AppWindow-1, SidebarNavigationSplitView"
        let badKey2 = "NSSplitView Subview Frames editor-AppWindow-2, EditorSplitView"

        defaults.set(
            ["0, 0, 220, 800, NO, NO", "0, 0, 1200, 800, NO, NO"],
            forKey: goodKey
        )
        defaults.set(
            ["0, 0, 5198, 886, NO, NO", "0, 0, 1512, 886, NO, NO"],
            forKey: badKey1
        )
        defaults.set(
            ["0, 0, 100, 88888, NO, NO"],
            forKey: badKey2
        )

        let removed = SplitViewFrameClamp.clampCorruptFrames(
            in: defaults,
            screenSizes: [CGSize(width: 1512, height: 982)]
        )

        XCTAssertEqual(removed, [badKey1, badKey2].sorted())
        XCTAssertNotNil(defaults.array(forKey: goodKey))
        XCTAssertNil(defaults.array(forKey: badKey1))
        XCTAssertNil(defaults.array(forKey: badKey2))
    }

    func testClamp_ignoresNonSplitViewKeys() {
        let unrelatedKey = "SomeOtherPreference"
        defaults.set("not a frame string at all", forKey: unrelatedKey)

        let removed = SplitViewFrameClamp.clampCorruptFrames(
            in: defaults,
            screenSizes: [CGSize(width: 1512, height: 982)]
        )

        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(defaults.string(forKey: unrelatedKey), "not a frame string at all")
    }

    func testClamp_emptyScreenList_skipsWork() {
        // With no screens to derive a bound from, the clamp can't
        // distinguish "really wide" from "intentional wide" — it
        // should leave UserDefaults alone rather than wipe arbitrary
        // state. Covers headless CI / pre-NSScreen init paths.
        let key = "NSSplitView Subview Frames editor-AppWindow-1, SidebarNavigationSplitView"
        let frames = ["0, 0, 99999, 99999, NO, NO"]
        defaults.set(frames, forKey: key)

        let removed = SplitViewFrameClamp.clampCorruptFrames(
            in: defaults,
            screenSizes: []
        )

        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(defaults.array(forKey: key) as? [String], frames)
    }

    func testClamp_largestScreenWins() {
        // Multi-monitor: a frame that's huge relative to the laptop
        // panel but fits the 6K external must survive. Limit is
        // 2 × max across all screens (= 12,288 for a 6K ultrafine),
        // so a 5,198 px sidebar is fine in this rig even though it
        // wedged the single-screen layout earlier.
        let key = "NSSplitView Subview Frames editor-AppWindow-1, SidebarNavigationSplitView"
        let frames = ["0, 0, 5198, 886, NO, NO", "0, 0, 1024, 886, NO, NO"]
        defaults.set(frames, forKey: key)

        let removed = SplitViewFrameClamp.clampCorruptFrames(
            in: defaults,
            screenSizes: [
                CGSize(width: 1512, height: 982),
                CGSize(width: 6016, height: 3384)
            ]
        )

        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(defaults.array(forKey: key) as? [String], frames)
    }

    func testClamp_arrayShapedKeyButWrongElementType_isLeftAlone() {
        // Defensive — if someone else's framework writes an array
        // under a NSSplitView-shaped key but with non-string entries,
        // the clamp should silently no-op rather than crash.
        let key = "NSSplitView Subview Frames weird, format"
        defaults.set([1, 2, 3], forKey: key)

        let removed = SplitViewFrameClamp.clampCorruptFrames(
            in: defaults,
            screenSizes: [CGSize(width: 1512, height: 982)]
        )

        XCTAssertTrue(removed.isEmpty)
        XCTAssertNotNil(defaults.array(forKey: key))
    }
}
