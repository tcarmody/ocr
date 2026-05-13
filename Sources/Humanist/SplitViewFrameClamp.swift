import Foundation
import AppKit

/// U-Splitview-Frame-Clamp: defensive cleanup of `NSSplitView`
/// autosave entries that AppKit persists to UserDefaults under
/// keys of the form `NSSplitView Subview Frames <autosaveName>`.
///
/// macOS occasionally writes pathological widths into these
/// keys — multi-monitor sessions, SwiftUI hot-reload mid-resize,
/// or a divider drag the OS misinterprets. On 2026-05-12 the
/// editor came up with a saved 5,198 px sidebar + 10,957 px
/// detail on a 1,512 px screen, which sent `SystemSplitView`
/// into a 300-iteration constraint loop and blanked the
/// sidebar / WYSIWYG / Preview panes until the keys were
/// manually `defaults delete`-d.
///
/// Belt-and-suspenders: on launch, walk every matching key and
/// drop any whose stored frames describe a subview wider or
/// taller than `2 × max(screen.{width,height})`. Dropping the
/// whole key (rather than editing individual array entries)
/// lets AppKit fall back to the view-tree's natural sizing on
/// the next open.
enum SplitViewFrameClamp {

    /// Prefix every `NSSplitView` autosave key shares.
    static let keyPrefix = "NSSplitView Subview Frames "

    /// Walks `defaults` for keys with `keyPrefix` and removes any
    /// whose persisted subview frames have a width or height
    /// exceeding `2 × max(screenSizes.{width,height})`. Returns
    /// the names of the removed keys so the caller can log them.
    ///
    /// `screenSizes` is injected so unit tests don't depend on a
    /// real `NSScreen`. Passing an empty array (or one whose
    /// largest dimension is 0) skips the clamp entirely — there's
    /// no safe bound to compare against.
    @discardableResult
    static func clampCorruptFrames(
        in defaults: UserDefaults,
        screenSizes: [CGSize]
    ) -> [String] {
        let maxScreenDim = screenSizes
            .flatMap { [$0.width, $0.height] }
            .max() ?? 0
        guard maxScreenDim > 0 else { return [] }
        let limit = maxScreenDim * 2

        let allKeys = defaults.dictionaryRepresentation().keys
        var removed: [String] = []
        for key in allKeys where key.hasPrefix(keyPrefix) {
            guard let frames = defaults.array(forKey: key) as? [String] else {
                continue
            }
            if frames.contains(where: { Self.frameExceedsLimit($0, limit: limit) }) {
                defaults.removeObject(forKey: key)
                removed.append(key)
            }
        }
        return removed.sorted()
    }

    /// NSSplitView writes each subview as a string of six comma-
    /// separated fields: `x, y, width, height, isCollapsed, isHidden`.
    /// Only width + height matter for the clamp; the booleans and
    /// origin are accepted as-is.
    static func frameExceedsLimit(_ frameString: String, limit: CGFloat) -> Bool {
        let parts = frameString
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 4,
              let w = Double(parts[2]),
              let h = Double(parts[3])
        else { return false }
        return CGFloat(w) > limit || CGFloat(h) > limit
    }
}
