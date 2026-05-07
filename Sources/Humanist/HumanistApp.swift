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

        // When launched as a raw executable (e.g. `swift run` or
        // `./.build/debug/Humanist`) instead of from a notarized
        // `.app` bundle, macOS treats the process as `.accessory`
        // by default — no Dock icon, no menu bar takeover, the
        // calling Terminal keeps keyboard focus and the user can't
        // reach Settings via ⌘,. Forcing `.regular` + activating
        // explicitly fixes both. No-op when launched from a bundled
        // .app (Phase 10 distribution path) since the bundle's
        // Info.plist already sets the right policy.
        // `NSApp` (the implicitly-unwrapped global) isn't set yet
        // during App.init — SwiftUI hasn't booted the runtime. Use
        // `NSApplication.shared` instead; that accessor creates the
        // singleton if needed.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // Launcher window: queue panel + drop zone for PDFs / folders.
        // All menu-bar commands attach here — the items appear in the
        // global menu bar regardless of which window is focused, and
        // the Save / Save As items use `EditorCommandRouter` (driven
        // by NSApp.keyWindow) instead of `@FocusedObject` so they
        // reliably enable/disable as the user switches between editor
        // windows. The Document menu also attaches once here; its
        // items use `@FocusedObject` and disable themselves when no
        // editor is focused.
        WindowGroup("Humanist") {
            ContentView()
                .environmentObject(queueVM)
                .environmentObject(jobStore)
                .environmentObject(jobRunner)
                .frame(minWidth: 620, minHeight: 520)
        }
        .commands {
            FileOpenCommands()
            EditorSaveCommands()
            EditorFindCommands()
            EditorFormatMenu()
            EditorInsertMenu()
            EditorToolsMenu()
            EditorViewMenu()
            ShowFullQueueCommand()
            CommandGroup(after: .help) {
                Button("Show Welcome…") {
                    NotificationCenter.default.post(
                        name: .humanistShowWelcome, object: nil
                    )
                }
            }
        }

        // R-Launcher-FullQueue. Single-instance window for the bulk
        // queue — designed to hold hundreds of rows with sortable
        // columns and one-click actions, without competing for the
        // launcher's drop / options / bottom-bar real estate. Same
        // store + runner as the launcher, threaded back in via
        // environmentObject (App scenes don't auto-propagate).
        Window("Humanist Queue", id: "queue") {
            QueueWindowView()
                .environmentObject(jobStore)
                .environmentObject(jobRunner)
        }
        .commandsRemoved()  // no per-window menu items beyond what the launcher already attaches

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

        // Standard macOS Settings (⌘,) scene. TabView so the
        // Editor and AI panes each get their own surface; future
        // tabs (default languages, default output location) slot
        // in alongside.
        Settings {
            TabView {
                EditorSettingsView()
                    .tabItem { Label("Editor", systemImage: "text.cursor") }
                AISettingsView()
                    .tabItem { Label("AI", systemImage: "sparkles") }
            }
            .frame(width: 540, height: 520)
        }
    }
}

/// File menu — Open / Open Recent / Convert / Split. Replaces the
/// default `.newItem` placement (which would otherwise carry SwiftUI's
/// stock New/Open pair). Save / Save As live separately in
/// `EditorSaveCommands` so they only attach to the editor scene.
///
///   * **Open** — view-only. PDF → PDF viewer, EPUB → editor.
///   * **Convert PDF to EPUB** — runs the OCR pipeline and opens the
///     editor on the resulting .epub. Same flow as drag-drop on the
///     launcher window.
private struct FileOpenCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            OpenCommand()
            OpenRecentMenu()
            ConvertCommand()
            Divider()
            SplitTwoUpCommand()
        }
    }
}

