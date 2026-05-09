import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Editor-window commands surfaced in the menu bar. Each one reads the
/// focused window's `EditorViewModel` via `@FocusedValue` so it acts on
/// whichever editor is frontmost. When no editor is focused the commands
/// disable themselves rather than disappearing — keeps the menu shape
/// stable and discoverable.

// MARK: - RouterButton helper

/// Menu Button observing `EditorCommandRouter.shared`, disabled when
/// the router's `enabled` predicate is false. Centralizes the
/// `@ObservedObject + Button + .keyboardShortcut + .disabled` shape
/// every router-driven menu item shared. `enabled` and `action` both
/// receive the router so callers stay one-liners.
struct RouterButton: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    let title: String
    let shortcut: KeyEquivalent?
    let modifiers: EventModifiers
    let enabled: @MainActor (EditorCommandRouter) -> Bool
    let action: @MainActor (EditorCommandRouter) -> Void

    init(
        _ title: String,
        shortcut: KeyEquivalent? = nil,
        modifiers: EventModifiers = .command,
        enabled: @escaping @MainActor (EditorCommandRouter) -> Bool = { $0.canFind },
        action: @escaping @MainActor (EditorCommandRouter) -> Void
    ) {
        self.title = title
        self.shortcut = shortcut
        self.modifiers = modifiers
        self.enabled = enabled
        self.action = action
    }

    @MainActor
    var body: some View {
        Button(title) { action(router) }
            .modifier(OptionalShortcut(shortcut: shortcut, modifiers: modifiers))
            .disabled(!enabled(router))
    }
}

private struct OptionalShortcut: ViewModifier {
    let shortcut: KeyEquivalent?
    let modifiers: EventModifiers
    @ViewBuilder func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut, modifiers: modifiers)
        } else {
            content
        }
    }
}

// MARK: - File menu items (Save, Save As, Close)

/// Save / Save As route through `EditorCommandRouter`, a singleton
/// the editor scene registers itself with on appear / unregisters
/// on disappear. We previously read the focused viewmodel via
/// `@FocusedObject`, but that wrapper doesn't reliably propagate to
/// items inside `CommandGroup(replacing: .saveItem)` — the items
/// either stayed disabled or didn't render at all in the menu bar.
/// The router pattern is robust because it uses NSApp.keyWindow as
/// the source of truth, which always tracks the focused window.

struct EditorSaveCommand: View {
    var body: some View {
        RouterButton(
            "Save", shortcut: "s", enabled: { $0.canSave }
        ) { $0.save() }
    }
}

struct EditorSaveAsCommand: View {
    var body: some View {
        RouterButton(
            "Save As…", shortcut: "s",
            modifiers: [.command, .shift], enabled: { $0.canSaveAs }
        ) { $0.saveAs() }
    }
}

// MARK: - Format menu (Phase 5a)

/// `Format` top-level menu — Bold/Italic, headings 1-6, casing
/// transforms, smart quotes, remove formatting. Items route through
/// `EditorCommandRouter` because the focused-object pattern is
/// unreliable for these (same reason as Save / Find).
struct EditorFormatMenu: Commands {
    var body: some Commands {
        // Wrapped in sub-Views to keep the body under SwiftUI's
        // @CommandsBuilder 10-element cap. See
        // feedback_swiftui_commandsbuilder_cap.md — overflow items
        // get silently dropped from the menu bar.
        CommandMenu("Format") {
            FormatInlineCommands()
            Divider()
            FormatStructureMenus()
            Divider()
            FormatNormalizationCommands()
        }
    }
}

private struct FormatInlineCommands: View {
    var body: some View {
        wrapButton("Bold", open: "<strong>", close: "</strong>", shortcut: "b")
        wrapButton("Italic", open: "<em>", close: "</em>", shortcut: "i")
        wrapButton("Inline Code", open: "<code>", close: "</code>")
    }
}

private struct FormatStructureMenus: View {
    var body: some View {
        Menu("Heading") {
            ForEach(1...6, id: \.self) { level in
                wrapButton(
                    "Heading \(level)",
                    open: "<h\(level)>", close: "</h\(level)>",
                    shortcut: KeyEquivalent(Character("\(level)")),
                    modifiers: [.command, .option]
                )
            }
        }
        Menu("Casing") {
            transformButton("UPPER CASE",    kind: .upper)
            transformButton("lower case",    kind: .lower)
            transformButton("Title Case",    kind: .title)
            transformButton("Sentence case", kind: .sentence)
        }
    }
}

