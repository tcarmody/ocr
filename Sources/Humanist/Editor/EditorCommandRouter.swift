import SwiftUI
import AppKit
import Combine

/// Singleton command router for the editor's File-menu actions.
///
/// `@FocusedObject` (paired with `View.focusedObject(_:)`) was the
/// natural SwiftUI mechanism for routing menu-bar Save / Save As to
/// whichever editor window is frontmost, but it didn't propagate
/// reliably into items declared inside
/// `CommandGroup(replacing: .saveItem)` — the menu items either
/// stayed permanently disabled or didn't render at all when the
/// editor scene was focused. The router replaces that brittle path:
///
///   * Each editor window registers its `EditorViewModel` on appear
///     and clears it on disappear (`bind(_:)` / `unbind(_:)`).
///   * The router watches `NSApplication.keyWindow` and the bound
///     viewmodel's `@Published` state (`isDirty`, `saveState`,
///     `package`) to compute `canSave` / `canSaveAs`. Menu items
///     observe the router (`@ObservedObject`) and re-render when
///     either source changes.
///   * Action methods route to the active viewmodel, falling back
///     to `keyWindow`-derived lookup when multiple editors are open.
///
/// Singleton because there's exactly one menu bar — making it a
/// shared instance keeps the registration API trivial.
@MainActor
final class EditorCommandRouter: ObservableObject {
    static let shared = EditorCommandRouter()

    /// Set of registered editors. Multiple windows can be open at
    /// once; the router picks the one matching the current key
    /// window (or the most-recently-bound when there's no clear key).
    private var bound: [ObjectIdentifier: WeakEditor] = [:]
    private var observers: [ObjectIdentifier: AnyCancellable] = [:]
    private var keyWindowObserver: NSObjectProtocol?

    /// True when there's a focused editor with a dirty buffer that
    /// isn't already mid-save. Drives the Save menu item's enabled
    /// state.
    @Published private(set) var canSave: Bool = false
    /// True when there's a focused editor with a loaded package.
    /// Save As works on any open document, dirty or not.
    @Published private(set) var canSaveAs: Bool = false

    private init() {
        // Watch key-window changes globally so the menu item state
        // reacts when the user clicks between editor windows.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        Task { @MainActor in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.recompute() }
            }
        }
    }

    /// Register an editor's viewmodel. Called from `EditorView.onAppear`.
    /// Subscribes to the viewmodel's published state so the Save
    /// menu item flips enabled/disabled as the user types.
    func bind(_ vm: EditorViewModel) {
        let id = ObjectIdentifier(vm)
        bound[id] = WeakEditor(vm: vm)
        // Re-evaluate on every @Published change. Coalesce via
        // `objectWillChange` — fires once per update batch.
        observers[id] = vm.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        recompute()
    }

    /// Drop a registration. Called from `EditorView.onDisappear`.
    func unbind(_ vm: EditorViewModel) {
        let id = ObjectIdentifier(vm)
        bound.removeValue(forKey: id)
        observers.removeValue(forKey: id)
        recompute()
    }

    /// Trigger Save on the active editor. No-op when none is focused.
    func save() {
        guard let vm = activeEditor() else { return }
        Task { await vm.save() }
    }

    /// Show the Save As panel and route the picked URL to the active
    /// editor. Mirrors the inline NSSavePanel logic from before.
    func saveAs() {
        guard let vm = activeEditor(), let pkg = vm.package else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.epub]
        panel.nameFieldStringValue = pkg.sourceURL
            .deletingPathExtension()
            .lastPathComponent + " copy.epub"
        panel.directoryURL = pkg.sourceURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            Task { await vm.saveAs(to: url) }
        }
    }

    // MARK: - private

    /// Pick the editor whose window is currently key. If none of the
    /// registered editors owns the key window (e.g. a sheet just
    /// resigned key), fall back to whichever editor we have. This is
    /// a fallback — the common case is a single editor whose window
    /// is key when ⌘S fires.
    private func activeEditor() -> EditorViewModel? {
        let live = bound.values.compactMap(\.vm)
        // Single editor → no ambiguity.
        if live.count == 1 { return live.first }
        // Multiple editors → resolve via key window's title match.
        if let keyTitle = NSApp.keyWindow?.title {
            if let match = live.first(where: { $0.package?.displayTitle == keyTitle }) {
                return match
            }
        }
        // Fallback: most-recently-bound (last in dict iteration order).
        return live.last
    }

    private func recompute() {
        guard let vm = activeEditor() else {
            if canSave { canSave = false }
            if canSaveAs { canSaveAs = false }
            return
        }
        let newSave = vm.isDirty && vm.saveState != .saving
        let newSaveAs = vm.package != nil && vm.saveState != .saving
        if canSave != newSave { canSave = newSave }
        if canSaveAs != newSaveAs { canSaveAs = newSaveAs }
    }

    /// Weak ref so a deallocated editor doesn't keep us alive.
    private struct WeakEditor {
        weak var vm: EditorViewModel?
    }
}
