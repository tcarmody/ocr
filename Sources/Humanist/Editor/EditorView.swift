import SwiftUI
import AppKit
import EPUB

/// Three-pane EPUB editor window.
///   * left:   file tree (`BookBrowser`)
///   * center: source pane — writable `TextEditor` for text files,
///             placeholder for binaries
///   * right:  rendered preview (`PreviewView`)
///
/// Edits are buffered in memory; Save (Cmd-S) flushes the buffers to
/// the working directory and re-zips the EPUB at the source URL.
struct EditorView: View {
    let epubURL: URL
    @StateObject private var vm: EditorViewModel

    init(epubURL: URL) {
        self.epubURL = epubURL
        _vm = StateObject(wrappedValue: EditorViewModel(epubURL: epubURL))
    }

    var body: some View {
        Group {
            switch vm.state {
            case .loading:
                ProgressView("Opening \(epubURL.lastPathComponent)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text("Could not open EPUB")
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            case .ready:
                if let pkg = vm.package {
                    NavigationSplitView {
                        BookBrowser(
                            root: pkg.fileTree,
                            selection: Binding(
                                get: { vm.selectedFile },
                                set: { if let n = $0 { vm.select(n) } }
                            )
                        )
                        .frame(minWidth: 220)
                    } detail: {
                        editorPanes(workingDir: pkg.workingDirectory)
                    }
                    .navigationTitle(pkg.displayTitle)
                    .navigationSubtitle(saveStatusSubtitle)
                    .toolbar { toolbarContent }
                    .background(WindowDirtyBridge(isDirty: vm.isDirty))
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await vm.save() }
            } label: {
                Label("Save", systemImage: "tray.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!vm.isDirty || vm.saveState == .saving)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                vm.revealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }

    private var saveStatusSubtitle: String {
        switch vm.saveState {
        case .saving:               return "Saving…"
        case .failed(let message):  return "Save failed: \(message)"
        case .idle:                 return vm.isDirty ? "Unsaved changes" : ""
        }
    }

    @ViewBuilder
    private func editorPanes(workingDir: URL) -> some View {
        HSplitView {
            sourcePane
                .frame(minWidth: 280)
            PreviewView(file: vm.selectedFile, workingDirectory: workingDir)
                .frame(minWidth: 280)
        }
    }

    @ViewBuilder
    private var sourcePane: some View {
        if let file = vm.selectedFile, EditorViewModel.isTextFile(file.id) {
            TextEditor(text: vm.sourceBinding)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                // re-mount the editor on file change so text + scroll
                // position reset properly.
                .id(file.id)
        } else if vm.selectedFile != nil {
            VStack {
                Text("Binary file").foregroundStyle(.secondary)
                Text("(see preview)").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }
}

/// Tiny NSViewRepresentable that, when mounted, finds its hosting
/// NSWindow and toggles `isDocumentEdited`. macOS shows a dot in the
/// red close button when this is true. Pure side-effect view — has
/// no visible representation.
private struct WindowDirtyBridge: NSViewRepresentable {
    let isDirty: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // Defer the lookup; the view isn't in a window yet at make time.
        DispatchQueue.main.async { v.window?.isDocumentEdited = isDirty }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.isDocumentEdited = isDirty }
    }
}