private struct FormatNormalizationCommands: View {
    var body: some View {
        RouterButton(
            "Remove Formatting", shortcut: "\\",
            modifiers: [.command, .shift]
        ) { $0.formatRemoveFormatting() }
        RouterButton("Convert Quotes to Smart Quotes") {
            $0.formatSmartQuotes()
        }
    }
}

@ViewBuilder
private func wrapButton(
    _ title: String, open: String, close: String,
    shortcut: KeyEquivalent? = nil,
    modifiers: EventModifiers = .command
) -> some View {
    RouterButton(title, shortcut: shortcut, modifiers: modifiers) {
        $0.formatWrap(opening: open, closing: close)
    }
}

@ViewBuilder
private func transformButton(
    _ title: String, kind: EditorViewModel.FormatRequest.TransformKind
) -> some View {
    RouterButton(title) { $0.formatTransform(kind) }
}

// MARK: - Insert menu (Phase 5a)

/// `Insert` top-level menu — Special Character picker, Closing Tag,
/// Footnote, Link, Language Tag. Lives parallel to Format so each
/// menu has a focused purpose.
struct EditorInsertMenu: Commands {
    var body: some Commands {
        CommandMenu("Insert") {
            RouterButton(
                "Special Character…", shortcut: "t",
                modifiers: [.command, .option]
            ) { $0.showSpecialCharacterPicker() }
            Divider()
            RouterButton(
                "Closing Tag", shortcut: ".",
                modifiers: [.command, .shift]
            ) { $0.insertClosingTag() }
            RouterButton(
                "Footnote", shortcut: "f",
                modifiers: [.command, .shift, .option]
            ) { $0.insertFootnote() }
            RouterButton("Footnote Manager…") { $0.showFootnoteManager() }
        }
    }
}

// MARK: - Tools menu (Phase 5b)

/// `Tools` top-level menu. Currently houses Validate EPUB; future
/// homes for Reports, Index editor, Mend Document live here.
struct EditorToolsMenu: Commands {
    var body: some Commands {
        CommandMenu("Tools") {
            ToolsMenuValidationCommands()
            Divider()
            ToolsMenuReOCRCommands()
            Divider()
            EditorCompareEPUBsCommand()
        }
    }
}

private struct ToolsMenuValidationCommands: View {
    var body: some View {
        RouterButton(
            "Validate EPUB…", shortcut: "v",
            modifiers: [.command, .shift, .option]
        ) { $0.validateEPUB() }
        RouterButton("Customize Style…") { $0.showStyleSheet() }
    }
}

/// Re-OCR commands moved here from the Document menu — they're
/// tool-like (run an engine, surface a result), not document-edit
/// operations.
private struct ToolsMenuReOCRCommands: View {
    var body: some View {
        EditorReOCRCurrentPageMenu()
        EditorReOCRPDFSelectionMenu()
        EditorReOCRAllPagesMenu()
    }
}

private struct EditorCompareEPUBsCommand: View {
    var body: some View {
        Button("Compare EPUBs…") { ToolsPrompts.runDiffEPUBs() }
    }
}

// MARK: - View menu (pane toggles + source PDF actions)

/// Top-level "Document" menu — pane toggles, source-PDF actions,
/// preview controls, and re-OCR commands for the open EPUB. Named
/// "Document" rather than "View" so it doesn't collide with the
/// system View menu (Show Toolbar, Enter Full Screen, etc.) and
/// produce two side-by-side View menus in the bar.
/// Top-level "Document" menu — chapter operations + source-PDF
/// attach + correction trail. Pane toggles, alignment commands, and
/// the reload-preview command moved to the new View menu; Re-OCR
/// commands moved to the Tools menu. Each lives where users would
/// naturally look for it.
struct EditorDocumentMenu: Commands {
    var body: some Commands {
        CommandMenu("Document") {
            EditorAttachPDFCommand()
            Divider()
            DocumentMenuChapterCommands()
            Divider()
            ShowCorrectionTrailCommand()
        }
    }
}

