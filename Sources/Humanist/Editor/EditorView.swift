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
    @AppStorage(EditorSettingsKeys.wysiwygFontFamily)
    private var wysiwygFontFamily: String = EditorSettingsDefaults.wysiwygFontFamily
    @AppStorage(EditorSettingsKeys.wysiwygFontSize)
    private var wysiwygFontSize: Double = EditorSettingsDefaults.wysiwygFontSize
    @AppStorage(EditorSettingsKeys.wysiwygTheme)
    private var wysiwygTheme: String = EditorSettingsDefaults.wysiwygTheme

    init(epubURL: URL) {
        self.epubURL = epubURL
        _vm = StateObject(wrappedValue: EditorViewModel(epubURL: epubURL))
    }

    private var showPDF:     Bool { vm.showPDFPane }
    private var showSource:  Bool { vm.showSourcePane }
    private var showWYSIWYG: Bool { vm.showWYSIWYGPane }
    private var showPreview: Bool { vm.showPreviewPane }
    private var showChat:    Bool { vm.showChatPane }
    // wysiwygCommand moved onto EditorViewModel so the menu-bar
    // Format commands (routed via EditorCommandRouter) can reach
    // it. EditorView and the toolbar bind through `$vm.wysiwygCommand`.

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
                    .background(
                        WindowSaveGuard(
                            isDirty: vm.isDirty,
                            bookTitle: book.displayTitle,
                            onSave: { await vm.save() }
                        )
                    )
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
                        get: { vm.bulkReOCR.confirmation },
                        set: { vm.bulkReOCR.confirmation = $0 }
                    )) { confirmation in
                        BulkReOCRConfirmationSheet(
                            confirmation: confirmation,
                            onConfirm: {
                                vm.bulkReOCR.run(engine: confirmation.engine)
                            },
                            onCancel: { vm.bulkReOCR.cancelConfirmation() }
                        )
                    }
                    .sheet(item: Binding(
                        get: { vm.bulkReOCR.progress },
                        set: { vm.bulkReOCR.progress = $0 }
                    )) { progress in
                        BulkReOCRProgressSheet(
                            progress: progress,
                            onCancel: { vm.bulkReOCR.cancel() },
                            onDone: { vm.bulkReOCR.dismissProgress() }
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
                    .sheet(isPresented: $vm.showFootnoteManager) {
                        FootnoteManagerSheet(vm: vm)
                    }
                    .sheet(isPresented: $vm.showChapterManager) {
                        ChapterManagerSheet(vm: vm)
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
    /// via @ViewBuilder; we exploit that so adding panes doesn't
    /// blow up the case matrix.
    @ViewBuilder
    private func editorPanes(workingDir: URL) -> some View {
        let visibleCount = [showPDF, showSource, showWYSIWYG, showPreview, showChat]
            .filter { $0 }.count
        if visibleCount == 0 {
            allPanesHiddenState
        } else if visibleCount == 1 {
            singlePane(workingDir: workingDir)
        } else {
            // "First visible" pane: no leading accent and hosts the
            // PaneEqualizerBridge that walks up to the NSSplitView.
            let firstVisible: EditorPane = showPDF ? .pdf
                : showSource ? .source
                : showWYSIWYG ? .wysiwyg
                : showPreview ? .preview
                : .chat
            let minWidth: CGFloat = visibleCount >= 3 ? 220 : 280
            HSplitView {
                if showPDF {
                    pdfPane
                        .frame(minWidth: minWidth)
                        .paneDecorations(
                            isFirst: firstVisible == .pdf,
                            equalizeSignal: vm.equalizePanesSignal,
                            onEqualize: { vm.equalizePanes() }
                        )
                }
                if showSource {
                    sourcePane
                        .frame(minWidth: minWidth)
                        .paneDecorations(
                            isFirst: firstVisible == .source,
                            equalizeSignal: vm.equalizePanesSignal,
                            onEqualize: { vm.equalizePanes() }
                        )
                }
                if showWYSIWYG {
                    wysiwygPane
                        .frame(minWidth: minWidth)
                        .paneDecorations(
                            isFirst: firstVisible == .wysiwyg,
                            equalizeSignal: vm.equalizePanesSignal,
                            onEqualize: { vm.equalizePanes() }
                        )
                }
                if showPreview {
                    previewPane(workingDir: workingDir)
                        .frame(minWidth: minWidth)
                        .paneDecorations(
                            isFirst: firstVisible == .preview,
                            equalizeSignal: vm.equalizePanesSignal,
                            onEqualize: { vm.equalizePanes() }
                        )
                }
                if showChat {
                    chatPane
                        .frame(minWidth: minWidth)
                        .paneDecorations(
                            isFirst: firstVisible == .chat,
                            equalizeSignal: vm.equalizePanesSignal,
                            onEqualize: { vm.equalizePanes() }
                        )
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
        else if showChat { chatPane }
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
            .accessibilityLabel("Previous Page")

            Button {
                vm.pdfNextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("Next Page (⇧⌘→)")
            .accessibilityLabel("Next Page")

            Divider().frame(height: 12).padding(.horizontal, 4)

            Button {
                vm.pdfZoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom Out (⌘−)")
            .accessibilityLabel("Zoom Out")

            Button {
                vm.pdfZoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom In (⌘=)")
            .accessibilityLabel("Zoom In")

            Button {
                vm.pdfFitPage()
            } label: {
                Image(systemName: "rectangle.arrowtriangle.2.inward")
            }
            .help("Fit Page (⌘0)")
            .accessibilityLabel("Fit Page")
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
    private var chatPane: some View {
        VStack(spacing: 0) {
            paneHeader("Chat", systemImage: "bubble.left.and.text.bubble.right") {
                if let chat = vm.chatViewModel {
                    Button {
                        chat.rebuildIndex()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Rebuild this book's chat indexes from scratch")
                    .accessibilityLabel("Rebuild chat indexes")
                    if !chat.messages.isEmpty {
                        Button {
                            chat.clear()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Clear this chat (deletes the persisted transcript)")
                        .accessibilityLabel("Clear chat transcript")
                    }
                }
            }
            if let chat = vm.chatViewModel {
                ChatPaneView(
                    vm: chat,
                    onCitationTap: { citation in
                        // Library-scope citations carry a source
                        // book URL — open it in a new editor window
                        // (or activate one already open). Per-book
                        // citations stay in this window. When the
                        // citation specifies a paragraph index,
                        // scroll the editor to that paragraph
                        // rather than just selecting the chapter.
                        if let bookURL = citation.bookEpubURL {
                            OpenRouter.open(bookURL, openWindow: openWindow)
                        } else if let paraIdx = citation.paragraphIndex {
                            vm.requestParagraphScroll(
                                resourceID: citation.resourceID,
                                paragraphIdx: paraIdx
                            )
                        } else {
                            selectChapter(byResourceID: citation.resourceID)
                        }
                    }
                )
            } else {
                VStack(spacing: 8) {
                    Text("Loading chat…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Resolve a citation's manifest id to the matching FileNode
    /// in the sidebar and select it. The citation pane uses
    /// resource IDs (stable across saves) rather than file URLs
    /// (which would shift if Humanist ever renamed chapter files).
    private func selectChapter(byResourceID resourceID: String) {
        guard let book = vm.book,
              let resource = book.resourcesByID[resourceID]
        else { return }
        let url = book.absoluteURL(for: resource)
        guard let tree = vm.fileTree,
              let node = Self.findNode(in: tree, matching: url)
        else { return }
        vm.select(node)
    }

    /// Recursive depth-first search for a leaf FileNode whose URL
    /// matches `target` after canonicalization. Mirrors the
    /// EditorViewModel's internal helpers without exposing them.
    private static func findNode(in node: FileNode, matching target: URL) -> FileNode? {
        let want = target.canonicalForFile.standardizedFileURL.path
        if node.children == nil {
            let have = node.id.canonicalForFile.standardizedFileURL.path
            return have == want ? node : nil
        }
        for child in node.children ?? [] {
            if let hit = findNode(in: child, matching: target) {
                return hit
            }
        }
        return nil
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
                WYSIWYGFormattingToolbar(commandRequest: $vm.wysiwygCommand)
                WYSIWYGView(
                    xhtml: $vm.sourceText,
                    resetID: AnyHashable(file.id),
                    cssURL: vm.bookCSSURL,
                    commandRequest: $vm.wysiwygCommand,
                    reloadAfterSaveToken: vm.wysiwygReloadToken,
                    appearance: WYSIWYGAppearance(
                        fontFamily: EditorFontFamily(rawValue: wysiwygFontFamily) ?? .serif,
                        fontSize: wysiwygFontSize,
                        theme: EditorThemeMode(rawValue: wysiwygTheme) ?? .system
                    ),
                    scrollRequest: vm.scrollWYSIWYGToAnchor,
                    onAnchorVisible: { id in vm.didReportWYSIWYGAnchor(id) },
                    onParagraphVisible: { id in vm.didReportWYSIWYGParagraph(id) },
                    onFocusChange: { focused in vm.wysiwygHasFocus = focused }
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
            // shortcut, and toolbar stay in lockstep. `.navigation`
            // placement renders icon-only on macOS 26 (intentional
            // — leading-edge view-toggle convention, per MACUX.md).
            // `Label` carries the visible-text name AND the
            // accessibility label for VoiceOver in one go.
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

            Toggle(isOn: paneBinding(.chat)) {
                Label("Show Chat", systemImage: "bubble.left.and.text.bubble.right")
            }
            .help("Toggle the chat-with-book pane (⌘5)")
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

// MARK: - Pane decoration helpers

private extension View {
    /// Apply the two pane decorations:
    ///  1. A 2 pt leading accent line that makes the NSSplitView
    ///     divider visually thicker (non-first panes only).
    ///  2. A hidden PaneEqualizerBridge that walks up to the
    ///     NSSplitView and equalizes pane widths when signalled
    ///     (first pane only, so there's exactly one bridge per split).
    func paneDecorations(
        isFirst: Bool,
        equalizeSignal: Int,
        onEqualize: @escaping () -> Void
    ) -> some View {
        self
            .overlay(alignment: .leading) {
                if !isFirst {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.8))
                        .frame(width: 2)
                        .allowsHitTesting(false)
                }
            }
            .background {
                if isFirst {
                    PaneEqualizerBridge(equalizeSignal: equalizeSignal)
                }
            }
            .contextMenu {
                Button("Equalize Panes") { onEqualize() }
            }
    }
}

/// Hidden NSViewRepresentable placed in the first visible pane's
/// background. When `equalizeSignal` changes it finds the enclosing
/// NSSplitView and distributes all subview widths equally.
private struct PaneEqualizerBridge: NSViewRepresentable {
    let equalizeSignal: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.frame = .zero
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        guard equalizeSignal != coord.lastSignal else { return }
        coord.lastSignal = equalizeSignal
        // Defer so the view hierarchy is fully laid out before we
        // read its frame dimensions.
        DispatchQueue.main.async {
            guard let splitView = Self.enclosingSplitView(of: nsView) else { return }
            Self.equalize(splitView)
        }
    }

    /// Walk up the AppKit hierarchy to find the first NSSplitView
    /// ancestor. Because the PaneEqualizerBridge lives inside a pane
    /// that is a direct NSHostingView child of the HSplitView's
    /// NSSplitView, this returns the content NSSplitView, not the
    /// outer NavigationSplitView.
    private static func enclosingSplitView(of view: NSView) -> NSSplitView? {
        var current: NSView? = view.superview
        while let v = current {
            if let sv = v as? NSSplitView { return sv }
            current = v.superview
        }
        return nil
    }

    private static func equalize(_ sv: NSSplitView) {
        // SwiftUI marks toggled-off panes as isHidden rather than
        // removing them from the subviews array, so count only the
        // visible ones and place dividers between those.
        let visible = sv.subviews.filter { !$0.isHidden }
        let n = visible.count
        guard n > 1 else { return }
        let total = sv.bounds.width - sv.dividerThickness * CGFloat(n - 1)
        let each = total / CGFloat(n)
        var dividerIndex = 0
        for i in 0..<(sv.subviews.count - 1) {
            guard !sv.subviews[i].isHidden else { continue }
            let pos = each * CGFloat(dividerIndex + 1) + sv.dividerThickness * CGFloat(dividerIndex)
            sv.setPosition(pos, ofDividerAt: i)
            dividerIndex += 1
        }
    }

    final class Coordinator {
        var lastSignal: Int = -1
    }
}

/// Sets `isDocumentEdited` on the hosting window (shows the dot in
/// the red close button) and intercepts window-close when there are
/// unsaved changes. Prompts: Save / Discard / Cancel.
private struct WindowSaveGuard: NSViewRepresentable {
    let isDirty: Bool
    let bookTitle: String
    let onSave: () async -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> _SaveGuardNSView {
        let v = _SaveGuardNSView()
        v.onWindowAttached = { window in
            context.coordinator.attach(to: window)
        }
        return v
    }

    func updateNSView(_ nsView: _SaveGuardNSView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async {
            nsView.window?.isDocumentEdited = self.isDirty
            if let window = nsView.window {
                context.coordinator.attach(to: window)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var parent: WindowSaveGuard
        private weak var attachedWindow: NSWindow?
        /// SwiftUI's own delegate (if any) — stored before we install
        /// ourselves so we can forward every message we don't handle.
        /// This is important: SwiftUI uses the window delegate for
        /// @SceneStorage writes (including the editor URL). Replacing it
        /// without forwarding breaks scene-storage persistence, causing
        /// the editor to reopen with a nil URL on the next launch.
        private weak var originalDelegate: (any NSWindowDelegate)?
        /// Set before programmatically closing so `windowShouldClose`
        /// doesn't show the alert a second time.
        private var closingProgrammatically = false

        init(parent: WindowSaveGuard) { self.parent = parent }

        func attach(to window: NSWindow) {
            guard attachedWindow !== window else { return }
            attachedWindow = window
            originalDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard parent.isDirty && !closingProgrammatically else {
                return originalDelegate?.windowShouldClose?(sender) ?? true
            }

            let alert = NSAlert()
            alert.messageText = "Save \u{201C}\(parent.bookTitle)\u{201D} before closing?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard Changes")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            switch alert.runModal() {
            case .alertFirstButtonReturn: // Save → async save then close
                Task { @MainActor [weak self, weak sender] in
                    guard let self, let sender else { return }
                    await self.parent.onSave()
                    self.closingProgrammatically = true
                    sender.close()
                }
                return false
            case .alertSecondButtonReturn: // Discard → close immediately
                return originalDelegate?.windowShouldClose?(sender) ?? true
            default: // Cancel
                return false
            }
        }

        // Forward every other NSWindowDelegate message to SwiftUI's
        // original delegate so scene storage, full-screen transitions,
        // and key-window tracking all keep working normally.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector)
                || (originalDelegate?.responds(to: aSelector) == true)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if originalDelegate?.responds(to: aSelector) == true {
                return originalDelegate
            }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

/// NSView subclass that calls back when it moves into a window.
/// Needed because at `makeNSView` time the view isn't yet in a
/// window — `viewDidMoveToWindow` fires after insertion.
final class _SaveGuardNSView: NSView {
    var onWindowAttached: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindowAttached?(window) }
    }
}
