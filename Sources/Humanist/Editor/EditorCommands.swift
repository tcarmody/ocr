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
        CommandMenu("Format") {
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
            Divider()
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
            Divider()
            EditorRemoveFormattingCommand()
            EditorSmartQuotesCommand()
        }
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
            EditorValidateEPUBCommand()
        }
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

// MARK: - View menu (pane toggles + source PDF actions)

/// Top-level "Document" menu — pane toggles, source-PDF actions,
/// preview controls, and re-OCR commands for the open EPUB. Named
/// "Document" rather than "View" so it doesn't collide with the
/// system View menu (Show Toolbar, Enter Full Screen, etc.) and
/// produce two side-by-side View menus in the bar.
struct EditorViewMenu: Commands {
    var body: some Commands {
        CommandMenu("Document") {
            EditorPaneToggle(pane: .pdf)
            EditorPaneToggle(pane: .source)
            EditorPaneToggle(pane: .preview)
            Divider()
            EditorAttachPDFCommand()
            EditorPDFNavMenu()
            Divider()
            EditorReloadPreviewCommand()
            Divider()
            EditorAlignFromSourceCommand()
            EditorAlignFromPDFCommand()
            EditorAlignFromPreviewCommand()
            Divider()
            EditorReOCRCurrentPageMenu()
            EditorReOCRPDFSelectionMenu()
            Divider()
            EditorSplitChapterCommand()
            EditorMergeChapterCommand()
            EditorRegenerateTOCCommand()
            Divider()
            ShowCorrectionTrailCommand()
        }
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
/// PDF pane. Mirror of the standalone PDF viewer's toolbar; lives
/// as a submenu so the View menu stays compact.
private struct EditorPDFNavMenu: View {
    @FocusedObject private var vm: EditorViewModel?

    var body: some View {
        Menu("Source PDF") {
            Button("Zoom In") { vm?.pdfZoomIn() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(vm?.canNavigatePDF != true)
            Button("Zoom Out") { vm?.pdfZoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(vm?.canNavigatePDF != true)
            Button("Fit Page") { vm?.pdfFitPage() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(vm?.canNavigatePDF != true)
            Divider()
            // ⇧⌘← / ⇧⌘→ rather than ⌘←/⌘→ so we don't fight
            // CodeMirror's beginning-/end-of-line bindings when the
            // user's cursor is in the source pane.
            Button("Previous Page") { vm?.pdfPrevPage() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .disabled(vm?.canNavigatePDF != true)
            Button("Next Page") { vm?.pdfNextPage() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(vm?.canNavigatePDF != true)
        }
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