private struct DocumentMenuChapterCommands: View {
    var body: some View {
        EditorSplitChapterCommand()
        EditorMergeChapterCommand()
        EditorMoveChapterUpCommand()
        EditorMoveChapterDownCommand()
        EditorRegenerateTOCCommand()
        Divider()
        EditorChapterManagerCommand()
    }
}

private struct EditorChapterManagerCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Chapter Manager…") { vm?.showChapterManager = true }
            .disabled(vm == nil)
    }
}

/// Adds editor items to the **system** View menu. macOS auto-
/// generates a View menu (Show Tab Bar, Enter Full Screen, etc.)
/// for any window, and `CommandMenu("View")` would create a
/// SECOND View menu next to it. Using `CommandGroup(after: .sidebar)`
/// places our items inside the system View menu after its sidebar
/// group — one View menu, system items + editor items in order.
struct EditorViewMenu: Commands {
    var body: some Commands {
        // Body wrapping kept under SwiftUI's @CommandsBuilder cap
        // by grouping items into per-section sub-Views — see
        // feedback_swiftui_commandsbuilder_cap.md.
        CommandGroup(after: .sidebar) {
            Divider()
            ViewMenuPaneToggles()
            Divider()
            EditorReloadPreviewCommand()
            Divider()
            ViewMenuPDFCommands()
            Divider()
            ViewMenuAlignmentCommands()
        }
    }
}

private struct ViewMenuPaneToggles: View {
    var body: some View {
        EditorPaneToggle(pane: .pdf)
        EditorPaneToggle(pane: .source)
        EditorPaneToggle(pane: .preview)
        EditorPaneToggle(pane: .wysiwyg)
        EditorPaneToggle(pane: .chat)
        Divider()
        EditorEqualizePanesCommand()
    }
}

private struct EditorEqualizePanesCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Equalize Panes") { vm?.equalizePanes() }
            .disabled(vm == nil)
    }
}

private struct ViewMenuAlignmentCommands: View {
    var body: some View {
        EditorAlignFromSourceCommand()
        EditorAlignFromPDFCommand()
        EditorAlignFromPreviewCommand()
    }
}

private struct ViewMenuPDFCommands: View {
    var body: some View {
        EditorPDFZoomInCommand()
        EditorPDFZoomOutCommand()
        EditorPDFFitPageCommand()
        EditorPDFPrevPageCommand()
        EditorPDFNextPageCommand()
    }
}

private struct EditorSplitChapterCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Split Chapter at Cursor") {
            guard let vm else { return }
            Task { await vm.splitChapterAtCursor() }
        }
        .keyboardShortcut("k", modifiers: [.command, .shift])
        .disabled(vm?.canSplitCurrentChapter != true)
    }
}

private struct EditorMergeChapterCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Merge with Next Chapter") {
            guard let vm else { return }
            Task { await vm.mergeChapterWithNext() }
        }
        .keyboardShortcut("j", modifiers: [.command, .shift])
        .disabled(vm?.canMergeWithNextChapter != true)
    }
}

private struct EditorRegenerateTOCCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Regenerate Table of Contents") {
            guard let vm else { return }
            Task { await vm.regenerateTableOfContents() }
        }
        .disabled(vm == nil)
    }
}

private struct EditorMoveChapterUpCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Move Chapter Up") {
            vm?.moveCurrentChapterUp()
        }
        // ⌥⌘↑ — same gesture pattern as the source-pane "move line
        // up" idiom, applied at the chapter granularity. Earlier
        // attempt used ⌃⌘[ but that gesture is reserved by macOS as
        // the system "Back" shortcut and SwiftUI's CommandMenu
        // silently swallows the entire menu item rather than
        // letting the binding land on top of it.
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        .disabled(vm?.canMoveCurrentChapterUp != true)
    }
}

private struct EditorMoveChapterDownCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Move Chapter Down") {
            vm?.moveCurrentChapterDown()
        }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        .disabled(vm?.canMoveCurrentChapterDown != true)
    }
}

// MARK: - alignment commands (replaces continuous bidirectional sync)

