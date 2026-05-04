import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct HumanistApp: App {
    /// Persistent job queue shared across the launcher's lifetime.
    /// `@StateObject` so the store survives view-tree rebuilds; the
    /// runner observes the same store and processes serially.
    @StateObject private var jobStore = JobStore()
    @StateObject private var jobRunner: JobRunner
    @StateObject private var queueVM: QueueViewModel

    init() {
        let store = JobStore()
        let runner = JobRunner(store: store)
        let vm = QueueViewModel(store: store, runner: runner)
        // Use `_` initializers to wire StateObjects from outside the
        // property wrapper's default-value path. The store/runner pair
        // is built once and shared across all three.
        _jobStore  = StateObject(wrappedValue: store)
        _jobRunner = StateObject(wrappedValue: runner)
        _queueVM   = StateObject(wrappedValue: vm)
    }

    var body: some Scene {
        // Launcher window: queue panel + drop zone for PDFs / folders.
        WindowGroup("Humanist") {
            ContentView()
                .environmentObject(queueVM)
                .environmentObject(jobStore)
                .environmentObject(jobRunner)
                .frame(minWidth: 620, minHeight: 520)
        }
        .commands {
            FileMenuCommands()
            EditorViewMenu()
        }

        // Editor window: one per opened EPUB. macOS reuses an existing
        // window when the same URL value is reopened, so dragging the
        // same .epub twice doesn't duplicate.
        //
        // No `.commands` attached here. The launcher scene above
        // declares them once; SwiftUI surfaces command items in the
        // global menu bar, and `@FocusedObject` inside each command
        // resolves to whichever editor is currently focused. Adding
        // `.commands` per-scene would create duplicate "Document"
        // menus in the bar (one per scene declaring it), which we've
        // bounced back and forth on — keeping it single-attached.
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
            OpenRecentMenu()
            ConvertCommand()
        }
        CommandGroup(replacing: .saveItem) {
            EditorSaveCommand()
            EditorSaveAsCommand()
        }
    }
}

/// File > Open Recent ▸ — the last 10 EPUBs/PDFs the user opened
/// (deduped, most recent first). Backed by `RecentsStore` via
/// @AppStorage so the menu re-renders when the list changes.
private struct OpenRecentMenu: View {
    @Environment(\.openWindow) private var openWindow
    // Observed so the menu re-renders when openings update the list.
    @AppStorage(RecentsStore.key) private var recentsJSON: String = "[]"

    var body: some View {
        Menu("Open Recent") {
            let urls = RecentsStore.urls
            if urls.isEmpty {
                Text("No Recent Items").disabled(true)
            } else {
                ForEach(urls, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        OpenRouter.open(url, openWindow: openWindow)
                    }
                }
                Divider()
                Button("Clear Menu") { RecentsStore.clear() }
            }
        }
    }
}

/// One place to route a URL to the right window kind. Keeps
/// recents-recording consistent across menu / drop / convert paths.
enum OpenRouter {
    static func open(_ url: URL, openWindow: OpenWindowAction) {
        RecentsStore.add(url)
        switch url.pathExtension.lowercased() {
        case "epub": openWindow(id: "editor", value: url)
        case "pdf":  openWindow(id: "pdf-viewer", value: url)
        default: break
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
            OpenRouter.open(url, openWindow: openWindow)
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
            RecentsStore.add(url)
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
