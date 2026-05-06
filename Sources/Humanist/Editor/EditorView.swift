import SwiftUI
import AppKit
import EPUB

/// Editor window with up to four panes: file-tree sidebar plus a
/// configurable horizontal split of (PDF source · XHTML source ·
/// rendered preview). Each of the three center panes can be toggled
/// independently so the same window adapts from a focused-edit layout
/// to the full PDF-vs-EPUB review layout.
struct EditorView: View {
    let epubURL: URL
    @StateObject private var vm: EditorViewModel
    @State private var showingCorrectionTrail = false
    @Environment(\.openWindow) private var openWindow
    // User preferences from the Settings pane. SwiftUI re-renders
    // EditorView (and re-fires `updateNSView` on the embedded
    // CodeMirror / Preview WKWebViews) on each value change, which
    // is the trigger for pushing the new value through the JS
    // bridge.
    @AppStorage(EditorSettingsKeys.sourceFontSize)
    private var sourceFontSize: Double = EditorSettingsDefaults.sourceFontSize
    @AppStorage(EditorSettingsKeys.sourceTheme)
    private var sourceTheme: String = EditorSettingsDefaults.sourceTheme
    @AppStorage(EditorSettingsKeys.sourceLineNumbers)
    private var sourceLineNumbers: Bool = EditorSettingsDefaults.sourceLineNumbers
    @AppStorage(EditorSettingsKeys.sourceWordWrap)
    private var sourceWordWrap: Bool = EditorSettingsDefaults.sourceWordWrap
    @AppStorage(EditorSettingsKeys.previewFontSize)
    private var previewFontSize: Double = EditorSettingsDefaults.previewFontSize
    @AppStorage(EditorSettingsKeys.previewTheme)
    private var previewTheme: String = EditorSettingsDefaults.previewTheme

    init(epubURL: URL) {
        self.epubURL = epubURL
        _vm = StateObject(wrappedValue: EditorViewModel(epubURL: epubURL))
    }

    private var showPDF:     Bool { vm.showPDFPane }
    private var showSource:  Bool { vm.showSourcePane }
    private var showPreview: Bool { vm.showPreviewPane }

