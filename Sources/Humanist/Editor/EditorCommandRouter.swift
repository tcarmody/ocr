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
        // Both observers are set up directly — EditorCommandRouter is
        // @MainActor, so init runs on the main actor and addObserver
        // can be called inline. (An earlier version wrapped the
        // didResignKey observer in `Task { @MainActor in }` for what
        // looked like a hop, but the wrapper was redundant and
        // tripped Swift 6's Sendable check on `addObserver`'s
        // NSObjectProtocol return type.)
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        _ = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
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
        guard let vm = activeEditor(), let book = vm.book else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.epub]
        panel.nameFieldStringValue = book.sourceURL
            .deletingPathExtension()
            .lastPathComponent + " copy.epub"
        panel.directoryURL = book.sourceURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            Task { await vm.saveAs(to: url) }
        }
    }

    /// Edit-menu Find / Find Next / Find Previous / Find and
    /// Replace dispatch. The default Edit > Find group SwiftUI
    /// synthesizes from `CommandGroup(replacing: .textEditing)`
    /// fires `performTextFinderAction:` against the responder chain,
    /// which CodeMirror's WKWebView doesn't pick up. We replace the
    /// group with menu items that route through the active
    /// editor's `searchRequest` instead.
    func openFind()    { activeEditor()?.openFind() }
    func findNext()    { activeEditor()?.findNext() }
    func findPrev()    { activeEditor()?.findPrev() }
    func openReplace() { activeEditor()?.openReplace() }

    /// True when there's an editor available to receive a find /
    /// replace command. The Edit-menu items disable when no editor
    /// is active.
    var canFind: Bool { activeEditor() != nil }

    /// Open the document-spelling check sheet on the active editor.
    func openSpellCheck() { activeEditor()?.openSpellCheck() }

    // MARK: - Format / Insert / Edit menu dispatch (Phase 5a)

    /// Should the next format command target the WYSIWYG surface
    /// instead of the source pane? True when the WYSIWYG pane is
    /// visible AND currently has keyboard focus. Source wins by
    /// default — when both panes are visible but the user
    /// hasn't clicked into WYSIWYG, format commands stay where
    /// they were.
    private func shouldDispatchToWYSIWYG(_ vm: EditorViewModel) -> Bool {
        vm.showWYSIWYGPane && vm.wysiwygHasFocus
    }

    /// Translate a "wrap with opening/closing tag pair" request
    /// into the equivalent semantic `WYSIWYGCommand`, when one
    /// exists. Format menu items use raw HTML wraps (`<strong>`
    /// / `</strong>`); the WYSIWYG bridge takes higher-level
    /// commands. Returns nil for wraps without a WYSIWYG
    /// equivalent — caller falls back to the source path.
    private func wysiwygEquivalent(forWrapOpening opening: String) -> WYSIWYGCommand? {
        switch opening {
        case "<strong>":           return .bold
        case "<em>":               return .italic
        case "<code>":             return .inlineCode
        case "<sup>":              return .superscript
        case "<sub>":              return .`subscript`
        case let s where s.hasPrefix("<h"):
            guard let levelChar = s.dropFirst(2).first,
                  let n = Int(String(levelChar)),
                  (1...6).contains(n)
            else { return nil }
            return .heading(n)
        case let s where s.hasPrefix("<blockquote>"):
            return .blockquote
        default:
            return nil
        }
    }

    /// Wrap the active pane's selection with `opening` / `closing`.
    /// Used by Format menu items (Bold, Italic, Headings 1-6, etc.).
    /// Routes to WYSIWYG when that pane is focused and the wrap
    /// has a known semantic equivalent; falls back to source for
    /// wraps the WYSIWYG bridge can't express (custom tags, link,
    /// language span — those use Insert menu items with their
    /// own routes).
    func formatWrap(opening: String, closing: String) {
        guard let vm = activeEditor() else { return }
        if shouldDispatchToWYSIWYG(vm),
           let cmd = wysiwygEquivalent(forWrapOpening: opening) {
            vm.wysiwygCommand = WYSIWYGCommandRequest(cmd)
            return
        }
        vm.formatWrap(opening: opening, closing: closing)
    }

    /// Apply a casing transform to the active pane's selection.
    /// Casing transforms are source-pane-only today — the WYSIWYG
    /// JS bridge doesn't have a transformSelection helper.
    /// Documented limitation; future expansion can add it.
    func formatTransform(_ kind: EditorViewModel.FormatRequest.TransformKind) {
        activeEditor()?.formatTransform(kind)
    }

    /// Strip inline formatting from the active pane's selection.
    /// Routes to WYSIWYG when that pane is focused — the bridge's
    /// `removeFormatting` command runs execCommand('removeFormat')
    /// + execCommand('unlink'). Falls back to source's tag-strip
    /// otherwise.
    func formatRemoveFormatting() {
        guard let vm = activeEditor() else { return }
        if shouldDispatchToWYSIWYG(vm) {
            vm.wysiwygCommand = WYSIWYGCommandRequest(.removeFormatting)
            return
        }
        vm.formatRemoveFormatting()
    }

    /// Convert straight quotes to typographic curly quotes
    /// document-wide. Routes to WYSIWYG when that pane is focused
    /// — the bridge walks every text node in the body. Source
    /// path does the same on the raw XHTML buffer.
    func formatSmartQuotes() {
        guard let vm = activeEditor() else { return }
        if shouldDispatchToWYSIWYG(vm) {
            vm.wysiwygCommand = WYSIWYGCommandRequest(.smartQuotes)
            return
        }
        vm.smartQuoteSourceText()
    }

    /// Insert a closing tag at the source pane's cursor for the most
    /// recently-opened unclosed tag.
    func insertClosingTag() {
        activeEditor()?.insertClosingTag()
    }

    /// Insert a noteref + matching footnote `<aside>` skeleton at
    /// the cursor.
    func insertFootnote() {
        activeEditor()?.insertFootnote()
    }

    /// Insert an empty named-anchor target at the cursor:
    /// `<a id="…"></a>`. Source-pane-only — WYSIWYG already exposes
    /// id editing through the element inspector, and a bare anchor
    /// target has no visible rendering for contentEditable to drive.
    func insertAnchor(id: String) {
        activeEditor()?.insertAnchor(id: id)
    }

    /// Toggle the Insert > Anchor… sheet on the active editor. The
    /// sheet collects the id and commits via `insertAnchor(id:)`.
    func showAnchorSheet() {
        guard let vm = activeEditor() else { return }
        vm.showAnchorSheet = true
    }

    /// Round-trip the active editor's source through `XMLDocument`
    /// and re-emit with pretty-printed indentation. Source-pane-only
    /// — operates on the raw XHTML buffer, not the rendered DOM.
    /// `EditorViewModel` surfaces parse failures through
    /// `tidySourceError`; the view-layer alert dismisses them.
    func tidySource() {
        activeEditor()?.tidySource()
    }

    /// Insert raw text at the source pane's cursor. Used by the
    /// Special Character picker so a chosen char goes straight into
    /// the document.
    func insertText(_ text: String) {
        activeEditor()?.formatInsert(text)
    }

    /// Toggle the Special Character picker sheet on the active
    /// editor. Reused by the menu item and any toolbar surface.
    func showSpecialCharacterPicker() {
        guard let vm = activeEditor() else { return }
        vm.showSpecialCharacterPicker = true
    }

    /// Toggle the Goto Line sheet on the active editor.
    func showGotoLineSheet() {
        guard let vm = activeEditor() else { return }
        vm.showGotoLineSheet = true
    }

    /// Equalize all visible panes to the same width.
    func equalizePanes() { activeEditor()?.equalizePanes() }

    /// Open the Footnote Manager sheet on the active editor.
    func showFootnoteManager() {
        guard let vm = activeEditor() else { return }
        vm.showFootnoteManager = true
    }

    /// Open the Chapter Manager sheet on the active editor.
    func showChapterManager() {
        guard let vm = activeEditor() else { return }
        vm.showChapterManager = true
    }

    /// Toggle the Find in Files sheet. If results from a prior
    /// invocation are still in the viewmodel, they're left in place
    /// — reopening the sheet picks up where the user left off.
    func showFindInFilesSheet() {
        guard let vm = activeEditor() else { return }
        vm.showFindInFilesSheet = true
    }

    /// Tools > Validate EPUB. Saves first if dirty, then invokes
    /// epubcheck and surfaces results in the validation sheet.
    func validateEPUB() {
        guard let vm = activeEditor() else { return }
        Task { await vm.validateEPUB() }
    }

    /// Tools > Customize Style. Opens the style sheet for the
    /// active editor; the sheet's Apply button writes the new
    /// `book.css` through the dirty-buffer pipeline.
    func showStyleSheet() {
        guard let vm = activeEditor() else { return }
        vm.showStyleSheet = true
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
            if let match = live.first(where: { $0.book?.displayTitle == keyTitle }) {
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
        let newSaveAs = vm.book != nil && vm.saveState != .saving
        if canSave != newSave { canSave = newSave }
        if canSaveAs != newSaveAs { canSaveAs = newSaveAs }
    }

    /// Weak ref so a deallocated editor doesn't keep us alive.
    private struct WeakEditor {
        weak var vm: EditorViewModel?
    }
}
