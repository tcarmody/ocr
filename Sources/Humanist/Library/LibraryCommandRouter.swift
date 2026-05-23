import SwiftUI
import Combine

/// Singleton router for Library menu-bar commands that depend on
/// the Library window's selection (today: "Remove from Library…").
///
/// Pattern mirrors `EditorCommandRouter` and exists for the same
/// reason: `@FocusedObject` / `@FocusedValue` don't propagate
/// reliably into items declared inside a `CommandGroup`, so the
/// items stay permanently disabled or don't render at all even
/// when the Library window is focused. The router replaces that
/// path:
///
///   * `LibraryWindowView` calls `bind(selectionCount:onRemove:)`
///     whenever its selection changes, and `unbind()` on disappear.
///   * The router publishes `canRemove` so menu items can disable
///     themselves via `.disabled(!router.canRemove)`.
///   * `triggerRemove()` invokes the bound closure — the actual
///     dialog presentation logic lives back in `LibraryWindowView`.
///
/// Singleton because there's exactly one Library window (single-
/// instance `Window(id: "library")`); a multi-window-aware shape
/// would be overkill.
@MainActor
final class LibraryCommandRouter: ObservableObject {
    static let shared = LibraryCommandRouter()

    /// True when the Library window is presenting at least one
    /// selectable row AND that selection is non-empty. Menu items
    /// gate on this so they're grayed out when the user hasn't
    /// picked anything (MACUX: "Disabled items: gray them out
    /// rather than hiding").
    @Published private(set) var canRemove: Bool = false

    /// Bound closure that re-runs the LibraryWindowView's
    /// `requestRemove(...)` against the current selection.
    /// Re-bound on every selection change (cheap — closure
    /// captures only the entry IDs to act on).
    private var removeAction: (() -> Void)?

    private init() {}

    /// LibraryWindowView calls this every time its selection
    /// changes. Passing a count of zero is treated the same as
    /// `unbind()` — both disable the menu item.
    func bind(selectionCount: Int, onRemove: @escaping () -> Void) {
        canRemove = selectionCount > 0
        removeAction = selectionCount > 0 ? onRemove : nil
    }

    /// Clear the binding when the Library window goes away (or
    /// loses focus). Belt-and-suspenders against a stale closure
    /// firing after the source view is gone.
    func unbind() {
        canRemove = false
        removeAction = nil
    }

    /// Run whatever the LibraryWindowView last bound. No-op when
    /// nothing is bound; menu items shouldn't be able to call
    /// this anyway because `canRemove` is the gate.
    func triggerRemove() {
        removeAction?()
    }
}
