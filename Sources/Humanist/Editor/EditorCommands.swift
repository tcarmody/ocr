import SwiftUI
import AppKit

/// Editor-window commands surfaced in the menu bar. Each one reads the
/// focused window's `EditorViewModel` via `@FocusedValue` so it acts on
/// whichever editor is frontmost. When no editor is focused the commands
/// disable themselves rather than disappearing — keeps the menu shape
/// stable and discoverable.

// MARK: - File menu items (Save, Save As, Close)

struct EditorSaveCommand: View {
    @FocusedValue(\.editorViewModel) private var vm: EditorViewModel?

    var body: some View {
        Button("Save") {
            guard let vm else { return }
            Task { await vm.save() }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(vm == nil || vm?.isDirty != true || vm?.saveState == .saving)
    }
}

// MARK: - View menu (pane toggles + source PDF actions)

/// Top-level View menu that owns the editor's pane toggles. Pane
/// visibility lives in `@SceneStorage` inside `EditorView`, so the menu
/// items have to round-trip through the focused viewmodel — we expose
/// togglers on the VM that the SceneStorage state mirrors.
struct EditorViewMenu: Commands {
    var body: some Commands {
        CommandMenu("View") {
            EditorPaneToggle(pane: .pdf)
            EditorPaneToggle(pane: .source)
            EditorPaneToggle(pane: .preview)
            Divider()
            EditorAttachPDFCommand()
        }
    }
}

private struct EditorPaneToggle: View {
    @FocusedValue(\.editorViewModel) private var vm: EditorViewModel?
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
    @FocusedValue(\.editorViewModel) private var vm: EditorViewModel?

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