/// File > Save / Save As. Placed `after: .newItem` (i.e. right below
/// our Open / Convert section) rather than `replacing: .saveItem`
/// because the `.saveItem` placement appears to be silently dropped
/// on some macOS / SwiftUI builds when the app isn't a DocumentGroup
/// — items declared there never reach the menu bar at all. `after`
/// is unambiguous: it always inserts in the File menu after the
/// `.newItem` placement we already populate. Items route through
/// `EditorCommandRouter`, not `@FocusedObject`, so the enable/disable
/// state tracks the active editor reliably.
struct EditorSaveCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            EditorSaveCommand()
            EditorSaveAsCommand()
        }
    }
}

/// Edit > Find / Find Next / Find Previous / Find and Replace.
/// CodeMirror's search dialog is the right surface, but the
/// default SwiftUI Edit > Find group dispatches via
/// `performTextFinderAction:` which CodeMirror's WKWebView doesn't
/// participate in — ⌘F does nothing without our intervention. We
/// add items routed through `EditorCommandRouter` (keyWindow-driven)
/// so the JS bridge actually receives the commands. Placed
/// `after: .pasteboard` (i.e. just below Cut/Copy/Paste).
struct EditorFindCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            EditorFindCommand()
            EditorFindNextCommand()
            EditorFindPrevCommand()
            EditorReplaceCommand()
            EditorFindInFilesCommand()
            Divider()
            EditorGotoLineCommand()
            Divider()
            EditorSpellCheckCommand()
        }
    }
}

private struct EditorFindInFilesCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Find in All Files…") { router.showFindInFilesSheet() }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!router.canFind)
    }
}

private struct EditorGotoLineCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Go to Line…") { router.showGotoLineSheet() }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!router.canFind)
    }
}

private struct EditorSpellCheckCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Check Document Spelling…") { router.openSpellCheck() }
            .keyboardShortcut(";", modifiers: [.command, .shift])
            .disabled(!router.canFind)
    }
}

private struct EditorFindCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Find…") { router.openFind() }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!router.canFind)
    }
}

private struct EditorFindNextCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Find Next") { router.findNext() }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(!router.canFind)
    }
}

private struct EditorFindPrevCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Find Previous") { router.findPrev() }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!router.canFind)
    }
}

private struct EditorReplaceCommand: View {
    @ObservedObject private var router = EditorCommandRouter.shared
    var body: some View {
        Button("Find and Replace…") { router.openReplace() }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(!router.canFind)
    }
}

/// File > Split Two-Up PDF… — manual entry point for cases where
/// auto-detect at queue-add missed (or the user wants to split a PDF
/// without queueing it for conversion). Opens a file picker → save
/// dialog → splits → confirms with an alert.
private struct SplitTwoUpCommand: View {
    var body: some View {
        Button("Split Two-Up PDF…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            _ = TwoUpPrompt.runManual(pdfURL: url)
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

/// Window > Show Full Queue (⇧⌘Q). Opens the dedicated full-queue
/// window (single instance — opening when already open just
/// brings it to the front). Placed in the standard `.windowList`
/// position so it sits alongside the OS-provided window-list
/// items in the Window menu.
private struct ShowFullQueueCommand: Commands {
    var body: some Commands {
        CommandGroup(before: .windowList) {
            ShowFullQueueButton()
            Divider()
        }
    }
}

private struct ShowFullQueueButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Queue") {
            openWindow(id: "queue")
        }
        .keyboardShortcut("q", modifiers: [.command, .shift])
    }
}

extension Notification.Name {
    /// The launcher window listens for this and starts a conversion.
    static let humanistConvertPDF = Notification.Name("humanistConvertPDF")
    /// Editor windows listen for this and show the correction-trail
    /// sheet. Posted by the Document menu item, which lives on the
    /// launcher scene and can't reach an editor's @State directly.
    static let humanistShowCorrectionTrail = Notification.Name(
        "humanistShowCorrectionTrail"
    )
    /// Launcher window listens for this and re-opens the first-run
    /// welcome sheet. Posted by the Help menu item.
    static let humanistShowWelcome = Notification.Name(
        "humanistShowWelcome"
    )
}
