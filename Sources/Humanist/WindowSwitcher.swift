import AppKit

/// Bring-forward helpers for the app's primary surfaces. SwiftUI's
/// `openWindow(id:)` opens a *new* window for `WindowGroup` scenes
/// (the launcher and editor), which isn't what "Show Editor" /
/// "Show Converter" want — those should reuse an existing window.
///
/// `NSApp.windows` is ordered front-to-back, so the first match for
/// a given window kind is the most-recently-focused. The window-
/// switcher commands fall through to the SwiftUI `openWindow` for
/// single-instance scenes (Library, Queue) where it does the right
/// thing.
@MainActor
enum WindowSwitcher {

    /// Find a window whose `NSWindow.identifier` contains
    /// `substring` and bring it to the front. Returns true on
    /// success. Used for editor windows whose identifiers SwiftUI
    /// sets from the scene `id: "editor"`.
    @discardableResult
    static func showWindow(matchingIdentifier substring: String) -> Bool {
        for window in NSApp.windows {
            guard let id = window.identifier?.rawValue,
                  id.contains(substring) else { continue }
            guard isReusable(window) else { continue }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            return true
        }
        return false
    }

    /// Find a window whose title equals `title` exactly and bring
    /// it forward. Used for the launcher (title = "Humanist") and
    /// other windows whose identifiers SwiftUI doesn't expose
    /// reliably.
    @discardableResult
    static func showWindow(withTitle title: String) -> Bool {
        for window in NSApp.windows where window.title == title {
            guard isReusable(window) else { continue }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            return true
        }
        return false
    }

    /// A window that we can meaningfully surface. Excludes the
    /// auxiliary panels SwiftUI leaves dangling in `NSApp.windows`
    /// (status bars, popovers, transient hosting windows) so the
    /// chord doesn't accidentally focus one of those. Closed
    /// windows usually fail `isVisible && !isMiniaturized` here,
    /// which is correct — the caller's fallback path then runs
    /// `openWindow(id:)` to reopen the scene cleanly.
    private static func isReusable(_ window: NSWindow) -> Bool {
        if window.isMiniaturized { return true }
        guard window.isVisible else { return false }
        // SwiftUI hosting windows that aren't user-facing
        // typically lack a non-empty title — exclude them so a
        // title-keyed match doesn't pick them up accidentally.
        return !window.title.isEmpty
    }
}