/// Drive the PDF + preview to the source pane's current cursor
/// anchor. The source pane itself isn't moved — the cursor stays
/// exactly where the user put it. This replaces the auto cursor →
/// PDF → preview drive that previously ran on every cursor activity
/// and produced the typing-yanks-cursor bug.
private struct EditorAlignFromSourceCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Align Others to Source Cursor") {
            vm?.alignOthersToSourceCursor()
        }
        .keyboardShortcut("1", modifiers: [.command, .shift])
        .disabled(vm?.currentSourceAnchor == nil)
    }
}

/// Drive the source + preview to the PDF's currently-visible page.
/// The PDF stays put.
private struct EditorAlignFromPDFCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Align Others to PDF Page") {
            vm?.alignOthersToPDFPage()
        }
        .keyboardShortcut("2", modifiers: [.command, .shift])
        .disabled(vm?.currentPDFPage == nil)
    }
}

/// Drive the source + PDF to the preview's topmost-visible anchor.
/// The preview stays put.
private struct EditorAlignFromPreviewCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Align Others to Preview Top") {
            vm?.alignOthersToPreviewTop()
        }
        .keyboardShortcut("3", modifiers: [.command, .shift])
        .disabled(vm?.currentPreviewAnchor == nil)
    }
}

/// Document > Show Correction Trail — opens the sheet listing every
/// Haiku post-OCR cleanup decision the conversion made on this book.
/// Disabled when no editor is focused or the open EPUB has no trail
/// sidecar (book wasn't converted with cleanup enabled, or no regions
/// tripped the trigger gate).
private struct ShowCorrectionTrailCommand: View {
    @FocusedObject private var vm: EditorViewModel?

    var body: some View {
        Button("Show Correction Trail…") {
            NotificationCenter.default.post(
                name: .humanistShowCorrectionTrail, object: nil
            )
        }
        .disabled(vm?.correctionTrail == nil)
    }
}

/// View > Source PDF ▸ — zoom + page navigation for the embedded
/// PDF pane navigation commands — zoom + page nav. Each command
/// gets its own struct rather than being inlined as a Button in a
/// shared body. Pane toggles follow the same pattern and they
/// work; an earlier "all 5 buttons in one struct's body" shape
/// rendered as nothing in the View menu, presumably because
/// SwiftUI's CommandMenu treats a sub-View's multi-Button body
/// differently from a sub-View that returns a single Button.
private struct EditorPDFZoomInCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Zoom In Original") { vm?.pdfZoomIn() }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(vm?.canNavigatePDF != true)
    }
}

private struct EditorPDFZoomOutCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Zoom Out Original") { vm?.pdfZoomOut() }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(vm?.canNavigatePDF != true)
    }
}

private struct EditorPDFFitPageCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Fit Original Page") { vm?.pdfFitPage() }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(vm?.canNavigatePDF != true)
    }
}

/// ⇧⌘← rather than ⌘← so we don't fight CodeMirror's
/// beginning-of-line binding when the user's cursor is in the
/// source pane.
private struct EditorPDFPrevPageCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Previous Original Page") { vm?.pdfPrevPage() }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            .disabled(vm?.canNavigatePDF != true)
    }
}

private struct EditorPDFNextPageCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Next Original Page") { vm?.pdfNextPage() }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            .disabled(vm?.canNavigatePDF != true)
    }
}

private struct EditorReloadPreviewCommand: View {
    @FocusedObject private var vm: EditorViewModel?

    var body: some View {
        Button("Reload Preview") {
            vm?.reloadPreview()
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(vm == nil || vm?.selectedFile == nil)
    }
}

/// Submenu: "Re-OCR Current Page With ▸ Vision · Surya · Tesseract".
/// Uses the source-pane cursor's enclosing `hu-page-N` anchor to pick
/// which PDF page to render. Whole-page re-OCR is the workflow most
/// users want most of the time — no PDF-selection dance, and the
/// sheet's "Replace Page in Source" splices cleanly between anchors.
private struct EditorReOCRCurrentPageMenu: View {
    @FocusedObject private var vm: EditorViewModel?

    var body: some View {
        Menu("Re-OCR Current Page With") {
            ForEach(ReOCREngineKind.allCases) { kind in
                Button(label(for: kind)) {
                    guard let vm else { return }
                    Task {
                        do { try await vm.reOCRCurrentSourcePage(engine: kind) }
                        catch { presentReOCRError(error) }
                    }
                }
                .disabled(vm == nil || !kind.isAvailable)
            }
        }
        .disabled(vm == nil || vm?.sourcePDFURL == nil)
    }

