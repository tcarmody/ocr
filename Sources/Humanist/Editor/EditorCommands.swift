import SwiftUI
import AppKit

/// Editor-window commands surfaced in the menu bar. Each one reads the
/// focused window's `EditorViewModel` via `@FocusedValue` so it acts on
/// whichever editor is frontmost. When no editor is focused the commands
/// disable themselves rather than disappearing — keeps the menu shape
/// stable and discoverable.

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
    @ObservedObject private var router = EditorCommandRouter.shared

    var body: some View {
        Button("Save") { router.save() }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!router.canSave)
    }
}

struct EditorSaveAsCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared

    var body: some View {
        Button("Save As…") { router.saveAs() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!router.canSaveAs)
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
        EditorWrapCommand(
            title: "Bold", opening: "<strong>", closing: "</strong>",
            shortcut: "b", modifiers: .command
        )
        EditorWrapCommand(
            title: "Italic", opening: "<em>", closing: "</em>",
            shortcut: "i", modifiers: .command
        )
        EditorWrapCommand(
            title: "Inline Code", opening: "<code>", closing: "</code>",
            shortcut: nil, modifiers: []
        )
    }
}

private struct FormatStructureMenus: View {
    var body: some View {
        Menu("Heading") {
            ForEach(1...6, id: \.self) { level in
                EditorWrapCommand(
                    title: "Heading \(level)",
                    opening: "<h\(level)>", closing: "</h\(level)>",
                    shortcut: KeyEquivalent(Character("\(level)")),
                    modifiers: [.command, .option]
                )
            }
        }
        Menu("Casing") {
            EditorTransformCommand(title: "UPPER CASE",     kind: .upper)
            EditorTransformCommand(title: "lower case",     kind: .lower)
            EditorTransformCommand(title: "Title Case",     kind: .title)
            EditorTransformCommand(title: "Sentence case",  kind: .sentence)
        }
    }
}

private struct FormatNormalizationCommands: View {
    var body: some View {
        EditorRemoveFormattingCommand()
        EditorSmartQuotesCommand()
    }
}

private struct EditorWrapCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    let title: String
    let opening: String
    let closing: String
    let shortcut: KeyEquivalent?
    let modifiers: EventModifiers

    var body: some View {
        let button = Button(title) {
            router.formatWrap(opening: opening, closing: closing)
        }
        .disabled(!router.canFind)
        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: modifiers)
        } else {
            button
        }
    }
}

private struct EditorTransformCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    let title: String
    let kind: EditorViewModel.FormatRequest.TransformKind

    var body: some View {
        Button(title) { router.formatTransform(kind) }
            .disabled(!router.canFind)
    }
}

private struct EditorRemoveFormattingCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Remove Formatting") { router.formatRemoveFormatting() }
            .keyboardShortcut("\\", modifiers: [.command, .shift])
            .disabled(!router.canFind)
    }
}

private struct EditorSmartQuotesCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Convert Quotes to Smart Quotes") {
            router.formatSmartQuotes()
        }
        .disabled(!router.canFind)
    }
}

// MARK: - Insert menu (Phase 5a)

/// `Insert` top-level menu — Special Character picker, Closing Tag,
/// Footnote, Link, Language Tag. Lives parallel to Format so each
/// menu has a focused purpose.
struct EditorInsertMenu: Commands {
    var body: some Commands {
        CommandMenu("Insert") {
            EditorSpecialCharacterCommand()
            Divider()
            EditorClosingTagCommand()
            EditorFootnoteCommand()
        }
    }
}

private struct EditorSpecialCharacterCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Special Character…") {
            router.showSpecialCharacterPicker()
        }
        .keyboardShortcut("t", modifiers: [.command, .option])
        .disabled(!router.canFind)
    }
}

private struct EditorClosingTagCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Closing Tag") { router.insertClosingTag() }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(!router.canFind)
    }
}

private struct EditorFootnoteCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Footnote") { router.insertFootnote() }
            .keyboardShortcut("f", modifiers: [.command, .shift, .option])
            .disabled(!router.canFind)
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
        EditorValidateEPUBCommand()
        EditorCustomizeStyleCommand()
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

private struct EditorValidateEPUBCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Validate EPUB…") { router.validateEPUB() }
            .keyboardShortcut("v", modifiers: [.command, .shift, .option])
            .disabled(!router.canFind)
    }
}

/// R-Custom-Styles. Opens the per-book style sheet on the active
/// editor. Disabled when no editor is focused — same predicate as
/// every other Tools-menu item.
private struct EditorCustomizeStyleCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Customize Style…") { router.showStyleSheet() }
            .disabled(!router.canFind)
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
    }
}

/// Top-level "View" menu — pane visibility toggles, preview reload,
/// PDF view commands, alignment commands. Uses `CommandMenu("View")`
/// because `CommandGroup(after: .sidebar)` didn't reliably expand
/// our sub-Views into the system View menu (zoom commands ended up
/// dropped). With CommandMenu the menu is fully under our control;
/// there's no system-generated View menu to collide with in this
/// app's scene shape (no DocumentGroup, no auto sidebar/toolbar
/// commands), so the earlier "two View menus" reading was probably
/// the CommandGroup placement creating a phantom secondary menu.
struct EditorViewMenu: Commands {
    var body: some Commands {
        // Body wrapping kept under SwiftUI's @CommandsBuilder cap by
        // grouping items into per-section sub-Views — see
        // feedback_swiftui_commandsbuilder_cap.md.
        CommandMenu("View") {
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
        Button("Zoom In Source PDF") { vm?.pdfZoomIn() }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(vm?.canNavigatePDF != true)
    }
}

private struct EditorPDFZoomOutCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Zoom Out Source PDF") { vm?.pdfZoomOut() }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(vm?.canNavigatePDF != true)
    }
}

private struct EditorPDFFitPageCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Fit Source PDF Page") { vm?.pdfFitPage() }
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
        Button("Previous Source PDF Page") { vm?.pdfPrevPage() }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            .disabled(vm?.canNavigatePDF != true)
    }
}

private struct EditorPDFNextPageCommand: View {
    @FocusedObject private var vm: EditorViewModel?
    var body: some View {
        Button("Next Source PDF Page") { vm?.pdfNextPage() }
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
                    vm?.confirmBulkReOCR(engine: kind)
                }
                .disabled(vm == nil || !kind.isAvailable)
            }
        }
        .disabled(
            vm == nil
            || vm?.sourcePDFURL == nil
            || vm?.pageMap == nil
            || vm?.bulkReOCRProgress != nil
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
        case .pdf:     return "\(action) Source PDF"
        case .source:  return "\(action) Source"
        case .preview: return "\(action) Preview"
        }
    }

    private var shortcut: KeyEquivalent {
        switch pane {
        case .pdf:     return "1"
        case .source:  return "2"
        case .preview: return "3"
        }
    }
}

private struct EditorAttachPDFCommand: View {
    @FocusedObject private var vm: EditorViewModel?

    var body: some View {
        Button(vm?.sourcePDFURL == nil ? "Attach Source PDF…" : "Change Source PDF…") {
            guard let vm else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf]
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
