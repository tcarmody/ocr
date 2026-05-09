import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Layout  // SuryaConnection.shared for E-Warm

@main
struct HumanistApp: App {
    /// Persistent job queue shared across the launcher's lifetime.
    /// `@StateObject` so the store survives view-tree rebuilds; the
    /// runner observes the same store and processes serially.
    @StateObject private var jobStore = JobStore()
    @StateObject private var jobRunner: JobRunner
    @StateObject private var queueVM: QueueViewModel
    @StateObject private var library = LibraryStore()
    @StateObject private var coverCache = CoverImageCache()

    init() {
        let store = JobStore()
        let lib = LibraryStore()
        let runner = JobRunner(store: store, library: lib)
        let vm = QueueViewModel(store: store, runner: runner)
        // Use `_` initializers to wire StateObjects from outside the
        // property wrapper's default-value path. The store/runner pair
        // is built once and shared across all three.
        _jobStore  = StateObject(wrappedValue: store)
        _library   = StateObject(wrappedValue: lib)
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

        // Tier 9 / E-Warm: kick the Surya sidecar's Python
        // interpreter + Surya imports off the launch path so the
        // first conversion doesn't pay the ~5-15s spawn cost. Fire-
        // and-forget — failure (Surya not installed, sidecar script
        // missing) silently falls back to the existing Vision /
        // Tesseract path on first conversion. Model weights still
        // load lazily on first inference, but Python startup +
        // imports are the bulk of the latency.
        Task.detached(priority: .background) {
            guard let conn = SuryaConnection.shared else { return }
            try? await conn.bridge.startIfNeeded()
        }
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
                .environmentObject(library)
                .frame(minWidth: 620, minHeight: 520)
                .humanistChrome()
                .onAppear {
                    // R-Library: stash the library on OpenRouter so
                    // the editor-open path can bump `lastOpened`
                    // without threading the store through every
                    // call site.
                    OpenRouter.library = library
                }
        }
        .commands {
            FileOpenCommands()
            EditorSaveCommands()
            EditorFindCommands()
            EditorFormatMenu()
            EditorInsertMenu()
            EditorToolsMenu()
            EditorViewMenu()
            EditorDocumentMenu()
            ShowWindowCommands()
            HelpMenuCommands()
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
                .humanistChrome()
        }
        .commandsRemoved()  // no per-window menu items beyond what the launcher already attaches

        // R-Library. Single-instance window listing every EPUB the
        // user has converted in this app. Same env-object plumbing
        // as the queue window.
        Window("Humanist Library", id: "library") {
            LibraryWindowView()
                .environmentObject(library)
                .environmentObject(coverCache)
                .humanistChrome()
        }
        .commandsRemoved()

        // O-Diff. Single-instance window for the most-recent EPUB
        // comparison. Tools → Compare EPUBs… stashes a diff on
        // EPUBDiffPresenter and posts `humanistShowEPUBDiff`; the
        // launcher picks up that notification (it's the only scene
        // that can openWindow from a notification callback) and
        // brings the window forward.
        Window("Compare EPUBs", id: "epub-diff") {
            EPUBDiffWindow()
                .humanistChrome()
        }
        .commandsRemoved()

        // Editor window: one per opened EPUB. macOS reuses an existing
        // window when the same URL value is reopened, so dragging the
        // same .epub twice doesn't duplicate.
        WindowGroup("Editor", id: "editor", for: URL.self) { $url in
            if let url {
                EditorView(epubURL: url)
                    .frame(minWidth: 900, minHeight: 600)
                    .humanistChrome()
            } else {
                // nil URL means macOS tried to restore an editor window
                // from a previous session but scene storage couldn't
                // decode the URL (e.g. the working temp dir was cleaned
                // up). Dismiss immediately so the launcher stays front
                // and the user isn't stranded in a broken editor state.
                _StaleWindowDismisser()
            }
        }

        // Source viewer window: opened by File > Open on a PDF, or by
        // the editor's "Show Original" command. Same URL → same
        // window. Dispatches by extension so PDFs use PDFKit and
        // other formats render via WebView / NSTextView as
        // appropriate.
        WindowGroup("Original", id: "source-viewer", for: URL.self) { $url in
            if let url {
                SourceViewerView(sourceURL: url)
                    .humanistChrome()
            } else {
                Text("No document loaded.")
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
                ConversionSettingsView()
                    .tabItem { Label("Conversion", systemImage: "folder") }
                AISettingsView()
                    .tabItem { Label("AI", systemImage: "sparkles") }
                AppearanceSettingsView()
                    .tabItem { Label("Appearance", systemImage: "paintpalette") }
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
            Divider()
            FileToolsButtons()
        }
    }
}