    private func label(for kind: ReOCREngineKind) -> String {
        kind.isAvailable ? kind.displayName : "\(kind.displayName) (not installed)"
    }
}

/// Submenu: "Re-OCR All Pages With ▸ …". V-Refresh: opens a
/// confirmation sheet, then walks every entry in the pagemap and
/// replaces each page's body in the source XHTML with a fresh OCR
/// pass through the chosen engine. Useful when the user wants to
/// retroactively apply newer engine improvements (typography pass,
/// Cloud features, layout fixes) to an already-converted EPUB.
///
/// Disabled when there's no source PDF attached or the EPUB has no
/// page map (older books or non-Humanist EPUBs).
private struct EditorReOCRAllPagesMenu: View {
    @FocusedObject private var vm: EditorViewModel?

    var body: some View {
        Menu("Re-OCR All Pages With") {
            ForEach(ReOCREngineKind.allCases) { kind in
                Button(label(for: kind)) {
                    vm?.bulkReOCR.confirm(engine: kind)
                }
                .disabled(vm == nil || !kind.isAvailable)
            }
        }
        .disabled(
            vm == nil
            || vm?.sourcePDFURL == nil
            || vm?.pageMap == nil
            || vm?.bulkReOCR.progress != nil
        )
    }

    private func label(for kind: ReOCREngineKind) -> String {
        kind.isAvailable ? kind.displayName : "\(kind.displayName) (not installed)"
    }
}

/// Submenu: "Re-OCR PDF Selection With ▸ …". Older flow — works on
/// whatever's currently text-selected in the PDF pane. Useful when
/// you want to OCR a tighter rectangle than a whole page.
private struct EditorReOCRPDFSelectionMenu: View {
    @FocusedObject private var vm: EditorViewModel?

    var body: some View {
        Menu("Re-OCR PDF Selection With") {
            ForEach(ReOCREngineKind.allCases) { kind in
                Button(label(for: kind)) {
                    guard let vm else { return }
                    Task {
                        do { try await vm.reOCRSelection(engine: kind) }
                        catch { presentReOCRError(error) }
                    }
                }
                .disabled(vm == nil || !kind.isAvailable)
            }
        }
        .disabled(vm == nil || vm?.sourcePDFURL == nil)
    }

    private func label(for kind: ReOCREngineKind) -> String {
        kind.isAvailable ? kind.displayName : "\(kind.displayName) (not installed)"
    }
}

private func presentReOCRError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Could not re-OCR"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

private struct EditorPaneToggle: View {
    @FocusedObject private var vm: EditorViewModel?
    let pane: EditorPane

    var body: some View {
        Button(label) {
            vm?.togglePane(pane)
        }
        .keyboardShortcut(shortcut, modifiers: .command)
        .disabled(vm == nil)
    }

    private var label: String {
        let visible = vm?.isPaneVisible(pane) ?? false
        let action = visible ? "Hide" : "Show"
        switch pane {
        case .pdf:     return "\(action) Original"
        case .source:  return "\(action) Source"
        case .wysiwyg: return "\(action) WYSIWYG"
        case .preview: return "\(action) Preview"
        case .chat:    return "\(action) Chat"
        }
    }

    private var shortcut: KeyEquivalent {
        switch pane {
        case .pdf:     return "1"
        case .source:  return "2"
        case .preview: return "3"
        case .wysiwyg: return "4"
        case .chat:    return "5"
        }
    }
}

private struct EditorAttachPDFCommand: View {
    @FocusedObject private var vm: EditorViewModel?

    var body: some View {
        Button(vm?.sourcePDFURL == nil ? "Attach Original…" : "Change Original…") {
            guard let vm else { return }
            let panel = NSOpenPanel()
            // Accept any format the source viewer can render. PDF
            // additionally enables Re-OCR commands; the others just
            // get a "Show Original" pane.
            let exts = ["pdf", "html", "htm", "rtf", "rtfd",
                        "docx", "doc", "odt", "md", "markdown", "txt"]
            panel.allowedContentTypes = exts.compactMap {
                UTType(filenameExtension: $0)
            }
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            if panel.runModal() == .OK, let url = panel.url {
                vm.attachSourcePDF(url)
            }
        }
        .disabled(vm == nil)
    }
}
