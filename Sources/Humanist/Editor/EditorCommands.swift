import SwiftUI
import AppKit

/// Editor-window commands surfaced in the menu bar. Each one reads the
/// focused window's `EditorViewModel` via `@FocusedValue` so it acts on
/// whichever editor is frontmost. When no editor is focused the commands
/// disable themselves rather than disappearing — keeps the menu shape
/// stable and discoverable.

// MARK: - File menu items (Save, Save As, Close)

struct EditorSaveCommand: View {
    @FocusedObject private var vm: EditorViewModel?

    var body: some View {
        Button("Save") {
            guard let vm else { return }
            Task { await vm.save() }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(vm == nil || vm?.isDirty != true || vm?.saveState == .saving)
    }
}

struct EditorSaveAsCommand: View {
    @FocusedObject private var vm: EditorViewModel?

    var body: some View {
        Button("Save As…") {
            guard let vm, let pkg = vm.package else { return }
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
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(vm == nil || vm?.saveState == .saving)
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
            EditorReOCRCurrentPageMenu()
            EditorReOCRPDFSelectionMenu()
        }
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
