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
            CommandGroup(replacing: .newItem) {
                OpenCommand()
            }
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
    }
}

/// File > Open… menu item. Lives in its own view so it can pull
/// `openWindow` out of the environment (commands themselves don't have
/// view-scoped environment access).
private struct OpenCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open EPUB or PDF…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.epub, .pdf]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if url.pathExtension.lowercased() == "epub" {
                openWindow(id: "editor", value: url)
            } else {
                // PDFs go to the launcher's converter via a notification —
                // the launcher view listens. (We can't do "open the
                // launcher window AND tell it to convert URL X" with
                // openWindow alone.)
                NotificationCenter.default.post(
                    name: .humanistConvertPDF,
                    object: nil,
                    userInfo: ["url": url]
                )
            }
        }
        .keyboardShortcut("o", modifiers: .command)
    }
}

extension Notification.Name {
    /// The launcher window listens for this and starts a conversion.
    static let humanistConvertPDF = Notification.Name("humanistConvertPDF")
}
