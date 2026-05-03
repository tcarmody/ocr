import SwiftUI
import EPUB

/// Three-pane EPUB editor window.
///   * left:   file tree (`BookBrowser`)
///   * center: source pane (TextEditor for text files, label otherwise)
///   * right:  rendered preview (`PreviewView`)
///
/// View-only for v1: the source TextEditor is read-only. Phase 6.B
/// will flip this to read/write and wire a save/repack action.
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
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                vm.revealInFinder()
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
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
        if let source = vm.selectedSource {
            // TextEditor in read-only mode for v1 — the .disabled
            // modifier visually grays it out but still allows
            // selection + scrolling, which is what we want.
            ScrollView {
                Text(source)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
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