    var body: some View {
        Group {
            switch vm.state {
            case .loading:
                ProgressView("Opening \(epubURL.lastPathComponent)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                failureView(message)
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
                            .onAppear { reconcilePaneDefaults() }
                            .onChange(of: vm.sourcePDFURL) { _, _ in reconcilePaneDefaults() }
                    }
                    .navigationTitle(pkg.displayTitle)
                    .navigationSubtitle(saveStatusSubtitle)
                    .toolbar { toolbarContent }
                    .background(WindowDirtyBridge(isDirty: vm.isDirty))
                    // Two routing channels for menu-bar commands:
                    //   * `.focusedObject` — read by `@FocusedObject`
                    //     in EditorCommands' Document menu (pane
                    //     toggles, re-OCR, etc.). Works for items
                    //     declared in CommandMenu.
                    //   * `EditorCommandRouter` — keyWindow-driven
                    //     singleton for Save / Save As. The
                    //     focused-object path didn't propagate
                    //     reliably into items inside
                    //     `CommandGroup(replacing: .saveItem)`; the
                    //     router uses NSApp.keyWindow and the vm's
                    //     @Published state to drive enable/disable.
                    .focusedObject(vm)
                    .onAppear { EditorCommandRouter.shared.bind(vm) }
                    .onDisappear { EditorCommandRouter.shared.unbind(vm) }
                    .sheet(item: Binding(
                        get: { vm.reOCRResult },
                        set: { vm.reOCRResult = $0 }
                    )) { result in
                        ReOCRResultSheet(
                            result: result,
                            onReplaceInSource: {
                                switch result.replaceTarget {
                                case .sourceSelection:
                                    vm.replaceSourceSelection(with: result.text)
                                case .pageInSource(let anchorId):
                                    // Prefer the well-formed XHTML
                                    // fragment when we have one (the
                                    // page path always sets it). Fall
                                    // back to plain text for safety.
                                    let payload = result.replacementXHTML ?? result.text
                                    vm.replacePageInSource(
                                        anchorId: anchorId, text: payload
                                    )
                                }
                                vm.reOCRResult = nil
                            },
                            onDismiss: { vm.reOCRResult = nil }
                        )
                    }
                    .sheet(isPresented: $showingCorrectionTrail) {
                        CorrectionTrailSheet(
                            vm: vm,
                            isPresented: $showingCorrectionTrail
                        )
                    }
                    .sheet(isPresented: Binding(
                        get: { vm.spellCheckSession != nil },
                        set: { presented in
                            if !presented { vm.spellCheckSession = nil }
                        }
                    )) {
                        if let session = vm.spellCheckSession {
                            SpellCheckSheet(
                                vm: vm,
                                session: session,
                                isPresented: Binding(
                                    get: { vm.spellCheckSession != nil },
                                    set: { presented in
                                        if !presented { vm.spellCheckSession = nil }
                                    }
                                )
                            )
                        }
                    }
                    // Document menu's "Show Correction Trail" command
                    // posts this notification so the menu item can
                    // reach this scene's local @State `showingCorrectionTrail`
                    // (commands attach to the launcher scene; @State
                    // here can't be read from there).
                    .onReceive(NotificationCenter.default.publisher(
                        for: .humanistShowCorrectionTrail
                    )) { _ in
                        showingCorrectionTrail = true
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: - panes

    /// Pick the right `HSplitView` shape for the current visibility
    /// triple. Switching is verbose but the alternative — a single
    /// HSplitView with conditional EmptyView children — gives every
    /// hidden pane real layout space.
    @ViewBuilder
    private func editorPanes(workingDir: URL) -> some View {
        switch (showPDF, showSource, showPreview) {
        case (true, true, true):
            HSplitView {
                pdfPane.frame(minWidth: 240)
                sourcePane.frame(minWidth: 240)
                previewPane(workingDir: workingDir).frame(minWidth: 240)
            }
        case (true, true, false):
            HSplitView {
                pdfPane.frame(minWidth: 280)
                sourcePane.frame(minWidth: 280)
            }
        case (true, false, true):
            HSplitView {
                pdfPane.frame(minWidth: 280)
                previewPane(workingDir: workingDir).frame(minWidth: 280)
            }
        case (false, true, true):
            HSplitView {
                sourcePane.frame(minWidth: 280)
                previewPane(workingDir: workingDir).frame(minWidth: 280)
            }
        case (true, false, false):
            pdfPane
        case (false, true, false):
            sourcePane
        case (false, false, true):
            previewPane(workingDir: workingDir)
        case (false, false, false):
            allPanesHiddenState
        }
    }

    @ViewBuilder
    private var pdfPane: some View {
        if let controller = vm.pdfController {
            VStack(spacing: 0) {
                paneHeader("Source PDF", systemImage: "doc.richtext.fill") {
                    pdfPaneToolbar
                }
                PDFKitView(pdfView: controller.pdfView)
                    .background(Color(nsColor: .underPageBackgroundColor))
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No source PDF attached").foregroundStyle(.secondary)
                Button("Attach Source PDF…") { attachSourcePDF() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// Trailing accessory for the PDF pane header — zoom + page nav
    /// inline so the user can drive the pane without going to the
    /// menu bar. Mirrors View > Source PDF ▸ exactly.
    private var pdfPaneToolbar: some View {
        HStack(spacing: 2) {
            Button {
                vm.pdfPrevPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Previous Page (⇧⌘←)")

            Button {
                vm.pdfNextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("Next Page (⇧⌘→)")

            Divider().frame(height: 12).padding(.horizontal, 4)

            Button {
                vm.pdfZoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom Out (⌘−)")

            Button {
                vm.pdfZoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom In (⌘=)")

            Button {
                vm.pdfFitPage()
            } label: {
                Image(systemName: "rectangle.arrowtriangle.2.inward")
            }
            .help("Fit Page (⌘0)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(!vm.canNavigatePDF)
    }

    @ViewBuilder
    private var sourcePane: some View {
        VStack(spacing: 0) {
            paneHeader("Source", systemImage: "chevron.left.forwardslash.chevron.right")
            // Formatting toolbar only when an editable text file is
            // selected — for binary files (images, fonts) the source
            // pane shows a placeholder instead and the toolbar
            // would have nothing to act on.
            if vm.selectedFile != nil, vm.canEditSelectedFile {
                SourceFormattingToolbar(vm: vm)
            }
            sourceContent
            validationStrip
        }
    }

    /// Shown under the source pane only when the most recent Save
    /// detected an XML parse error in the file the user is currently
    /// looking at. Cleared on the next clean Save. Save is non-blocking,
    /// so the strip is informational — the file is on disk, but it
    /// won't render in the preview (or in real EPUB readers) until the
    /// XML parses.
    @ViewBuilder
    private var validationStrip: some View {
        if let url = vm.selectedFile?.id,
           let issue = vm.validationIssues[url] {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("XML parse error: \(issue)")
                    .font(.caption)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .top) { Divider() }
        }
    }

    @ViewBuilder
    private var sourceContent: some View {
        if let file = vm.selectedFile, vm.canEditSelectedFile {
            CodeEditorView(
                text: $vm.sourceText,
                language: CodeEditorView.Language.from(url: file.id),
                resetID: AnyHashable(file.id),
                scrollRequest: vm.scrollCodeToAnchor,
                replaceRequest: vm.replaceSourceRequest,
                replacePageRequest: vm.replacePageRequest,
                formatRequest: vm.formatRequest,
                searchRequest: vm.searchRequest,
                fontSize: sourceFontSize,
                theme: sourceTheme,
                lineNumbers: sourceLineNumbers,
                wordWrap: sourceWordWrap,
                onCursorAnchorChanged: { id in vm.didMoveCursorToAnchor(id) }
            )
            .id(file.id)
            .onChange(of: vm.sourceText) { _, _ in
                vm.didEditSourceText()
            }
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

    @ViewBuilder
    private func previewPane(workingDir: URL) -> some View {
        VStack(spacing: 0) {
            paneHeader("Preview", systemImage: "eye")
            PreviewView(
                file: vm.selectedFile,
                workingDirectory: workingDir,
                reloadTrigger: vm.previewVersion,
                scrollRequest: vm.scrollPreviewToAnchor,
                fontSize: previewFontSize,
                theme: previewTheme,
                onAnchorVisible: { id in vm.didReportPreviewAnchor(id) }
            )
        }
    }

    @ViewBuilder
    private func paneHeader<Trailing: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var allPanesHiddenState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("All panes hidden").foregroundStyle(.secondary)
            Text("Use the toolbar toggles or ⌘1 / ⌘2 / ⌘3 to show a pane.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Could not open EPUB").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // Toolbar toggles mirror the View > Show … menu items;
            // both flow through `vm.togglePane` so menu, keyboard
            // shortcut, and toolbar stay in lockstep.
            Toggle(isOn: paneBinding(.pdf)) {
                Label("Show PDF", systemImage: "doc.richtext")
            }
            .help("Toggle the PDF source pane (⌘1)")

            Toggle(isOn: paneBinding(.source)) {
                Label("Show Source", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .help("Toggle the XHTML source pane (⌘2)")

            Toggle(isOn: paneBinding(.preview)) {
                Label("Show Preview", systemImage: "eye")
            }
            .help("Toggle the rendered preview pane (⌘3)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await vm.save() }
            } label: {
                Label("Save", systemImage: "tray.and.arrow.down")
            }
            .disabled(!vm.isDirty || vm.saveState == .saving)
            .help("Save changes back to the .epub (⌘S)")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if vm.sourcePDFURL == nil {
                    Button("Attach Source PDF…") { attachSourcePDF() }
                } else {
                    Button("Change Source PDF…") { attachSourcePDF() }
                    Button("Open Source PDF in New Window") { openSourcePDFWindow() }
                    Divider()
                    Button("Detach Source PDF", role: .destructive) {
                        vm.detachSourcePDF()
                    }
                }
            } label: {
                Label(
                    vm.sourcePDFURL?.lastPathComponent ?? "Source PDF",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            .help("Manage the source PDF associated with this EPUB")
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

    // MARK: - actions

    private func attachSourcePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            vm.attachSourcePDF(url)
        }
    }

    private func openSourcePDFWindow() {
        guard let url = vm.sourcePDFURL else { return }
        openWindow(id: "pdf-viewer", value: url)
    }

    private func paneBinding(_ pane: EditorPane) -> Binding<Bool> {
        Binding(
            get: { vm.isPaneVisible(pane) },
            set: { _ in vm.togglePane(pane) }
        )
    }

    /// Default visibility heuristic: keep PDF off when there's no
    /// source PDF attached (the empty placeholder is unhelpful in
    /// that case), keep it on once a PDF is attached. The user can
    /// override via the toolbar — `@SceneStorage` then remembers it.
    private func reconcilePaneDefaults() {
        if vm.sourcePDFURL == nil && showPDF {
            // Don't waste pane space on the empty-state placeholder
            // unless the user explicitly toggled PDF on.
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
        DispatchQueue.main.async { v.window?.isDocumentEdited = isDirty }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.isDocumentEdited = isDirty }
    }
}