/// File-system utilities — Join / Split for PDFs and EPUBs.
/// Wrapped in a single View so the parent `CommandGroup` body
/// stays under SwiftUI's @CommandsBuilder 10-component cap; the
/// flat button list inside this View body uses the same builder
/// rule but with its own 10-item budget.
private struct FileToolsButtons: View {
    var body: some View {
        Button("Join PDFs…") { ToolsPrompts.runJoinPDFs() }
        Button("Split PDF…") { ToolsPrompts.runSplitPDF() }
        Button("Join EPUBs…") { ToolsPrompts.runJoinEPUBs() }
        Button("Split EPUB…") { ToolsPrompts.runSplitEPUB() }
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
        // Wrapped in sub-Views to keep the body under SwiftUI's
        // @CommandsBuilder 10-element cap. See
        // feedback_swiftui_commandsbuilder_cap.md.
        CommandGroup(after: .pasteboard) {
            Divider()
            FindMenuSearchCommands()
            Divider()
            EditorGotoLineCommand()
            Divider()
            EditorSpellCheckCommand()
        }
    }
}

private struct FindMenuSearchCommands: View {
    var body: some View {
        RouterButton("Find…", shortcut: "f") { $0.openFind() }
        RouterButton("Find Next", shortcut: "g") { $0.findNext() }
        RouterButton(
            "Find Previous", shortcut: "g", modifiers: [.command, .shift]
        ) { $0.findPrev() }
        RouterButton(
            "Find and Replace…", shortcut: "f", modifiers: [.command, .option]
        ) { $0.openReplace() }
        RouterButton(
            "Find in All Files…", shortcut: "f", modifiers: [.command, .shift]
        ) { $0.showFindInFilesSheet() }
    }
}

private struct EditorGotoLineCommand: View {
    var body: some View {
        RouterButton("Go to Line…", shortcut: "l") { $0.showGotoLineSheet() }
    }
}

private struct EditorSpellCheckCommand: View {
    var body: some View {
        RouterButton(
            "Check Document Spelling…", shortcut: ";",
            modifiers: [.command, .shift]
        ) { $0.openSpellCheck() }
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
@MainActor
enum OpenRouter {
    /// Library catalog the open path bumps `lastOpened` against
    /// when an EPUB is opened. Set once at app launch in
    /// `HumanistApp.body` via the `.onAppear` modifier on the
    /// launcher's WindowGroup; nil before that or in test
    /// fixtures, in which case `recordOpen` is a no-op (which is
    /// the correct fallback — the editor still opens).
    static var library: LibraryStore?

    static func open(_ url: URL, openWindow: OpenWindowAction) {
        RecentsStore.add(url)
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "epub":
            library?.recordOpen(url)
            openWindow(id: "editor", value: url)
        default:
            // PDF + every other format the SourceViewer can render
            // (HTML / DOCX / RTF / MD / TXT / ODT / DOC) goes through
            // the unified source-viewer scene.
            openWindow(id: "source-viewer", value: url)
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

/// Window menu — Show Queue (⇧⌘Q) + Show Library (⇧⌘L). Both open
/// single-instance scenes; opening when already open just brings to
/// front. Placed in the standard `.windowList` position so they sit
/// alongside the OS-provided window-list items.
struct ShowWindowCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .windowList) {
            ShowQueueButton()
            ShowLibraryButton()
            Divider()
        }
    }
}

private struct ShowQueueButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Queue") { openWindow(id: "queue") }
            .keyboardShortcut("q", modifiers: [.command, .shift])
    }
}

private struct ShowLibraryButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Library") { openWindow(id: "library") }
            .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}

/// Help > Show Welcome…. Pulled into its own `Commands` struct so
/// the top-level `.commands` block can address it as a single slot.
struct HelpMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Show Welcome…") {
                NotificationCenter.default.post(
                    name: .humanistShowWelcome, object: nil
                )
            }
        }
    }
}

/// Shown when a `WindowGroup("Editor", for: URL.self)` window is
/// restored from a previous session but the URL could not be decoded
/// (e.g. the EPUB's working temp directory was cleaned up at quit).
/// Dismisses the window on appear so the user isn't stranded in a
/// blank editor — the launcher window becomes front instead.
private struct _StaleWindowDismisser: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear { dismiss() }
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
    /// Launcher window listens for this and opens the EPUB diff
    /// window. Posted by Tools → Compare EPUBs… after the differ
    /// has populated the presenter.
    static let humanistShowEPUBDiff = Notification.Name(
        "humanistShowEPUBDiff"
    )
}
