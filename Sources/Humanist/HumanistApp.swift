import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct HumanistApp: App {
    var body: some Scene {
        // Launcher window: drop a PDF to convert, drop an EPUB to edit.
        WindowGroup("Humanist") {
            ContentView()
                .frame(minWidth: 560, minHeight: 420)
        }
        .windowResizability(.contentSize)
        .commands {
            FileMenuCommands()
            EditorViewMenu()
        }

        // Editor window: one per opened EPUB. macOS reuses an existing
        // window when the same URL value is reopened, so dragging the
        // same .epub twice doesn't duplicate.
        WindowGroup("Editor", id: "editor", for: URL.self) { $url in
            if let url {
                EditorView(epubURL: url)
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                Text("No EPUB loaded.")
            }
        }

        // PDF viewer window: opened by File > Open on a PDF, or by the
        // editor's "Open Source PDF…" command. Same URL → same window.
        WindowGroup("PDF", id: "pdf-viewer", for: URL.self) { $url in
            if let url {
                PDFViewerView(pdfURL: url)
            } else {
                Text("No PDF loaded.")
            }
        }
    }
}

/// File menu rebuild. We replace `.newItem` (the default New/Open
/// pair) with two distinct actions:
///
///   * **Open** — view-only. PDF → PDF viewer, EPUB → editor.
///   * **Convert PDF to EPUB** — runs the OCR pipeline and opens the
///     editor on the resulting .epub. Same flow as drag-drop on the
///     launcher window.
private struct FileMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            OpenCommand()
            ConvertCommand()
        }
        CommandGroup(replacing: .saveItem) {
            EditorSaveCommand()
        }
    }
}

private struct OpenCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.epub, .pdf]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            switch url.pathExtension.lowercased() {
            case "epub": openWindow(id: "editor", value: url)
            case "pdf":  openWindow(id: "pdf-viewer", value: url)
            default:     break
            }
        }
        .keyboardShortcut("o", modifiers: .command)
    }
}

private struct ConvertCommand: View {
    var body: some View {
        Button("Convert PDF to EPUB…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            // The launcher window owns the conversion ViewModel; route
            // the URL to it. (We can't reach a SwiftUI ViewModel from
            // an App-scope command directly.)
            NotificationCenter.default.post(
                name: .humanistConvertPDF,
                object: nil,
                userInfo: ["url": url]
            )
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
    }
}

extension Notification.Name {
    /// The launcher window listens for this and starts a conversion.
    static let humanistConvertPDF = Notification.Name("humanistConvertPDF")
}
