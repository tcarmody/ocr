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
    private var showWYSIWYG: Bool { vm.showWYSIWYGPane }
    private var showPreview: Bool { vm.showPreviewPane }
    @State private var wysiwygCommand: WYSIWYGCommand?

    var body: some View {
        Group {
            switch vm.state {
            case .loading:
                ProgressView("Opening \(epubURL.lastPathComponent)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                failureView(message)
            case .ready:
                if let book = vm.book, let tree = vm.fileTree {
                    NavigationSplitView {
                        BookBrowser(
                            root: tree,
                            selection: Binding(
                                get: { vm.selectedFile },
                                set: { if let n = $0 { vm.select(n) } }
                            ),
                            viewModel: vm
                        )
                        .frame(minWidth: 220)
                    } detail: {
                        editorPanes(workingDir: book.workingDirectory)
                            .onAppear { reconcilePaneDefaults() }
                            .onChange(of: vm.sourcePDFURL) { _, _ in reconcilePaneDefaults() }
                    }
                    .navigationTitle(book.displayTitle)
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
                        get: { vm.bulkReOCRConfirmation },
                        set: { vm.bulkReOCRConfirmation = $0 }
                    )) { confirmation in
                        BulkReOCRConfirmationSheet(
                            confirmation: confirmation,
                            onConfirm: {
                                vm.runBulkReOCR(engine: confirmation.engine)
                            },
                            onCancel: { vm.cancelBulkReOCRConfirmation() }
                        )
                    }
                    .sheet(item: Binding(
                        get: { vm.bulkReOCRProgress },
                        set: { vm.bulkReOCRProgress = $0 }
                    )) { progress in
                        BulkReOCRProgressSheet(
                            progress: progress,
                            onCancel: { vm.cancelBulkReOCR() },
                            onDone: { vm.dismissBulkReOCRProgress() }
                        )
                    }
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
                    // Phase 5a: Insert > Special Character picker
                    // sheet. Driven by the EditorViewModel flag the
                    // command router flips on.
                    .sheet(isPresented: $vm.showSpecialCharacterPicker) {
                        SpecialCharacterPicker(
                            isPresented: $vm.showSpecialCharacterPicker,
                            onPick: { ch in vm.formatInsert(ch) }
                        )
                    }
                    // Phase 5a: Edit > Go to Line… sheet.
                    .sheet(isPresented: $vm.showGotoLineSheet) {
                        GotoLineSheet(
                            isPresented: $vm.showGotoLineSheet,
                            onSubmit: { line in vm.gotoLine(line) }
                        )
                    }
                    // Phase 5b: Search > Find in Files… sheet.
                    .sheet(isPresented: $vm.showFindInFilesSheet) {
                        FindInFilesSheet(
                            vm: vm,
                            isPresented: $vm.showFindInFilesSheet
                        )
                    }
                    // Phase 5b: Tools > Validate EPUB sheet.
                    .sheet(isPresented: $vm.showValidationSheet) {
                        EPUBValidationSheet(
                            vm: vm,
                            isPresented: $vm.showValidationSheet
                        )
                    }
                    // R-Custom-Styles: Tools > Customize Style sheet.
                    .sheet(isPresented: $vm.showStyleSheet) {
                        BookStyleSheet(
                            vm: vm,
                            isPresented: $vm.showStyleSheet
                        )
                    }
                    // Phase 5b: chapter-operation failures (split,
                    // merge, regen TOC) surface here so the user sees
                    // what went wrong without digging through logs.
                    .alert(
                        "Chapter operation failed",
                        isPresented: Binding(
                            get: { vm.chapterOperationError != nil },
                            set: { presented in
                                if !presented { vm.chapterOperationError = nil }
                            }
                        ),
                        actions: { Button("OK", role: .cancel) {} },
                        message: {
                            if let msg = vm.chapterOperationError {
                                Text(msg)
                            }
                        }
                    )
                    // Rename Chapter prompt. The view-model owns the
                    // pending rename's state (URL + original name +
                    // typed buffer); SwiftUI's `.alert(item:)` opens
                    // when non-nil and binds the TextField via the
                    // unwrapped pending value.
                    .alert(
                        "Rename Chapter",
                        isPresented: Binding(
                            get: { vm.pendingRename != nil },
                            set: { presented in
                                if !presented { vm.cancelRenameChapter() }
                            }
                        ),
                        actions: {
                            if vm.pendingRename != nil {
                                TextField(
                                    "New name",
                                    text: Binding(
                                        get: { vm.pendingRename?.newBaseName ?? "" },
                                        set: { vm.pendingRename?.newBaseName = $0 }
                                    )
                                )
                                Button("Rename") { vm.commitRenameChapter() }
                                Button("Cancel", role: .cancel) {
                                    vm.cancelRenameChapter()
                                }
                            }
                        },
                        message: {
                            if let pending = vm.pendingRename {
                                Text("Rename “\(pending.originalStem).\(pending.extensionOnly)” to a new filename. Internal links will be updated automatically.")
                            }
                        }
                    )
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

    /// Build the pane layout from the current visibility flags.
    /// HSplitView accepts up to 10 conditionally-included children
    /// via @ViewBuilder; we exploit that so adding a 4th pane
    /// doesn't blow up the case matrix.
    @ViewBuilder
    private func editorPanes(workingDir: URL) -> some View {
        let visibleCount = [showPDF, showSource, showWYSIWYG, showPreview]
            .filter { $0 }.count
        if visibleCount == 0 {
            allPanesHiddenState
        } else if visibleCount == 1 {
            singlePane(workingDir: workingDir)
        } else {
            let minWidth: CGFloat = visibleCount >= 3 ? 220 : 280
            HSplitView {
                if showPDF {
                    pdfPane.frame(minWidth: minWidth)
                }
                if showSource {
                    sourcePane.frame(minWidth: minWidth)
                }
                if showWYSIWYG {
                    wysiwygPane.frame(minWidth: minWidth)
                }
                if showPreview {
                    previewPane(workingDir: workingDir).frame(minWidth: minWidth)
                }
            }
        }
    }

    @ViewBuilder
    private func singlePane(workingDir: URL) -> some View {
        if showPDF { pdfPane }
        else if showSource { sourcePane }
        else if showWYSIWYG { wysiwygPane }
        else if showPreview { previewPane(workingDir: workingDir) }
    }

    @ViewBuilder
    private var pdfPane: some View {
        if let controller = vm.pdfController {
            VStack(spacing: 0) {
                paneHeader("Original", systemImage: "doc.richtext.fill") {
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
                Text("No original document attached").foregroundStyle(.secondary)
                Button("Attach Original…") { attachSourcePDF() }
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

    @ViewBuilder
    private var wysiwygPane: some View {
        VStack(spacing: 0) {
            paneHeader("WYSIWYG", systemImage: "text.alignleft")
            if let file = vm.selectedFile,
               vm.canEditSelectedFile,
               file.id.pathExtension.lowercased().hasPrefix("xhtml")
                || file.id.pathExtension.lowercased() == "html"
                || file.id.pathExtension.lowercased() == "htm" {
                WYSIWYGFormattingToolbar(commandRequest: $wysiwygCommand)
                WYSIWYGView(
                    xhtml: $vm.sourceText,
                    resetID: AnyHashable(file.id),
                    cssURL: vm.bookCSSURL,
                    commandRequest: $wysiwygCommand
                )
            } else if vm.selectedFile != nil {
                VStack {
                    Text("WYSIWYG editing applies only to chapter XHTML.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    Text("Select a chapter to edit visually.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
                onCursorAnchorChanged: { id in vm.didMoveCursorToAnchor(id) },
                onCursorOffsetChanged: { offset in vm.didMoveCursor(offset: offset) },
                onCursorParagraphChanged: { id in vm.didMoveCursorToParagraph(id) }
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
                onAnchorVisible: { id in vm.didReportPreviewAnchor(id) },
                onParagraphVisible: { id in vm.didReportPreviewParagraph(id) }
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

            Toggle(isOn: paneBinding(.wysiwyg)) {
                Label("Show WYSIWYG", systemImage: "text.alignleft")
            }
            .help("Toggle the WYSIWYG editor pane (⌘4)")
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
                    Button("Attach Original…") { attachSourcePDF() }
                } else {
                    Button("Change Original…") { attachSourcePDF() }
                    Button("Show Original in New Window") { openSourcePDFWindow() }
                    Divider()
                    Button("Detach Original", role: .destructive) {
                        vm.detachSourcePDF()
                    }
                }
            } label: {
                Label(
                    vm.sourcePDFURL?.lastPathComponent ?? "Original",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            .help("Manage the original document associated with this EPUB")
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
        openWindow(id: "source-viewer", value: url)
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
