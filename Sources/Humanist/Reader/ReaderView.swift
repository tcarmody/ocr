import SwiftUI
import AppKit
import WebKit
import EPUB

/// R-Reader. Standalone EPUB reading window. NavigationSplitView
/// with a stub TOC sidebar + a single-column scrolling chapter
/// pane backed by WKWebView. Commit 1 ships the skeleton; later
/// commits in the phase wire real TOC titles, default-open
/// routing, and reading-position persistence.
struct ReaderView: View {
    /// Bounds for the reader's font-size stepper. Local to the
    /// reader for now; the editor's preview has its own picker
    /// without bounds so we don't share constants.
    static let fontSizeMin: Double = 10
    static let fontSizeMax: Double = 36

    let epubURL: URL

    @StateObject private var vm: ReaderViewModel
    @Environment(\.openWindow) private var openWindow
    /// Font-size preference for the chapter pane. Shared with the
    /// editor's preview pane keys so adjustments in either surface
    /// stay consistent. Persisted via @AppStorage.
    @AppStorage(EditorSettingsKeys.previewFontSize)
    private var fontSize: Double = EditorSettingsDefaults.previewFontSize

    /// TOC sidebar visibility. Persisted across reader window
    /// opens — a user who closes the TOC sidebar for a focused-
    /// reading session expects it to stay closed on the next
    /// open. `NavigationSplitView` maps the Bool to its native
    /// `.all` / `.detailOnly` visibility states.
    @AppStorage("humanist.reader.sidebarVisible")
    private var sidebarVisible: Bool = true

    // MARK: - Find state

    /// Find bar visibility — ⌘F toggles, Esc dismisses.
    @State private var showingFind: Bool = false
    /// Current search query — bound to the find bar's TextField.
    /// Each non-empty value mints a new FindRequest with
    /// direction=forward so the WKWebView searches as the user
    /// types.
    @State private var findQuery: String = ""
    /// Outbound find request. Bumped (new nonce) on user-driven
    /// search events: query change (forward from current),
    /// Find Next (⌘G), Find Previous (⇧⌘G).
    @State private var findRequest: FindRequest?
    /// Last find result — drives the small status label
    /// ("Match found." / "No match.") in the find bar.
    @State private var findResultMessage: String = ""

    /// Copy-with-citation request. Bumped (new UUID) when the
    /// user invokes ⇧⌘C / the toolbar button; the WKWebView's
    /// coordinator catches the change, computes the selection
    /// + nearest paragraph anchor, builds the citation string,
    /// and writes it to the system clipboard.
    @State private var copyCitationRequest: UUID?
    /// Transient banner shown after a copy-with-citation: "Copied
    /// with citation." or "Select some text first." Cleared after
    /// a couple of seconds.
    @State private var copyCitationToast: String?

    /// Bookmark-here request nonce. Bumped (new UUID) on the
    /// gesture; coordinator captures the nearest visible anchor
    /// and posts back so the VM can append the bookmark.
    @State private var bookmarkRequest: UUID?

    /// Highlight-selection request. Carries a pre-minted
    /// annotation id so the wrap span and the persisted
    /// Annotation share an id; coordinator wraps the selection
    /// then reports back the text + anchor + offsets for
    /// Swift-side persistence.
    @State private var highlightRequest: WebReaderPane.HighlightRequest?

    /// Annotation currently being edited in the note sheet.
    /// nil → sheet hidden. Wraps the id rather than the
    /// Annotation itself so the in-memory list is always the
    /// source of truth while editing — saving mutates that
    /// list directly via the VM.
    @State private var editingAnnotationId: UUID?

    /// One-shot flag: when true, the next successful highlight
    /// capture opens the note editor for the just-created
    /// annotation. Set by the right-click "Add Note…" menu
    /// action and consumed in `handleHighlightCaptured`.
    /// Lets the user go from selection → highlight + note in
    /// one gesture instead of right-click-highlight then right-
    /// click-the-sidebar-row-add-note.
    @State private var openNoteEditorAfterNextHighlight: Bool = false

    /// Reading-prefs popover visibility.
    @State private var showingReadingPrefs: Bool = false

    // Reading preferences — persisted globally so a user's
    // typographic preference travels across books / windows.
    @AppStorage("humanist.reader.fontFamily")
    private var fontFamily: ReaderFontFamily = .serif
    @AppStorage("humanist.reader.lineHeight")
    private var lineHeight: Double = 1.5
    @AppStorage("humanist.reader.marginEm")
    private var marginEm: Double = 2.0
    @AppStorage("humanist.reader.theme")
    private var theme: ReaderTheme = .system

    /// In-flight passage-attribute update for the wrap span.
    /// Bumped (new request) when a note save promotes a
    /// highlight to a passage (or demotes the other way);
    /// coordinator runs JS to stamp / strip the data-passage
    /// attribute so the visual underline appears immediately
    /// without a chapter reload.
    @State private var passageMarkerRequest: PassageMarkerRequest?

    struct PassageMarkerRequest: Equatable {
        let annotationId: UUID
        let isPassage: Bool
        let nonce: UUID
    }

    /// Sidebar tab. Persisted so a user who lives in the
    /// annotations list during a read stays there on reopen.
    @AppStorage("humanist.reader.sidebarTab")
    private var sidebarTab: SidebarTab = .toc

    enum SidebarTab: String, CaseIterable {
        case toc, annotations
        var label: String {
            switch self {
            case .toc:         return "Contents"
            case .annotations: return "Marks"
            }
        }
        var systemImage: String {
            switch self {
            case .toc:         return "list.bullet"
            case .annotations: return "bookmark"
            }
        }
    }

    init(epubURL: URL) {
        self.epubURL = epubURL
        _vm = StateObject(wrappedValue: ReaderViewModel(epubURL: epubURL))
    }

    var body: some View {
        Group {
            switch vm.state {
            case .loading:
                ProgressView("Opening \(epubURL.lastPathComponent)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                failureView(message)
            case .ready:
                if let book = vm.book {
                    readyBody(book: book)
                } else {
                    failureView("Reader is ready but no book was loaded.")
                }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .humanistChrome()
        .overlay(alignment: .bottom) {
            if let toast = copyCitationToast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: copyCitationToast)
        .sheet(isPresented: Binding(
            get: { editingAnnotationId != nil },
            set: { presented in
                if !presented { editingAnnotationId = nil }
            }
        )) {
            if let id = editingAnnotationId,
               let annot = vm.annotations.first(where: { $0.id == id }) {
                NoteEditorSheet(
                    annotation: annot,
                    onSave: { newNote in
                        saveNote(forAnnotationID: id, note: newNote)
                        editingAnnotationId = nil
                    },
                    onCancel: { editingAnnotationId = nil }
                )
            }
        }
    }

    /// Persist a note edit and trigger the visual passage-
    /// marker update on the wrap span. Promotion / demotion
    /// between highlight ↔ passage happens inside
    /// `vm.updateAnnotationNote`; we just need to look at the
    /// updated kind to decide whether the wrap should carry
    /// the data-passage attribute.
    private func saveNote(forAnnotationID id: UUID, note: String?) {
        vm.updateAnnotationNote(id: id, note: note)
        guard let updated = vm.annotations.first(where: { $0.id == id })
        else { return }
        // Bookmarks don't have a wrap span — visual update only
        // applies to highlight / passage kinds.
        guard updated.kind == .highlight || updated.kind == .passage
        else { return }
        passageMarkerRequest = PassageMarkerRequest(
            annotationId: id,
            isPassage: updated.kind == .passage,
            nonce: UUID()
        )
    }

    // MARK: - Ready body

    @ViewBuilder
    private func readyBody(book: EPUBBook) -> some View {
        NavigationSplitView(
            columnVisibility: Binding(
                get: { sidebarVisible ? .all : .detailOnly },
                set: { newValue in
                    // .all and .doubleColumn both count as visible
                    // (the latter is what AppKit emits when the
                    // user un-collapses a hidden sidebar); only
                    // .detailOnly means the user actively hid it.
                    sidebarVisible = newValue != .detailOnly
                }
            )
        ) {
            sidebarColumn(book: book)
                .frame(minWidth: 220, idealWidth: 260)
        } detail: {
            detailPane(book: book)
        }
        .navigationTitle(vm.displayTitle)
        .navigationSubtitle(vm.currentChapterLabel)
        .toolbar { toolbarContent }
    }

    /// Detail column. Always shows the reading pane; adds the
    /// chat pane on the right when `vm.showChatPane` is on. Uses
    /// HSplitView so the user can drag the divider — matches the
    /// editor's pane behavior.
    @ViewBuilder
    private func detailPane(book: EPUBBook) -> some View {
        if vm.showChatPane, let chatVM = vm.chatViewModel {
            HSplitView {
                readingPane(book: book)
                    .frame(minWidth: 360)
                ReaderChatPaneView(
                    vm: chatVM,
                    onCitationTap: { citation in
                        // Tap a citation chip → snap the reading
                        // pane to the cited chapter. Library-scope
                        // citations (which carry a bookEpubURL)
                        // can't appear in reader chat because
                        // scope is locked to .currentBook on the
                        // VM, but defend anyway: only navigate
                        // when the citation targets this book.
                        guard citation.bookEpubURL == nil else { return }
                        if let paraIdx = citation.paragraphIndex {
                            vm.jumpToParagraph(
                                chapterIdx: citation.chapterIndex,
                                paragraphIdx: paraIdx
                            )
                        } else {
                            vm.jump(toSpineIndex: citation.chapterIndex)
                        }
                    }
                )
                .frame(minWidth: 320, idealWidth: 380)
            }
        } else {
            readingPane(book: book)
        }
    }

    /// Sidebar column = tab picker (Contents / Marks) + the
    /// appropriate list below. Picker state persists via
    /// @AppStorage so a user who lives in the annotations list
    /// stays there on reopen.
    @ViewBuilder
    private func sidebarColumn(book: EPUBBook) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $sidebarTab) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Label(tab.label, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            switch sidebarTab {
            case .toc:
                tocSidebar(book: book)
            case .annotations:
                annotationsSidebar(book: book)
            }
        }
    }

    /// TOC sidebar. Titles come from `ReaderTOC.build` — preferring
    /// the EPUB's `nav.xhtml` when present, falling back to per-
    /// spine-item `<title>` / first heading / filename otherwise.
    /// Always-flat list for v1; sub-section hierarchy lands in v2
    /// of the reader.
    @ViewBuilder
    private func tocSidebar(book: EPUBBook) -> some View {
        let entries = vm.toc.entries
        List(selection: Binding(
            get: { vm.spineIndex },
            set: { if let new = $0 { vm.jump(toSpineIndex: new) } }
        )) {
            ForEach(entries) { entry in
                Text(entry.title)
                    .lineLimit(2)
                    .tag(Optional(entry.spineIndex))
            }
        }
        .listStyle(.sidebar)
    }

    /// Annotations list — bookmarks / highlights / passages
    /// across the whole book, sorted by spine order (then
    /// paragraph index, then capture date). Tap an entry to
    /// jump the reader to that paragraph; right-click for
    /// edit / delete.
    @ViewBuilder
    private func annotationsSidebar(book: EPUBBook) -> some View {
        if vm.annotations.isEmpty {
            VStack(alignment: .center, spacing: 8) {
                Image(systemName: "bookmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No marks yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Use ⌘D to bookmark a paragraph or select text and use the Highlight gesture (lands in Phase D).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(sortedAnnotations()) { annot in
                    annotationRow(annot)
                        .contextMenu {
                            Button("Jump to") { jumpToAnnotation(annot) }
                            Button(annot.note == nil ? "Add Note…" : "Edit Note…") {
                                editingAnnotationId = annot.id
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                vm.removeAnnotation(id: annot.id)
                            }
                        }
                        .onTapGesture {
                            jumpToAnnotation(annot)
                        }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// Single-row rendering for the annotations sidebar. Layout
    /// is icon + chapter title + (selected text excerpt or note
    /// preview when present). Bookmark = bookmark icon;
    /// Highlight = highlighter icon; Passage = note icon. Capped
    /// preview text length so a paragraph-long highlight doesn't
    /// stretch the row.
    @ViewBuilder
    private func annotationRow(_ annot: Annotation) -> some View {
        let chapterTitle = vm.toc.entries.first(
            where: { $0.spineIndex == annot.chapterIdx }
        )?.title ?? "Chapter \(annot.chapterIdx + 1)"
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: annotationIcon(annot.kind))
                .foregroundStyle(annotationTint(annot.kind))
                .imageScale(.small)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(chapterTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let text = annot.selectedText, !text.isEmpty {
                    Text("\u{201C}\(text.prefix(80))\u{201D}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let note = annot.note, !note.isEmpty {
                    Text(note.prefix(80))
                        .font(.caption.italic())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Stable ordering: by chapter index, then by paragraph
    /// number (parsed from `hu-p-N-M`), then by creation time.
    /// Matches a reader's natural "show me my marks in reading
    /// order" expectation.
    private func sortedAnnotations() -> [Annotation] {
        vm.annotations.sorted { a, b in
            if a.chapterIdx != b.chapterIdx {
                return a.chapterIdx < b.chapterIdx
            }
            let aP = paragraphIdx(from: a.paragraphAnchorId)
            let bP = paragraphIdx(from: b.paragraphAnchorId)
            if aP != bP { return aP < bP }
            return a.createdAt < b.createdAt
        }
    }

    /// Parse the paragraph index out of `hu-p-N-M`. Returns
    /// `Int.max` for nil / malformed anchors so they sort to
    /// the end within their chapter.
    private func paragraphIdx(from anchor: String?) -> Int {
        guard let anchor else { return Int.max }
        let parts = anchor.split(separator: "-")
        guard parts.count >= 4, let idx = Int(parts[3]) else {
            return Int.max
        }
        return idx
    }

    private func annotationIcon(_ kind: Annotation.Kind) -> String {
        switch kind {
        case .bookmark:  return "bookmark.fill"
        case .highlight: return "highlighter"
        case .passage:   return "text.bubble.fill"
        }
    }

    private func annotationTint(_ kind: Annotation.Kind) -> Color {
        switch kind {
        case .bookmark:  return .blue
        case .highlight: return .yellow
        case .passage:   return .orange
        }
    }

    /// Jump the reader to the annotation's anchor. Uses the
    /// paragraph anchor when present; falls back to chapter
    /// top.
    private func jumpToAnnotation(_ annot: Annotation) {
        if let anchor = annot.paragraphAnchorId,
           let paraIdx = parseParagraphIdx(from: anchor) {
            vm.jumpToParagraph(
                chapterIdx: annot.chapterIdx, paragraphIdx: paraIdx
            )
        } else {
            vm.jump(toSpineIndex: annot.chapterIdx)
        }
    }

    private func parseParagraphIdx(from anchor: String) -> Int? {
        let parts = anchor.split(separator: "-")
        guard parts.count >= 4 else { return nil }
        return Int(parts[3])
    }

    @ViewBuilder
    private func readingPane(book: EPUBBook) -> some View {
        if let chapterURL = vm.currentChapterURL {
            // Only pass the anchor / fraction through when it
            // targets the currently-loaded spine index — otherwise
            // the WKWebView would try to scroll the wrong chapter's
            // DOM. The VM updates spineIndex first, so by the time
            // updateNSView runs the target's spineIndex matches.
            let anchor: ReaderViewModel.ScrollAnchor? = {
                guard let a = vm.pendingScrollAnchor,
                      a.spineIndex == vm.spineIndex
                else { return nil }
                return a
            }()
            let fractionReq: ReaderViewModel.ScrollFractionRequest? = {
                guard let f = vm.pendingScrollFraction,
                      f.spineIndex == vm.spineIndex
                else { return nil }
                return f
            }()
            VStack(spacing: 0) {
                if vm.bookChangedOnDisk {
                    staleBanner
                    Divider()
                }
                if showingFind {
                    findBar
                    Divider()
                }
                WebReaderPane(
                    url: chapterURL,
                    accessRoot: book.workingDirectory,
                    reloadTrigger: vm.reloadTrigger,
                    fontSize: fontSize,
                    scrollAnchor: anchor,
                    scrollFraction: fractionReq,
                    onScrollUpdate: { fraction in
                        vm.didReportScrollFraction(fraction)
                    },
                    findRequest: findRequest,
                    onFindResult: { matchFound in
                        findResultMessage = matchFound
                            ? "Match found."
                            : "No match."
                    },
                    copyCitationRequest: copyCitationRequest,
                    onCitationContext: { ctx in
                        handleCitationContext(ctx)
                    },
                    bookmarkRequest: bookmarkRequest,
                    onBookmarkContext: { anchorId in
                        handleBookmarkRequest(anchorId)
                    },
                    highlightRequest: highlightRequest,
                    onHighlightCaptured: { capture in
                        handleHighlightCaptured(capture)
                    },
                    onContextHighlight: {
                        openNoteEditorAfterNextHighlight = false
                        highlightRequest = WebReaderPane.HighlightRequest(
                            annotationId: UUID(),
                            nonce: UUID()
                        )
                    },
                    onContextAddNote: {
                        openNoteEditorAfterNextHighlight = true
                        highlightRequest = WebReaderPane.HighlightRequest(
                            annotationId: UUID(),
                            nonce: UUID()
                        )
                    },
                    onContextCopyCitation: {
                        copyCitationRequest = UUID()
                    },
                    chapterHighlights: vm.annotations.filter {
                        $0.chapterIdx == vm.spineIndex
                            && ($0.kind == .highlight || $0.kind == .passage)
                    },
                    passageMarkerRequest: passageMarkerRequest,
                    isPaginated: vm.isPaginated,
                    pageNavRequest: vm.pageNavRequest,
                    onPaginationUpdate: { current, count in
                        vm.didReportPagination(
                            currentPage: current, pageCount: count
                        )
                    },
                    appearance: WebReaderPane.Appearance(
                        fontStack: fontFamily.cssStack,
                        lineHeight: lineHeight,
                        marginEm: marginEm,
                        themeName: theme.rawValue
                    )
                )
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "book.closed")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("This book has no readable chapters.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { vm.previousChapter() } label: {
                Label("Previous Chapter", systemImage: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!vm.canGoPrevious)

            Button { vm.nextChapter() } label: {
                Label("Next Chapter", systemImage: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!vm.canGoNext)

            // Paginated-mode-only controls: previous page,
            // page indicator, next page. ←/→ navigate within
            // a chapter; ⌘← / ⌘→ still cross chapter boundaries.
            if vm.isPaginated {
                Divider()
                Button { vm.previousPage() } label: {
                    Label("Previous Page",
                          systemImage: "arrowtriangle.left.fill")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                Text(pageIndicatorLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56)
                    .lineLimit(1)
                Button { vm.nextPage() } label: {
                    Label("Next Page",
                          systemImage: "arrowtriangle.right.fill")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                Button { vm.nextPage() } label: {
                    Label("Next Page (Space)", systemImage: "space")
                }
                .keyboardShortcut(.space, modifiers: [])
                .hidden()
                .frame(width: 0, height: 0)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 4) {
                Button {
                    fontSize = max(Self.fontSizeMin,
                                   fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("Decrease font size")
                .disabled(fontSize <= Self.fontSizeMin)

                Text("\(Int(fontSize))")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 22)

                Button {
                    fontSize = min(Self.fontSizeMax,
                                   fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("Increase font size")
                .disabled(fontSize >= Self.fontSizeMax)
            }

            Button {
                vm.showChatPane.toggle()
            } label: {
                Label(
                    "Chat",
                    systemImage: vm.showChatPane
                        ? "bubble.left.and.text.bubble.right.fill"
                        : "bubble.left.and.text.bubble.right"
                )
            }
            .help(vm.showChatPane
                  ? "Hide chat sidebar (⌥⌘C)"
                  : "Chat with this book (⌥⌘C)")
            .keyboardShortcut("c", modifiers: [.command, .option])

            Button {
                openWindow(id: "editor", value: epubURL)
            } label: {
                Label("Edit Source…", systemImage: "pencil")
            }
            .help("Open this book in the Editor (⌥⌘O)")
            .keyboardShortcut("o", modifiers: [.command, .option])

            Button {
                showingFind.toggle()
                if showingFind {
                    findResultMessage = ""
                } else {
                    // Clearing the request on dismiss prevents
                    // the next ⌘F open from re-running the stale
                    // query against the new chapter.
                    findRequest = nil
                    findQuery = ""
                }
            } label: {
                Label("Find in Chapter", systemImage: "magnifyingglass")
            }
            .help("Find in chapter (⌘F)")
            .keyboardShortcut("f", modifiers: .command)

            Button {
                copyCitationRequest = UUID()
            } label: {
                Label("Copy with Citation", systemImage: "quote.opening")
            }
            .help("Copy selection with a citation back to the book (⇧⌘C)")
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button {
                bookmarkRequest = UUID()
            } label: {
                Label("Bookmark", systemImage: "bookmark")
            }
            .help("Bookmark the current location (⌘D)")
            .keyboardShortcut("d", modifiers: .command)

            Button {
                highlightRequest = WebReaderPane.HighlightRequest(
                    annotationId: UUID(),
                    nonce: UUID()
                )
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }
            .help("Highlight the selected text (⌃⌘H)")
            .keyboardShortcut("h", modifiers: [.command, .control])

            Button {
                vm.isPaginated.toggle()
            } label: {
                Label(
                    vm.isPaginated ? "Scroll View" : "Page View",
                    systemImage: vm.isPaginated
                        ? "scroll"
                        : "rectangle.split.2x1"
                )
            }
            .help(vm.isPaginated
                  ? "Switch back to scrolling layout (⌥⌘P)"
                  : "Switch to paginated layout (⌥⌘P)")
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button {
                showingReadingPrefs.toggle()
            } label: {
                Label("Reading Preferences", systemImage: "textformat")
            }
            .help("Font, line spacing, margins, and theme (⌃⌘A)")
            .keyboardShortcut("a", modifiers: [.command, .control])
            .popover(
                isPresented: $showingReadingPrefs,
                arrowEdge: .bottom
            ) {
                readingPrefsPopover
            }
        }
    }

    /// Reading preferences popover. Each control writes to the
    /// matching @AppStorage; the WKWebView observes the values
    /// and live-updates CSS variables on the loaded chapter via
    /// the appearance JS bridge. No reload needed.
    @ViewBuilder
    private var readingPrefsPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reading Preferences")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Font").font(.callout.weight(.medium))
                Picker("Font", selection: $fontFamily) {
                    ForEach(ReaderFontFamily.allCases) { ff in
                        Text(ff.displayName).tag(ff)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Size").font(.callout.weight(.medium))
                    Spacer()
                    Text("\(Int(fontSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $fontSize,
                    in: Self.fontSizeMin...Self.fontSizeMax,
                    step: 1
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Line spacing").font(.callout.weight(.medium))
                    Spacer()
                    Text(String(format: "%.1f×", lineHeight))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $lineHeight, in: 1.2...2.2, step: 0.1)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Margins").font(.callout.weight(.medium))
                    Spacer()
                    Text(String(format: "%.1f em", marginEm))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $marginEm, in: 0...8, step: 0.5)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Theme").font(.callout.weight(.medium))
                Picker("Theme", selection: $theme) {
                    ForEach(ReaderTheme.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    /// "1 / 47" — visible only in paginated mode. Pre-measurement
    /// (chapter still loading) shows "—" so the slot stays a
    /// stable size and doesn't jitter as the indicator catches up.
    private var pageIndicatorLabel: String {
        guard vm.pageCount > 0 else { return "—" }
        return "\(vm.currentPage + 1) / \(vm.pageCount)"
    }

    /// Stale-on-disk banner. Appears above the chapter pane
    /// when the editor saves this book while the reader is
    /// open. Two actions: Reload (re-open the EPUB and refresh
    /// the reader VM) or Dismiss (keep the stale in-memory copy
    /// — useful when the user knows the edit was minor and
    /// they don't want to lose their place mid-paragraph).
    @ViewBuilder
    private var staleBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
            Text("Book changed on disk")
                .font(.callout.weight(.medium))
            Text("(saved from the Editor)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reload") {
                Task { await vm.reloadFromDisk() }
            }
            .controlSize(.small)
            Button {
                vm.bookChangedOnDisk = false
            } label: {
                Image(systemName: "xmark")
            }
            .help("Dismiss (keeps your current in-memory copy)")
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    /// Inline find bar shown above the chapter pane when
    /// `showingFind` is on. ⌘G / ⇧⌘G drive next / previous;
    /// Esc dismisses. WKWebView's native `find(_:configuration:
    /// completionHandler:)` API drives the actual search +
    /// highlighting.
    @ViewBuilder
    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField("Find in chapter", text: $findQuery)
                .textFieldStyle(.plain)
                .onSubmit { fireFind(direction: .forward) }
                .onChange(of: findQuery) { _, newValue in
                    // Live find as the user types. Empty query
                    // resets the result label.
                    if newValue.isEmpty {
                        findResultMessage = ""
                        findRequest = nil
                    } else {
                        fireFind(direction: .forward)
                    }
                }
                .frame(maxWidth: 280)

            if !findResultMessage.isEmpty {
                Text(findResultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button { fireFind(direction: .backward) } label: {
                Image(systemName: "chevron.up")
            }
            .help("Find previous (⇧⌘G)")
            .disabled(findQuery.isEmpty)
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Button { fireFind(direction: .forward) } label: {
                Image(systemName: "chevron.down")
            }
            .help("Find next (⌘G)")
            .disabled(findQuery.isEmpty)
            .keyboardShortcut("g", modifiers: .command)

            Button {
                showingFind = false
                findRequest = nil
                findQuery = ""
                findResultMessage = ""
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close (Esc)")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Mint a new FindRequest with the current query + direction.
    /// Bumps the nonce so the WKWebView re-fires even when the
    /// query text didn't change (consecutive ⌘G presses).
    private func fireFind(direction: FindRequest.Direction) {
        guard !findQuery.isEmpty else { return }
        findRequest = FindRequest(
            query: findQuery,
            direction: direction,
            nonce: UUID()
        )
    }

    /// Format the JS-side citation context as a clipboard
    /// payload + write it. nil context (nothing selected) shows
    /// a toast hint instead.
    private func handleCitationContext(
        _ ctx: WebReaderPane.CitationContext?
    ) {
        guard let ctx else {
            showCopyToast("Select some text first.")
            return
        }
        let citation = formatCitation(for: ctx)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(citation, forType: .string)
        showCopyToast("Copied with citation.")
    }

    /// Build the clipboard payload. Shape:
    ///
    ///   "<selected text>"
    ///   — <Book Title>, <Chapter Title>, ¶M
    ///
    /// Chapter title from the VM's `chapterTitle` lookup when
    /// available; falls back to the current spine label. Paragraph
    /// suffix only present when the source had an `hu-p-N-M`
    /// anchor (Humanist-converted EPUBs).
    private func formatCitation(
        for ctx: WebReaderPane.CitationContext
    ) -> String {
        // Cite the chapter the selection actually came from
        // (from the hu-p-N-M anchor) when present; fall back to
        // the currently-displayed chapter when the EPUB lacks
        // per-paragraph anchors.
        let chapterIdx = ctx.chapterIdx ?? vm.spineIndex
        let chapterTitle: String = {
            if let entry = vm.toc.entries.first(
                where: { $0.spineIndex == chapterIdx }
            ) {
                return entry.title
            }
            return "Chapter \(chapterIdx + 1)"
        }()
        let bookTitle = vm.displayTitle
        var citation = "— \(bookTitle), \(chapterTitle)"
        if let paragraphIdx = ctx.paragraphIdx {
            citation += ", ¶\(paragraphIdx)"
        }
        return "\"\(ctx.text)\"\n\(citation)"
    }

    /// Brief toast banner after a copy attempt. Auto-clears
    /// after 2 s.
    private func showCopyToast(_ message: String) {
        copyCitationToast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if copyCitationToast == message {
                    copyCitationToast = nil
                }
            }
        }
    }

    /// Handler for the ⌘D bookmark gesture. Builds a bookmark
    /// Annotation from the JS-reported topmost-visible anchor
    /// + the current spine index, persists it via the VM, and
    /// flashes a brief toast confirming the action. Degrades
    /// gracefully when no anchor is found (third-party EPUB)
    /// — the bookmark stores chapter-level only.
    private func handleBookmarkRequest(_ anchorId: String?) {
        vm.addBookmark(
            chapterIdx: vm.spineIndex,
            paragraphAnchorId: anchorId
        )
        showCopyToast(anchorId == nil
            ? "Bookmarked chapter."
            : "Bookmarked.")
    }

    /// Handler for the highlight gesture's JS callback.
    /// `capture == nil` means the user fired the gesture
    /// without selecting text; surface a hint. Otherwise build
    /// the Annotation with the pre-minted id (the JS-side wrap
    /// span already carries that id in its dataset for later
    /// delete-by-id flows) and persist via the VM.
    private func handleHighlightCaptured(
        _ capture: WebReaderPane.HighlightCapture?
    ) {
        guard let capture else {
            // Reset the deferred-editor flag — a failed "Add
            // Note…" still consumes its intent (no zombie state
            // for the next highlight to inherit).
            openNoteEditorAfterNextHighlight = false
            showCopyToast("Select some text first.")
            return
        }
        let range: Annotation.TextRange?
        if let s = capture.startOffset, let e = capture.endOffset,
           e > s {
            range = Annotation.TextRange(
                startOffset: s, endOffset: e
            )
        } else {
            range = nil
        }
        vm.addHighlight(
            id: capture.annotationId,
            chapterIdx: vm.spineIndex,
            paragraphAnchorId: capture.paragraphAnchorId,
            selectedText: capture.text,
            selectionRange: range
        )
        if openNoteEditorAfterNextHighlight {
            // Consume the flag and open the note sheet on the
            // freshly-minted annotation. Saving a non-empty
            // note will promote it from .highlight to .passage
            // via the existing vm.updateAnnotationNote path.
            openNoteEditorAfterNextHighlight = false
            editingAnnotationId = capture.annotationId
            showCopyToast("Highlighted — add a note.")
        } else {
            showCopyToast("Highlighted.")
        }
    }
}

/// One find request from the reader's find bar to the
/// WKWebView. Nonce-tagged so consecutive Next-or-Previous
/// presses on the same query each re-trigger the search.
struct FindRequest: Equatable {
    enum Direction { case forward, backward }
    let query: String
    let direction: Direction
    let nonce: UUID
}

/// Reader font-family picker. Each case maps to a font-stack
/// the WKWebView injects on the loaded chapter. Concrete fonts
/// chosen for typographic quality on long-form reading on
/// macOS; San Francisco is included for users who prefer the
/// system sans-serif.
enum ReaderFontFamily: String, CaseIterable, Identifiable, Sendable {
    case serif        // Iowan Old Style → Hoefler Text → Georgia
    case newYork      // New York (Apple's optical-size serif)
    case sansSerif    // San Francisco → Helvetica Neue
    case mono         // SF Mono → Menlo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .serif:     return "Serif"
        case .newYork:   return "New York"
        case .sansSerif: return "Sans-serif"
        case .mono:      return "Monospace"
        }
    }

    /// CSS font-stack injected on the chapter body. macOS-only
    /// — no fallback to web-safe fonts since the reader doesn't
    /// run anywhere else.
    var cssStack: String {
        switch self {
        case .serif:
            return "\"Iowan Old Style\", \"Hoefler Text\", Georgia, serif"
        case .newYork:
            return "\"New York\", \"Iowan Old Style\", Georgia, serif"
        case .sansSerif:
            return "-apple-system, \"Helvetica Neue\", Helvetica, sans-serif"
        case .mono:
            return "\"SF Mono\", Menlo, Monaco, monospace"
        }
    }
}

/// Reader theme. System tracks `prefers-color-scheme`; Sepia
/// + Dark are explicit overrides for users who want a fixed
/// reading palette independent of system appearance.
enum ReaderTheme: String, CaseIterable, Identifiable, Sendable {
    case system, sepia, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .sepia:  return "Sepia"
        case .dark:   return "Dark"
        }
    }
}

/// Modal note editor for a single annotation. Triggered from
/// the annotations-sidebar context menu ("Add Note…" /
/// "Edit Note…"). Shows the selected text as context (when
/// available — bookmarks have no selected text) and a
/// TextEditor for the note body. Cancel discards; Save writes
/// through the VM, which promotes the annotation's kind to
/// `.passage` when the note becomes non-empty (or demotes back
/// to `.highlight` when cleared).
private struct NoteEditorSheet: View {
    let annotation: Annotation
    let onSave: (String?) -> Void
    let onCancel: () -> Void
    @State private var noteText: String

    init(
        annotation: Annotation,
        onSave: @escaping (String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.annotation = annotation
        self.onSave = onSave
        self.onCancel = onCancel
        _noteText = State(initialValue: annotation.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headerTitle)
                .font(.headline)
            if let text = annotation.selectedText, !text.isEmpty {
                Text("\u{201C}\(text)\u{201D}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6))
                    .lineLimit(5)
            }
            Text("Note")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            TextEditor(text: $noteText)
                .font(.body)
                .frame(minHeight: 120)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2))
                )
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(noteText) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 280)
    }

    private var headerTitle: String {
        annotation.note == nil ? "Add Note" : "Edit Note"
    }
}

// MARK: - WKWebView reader pane

/// Minimal WKWebView wrapper for the reader's chapter pane. Far
/// simpler than the editor's `PreviewView` — no IntersectionObserver
/// bridge, no anchor-scroll requests, no JS message channel. Reads
/// the chapter file URL with the EPUB's working directory as the
/// allowed-access root so relative CSS / image references resolve.
///
/// Font-size injection lives in a tiny `<style id="humanist-reader-
/// override">` element added on `didFinish`. Re-injecting on every
/// load keeps the override consistent across chapter changes.
private struct WebReaderPane: NSViewRepresentable {
    let url: URL
    let accessRoot: URL
    let reloadTrigger: Int
    let fontSize: Double
    /// Optional scroll target — when the spine index matches this
    /// pane's chapter and the nonce hasn't been flushed yet, scroll
    /// the WKWebView to the matching element id after load (or
    /// immediately if already loaded).
    var scrollAnchor: ReaderViewModel.ScrollAnchor? = nil
    /// Optional scroll-fraction restore target. Same shape as
    /// `scrollAnchor` but targets a normalized position
    /// (0.0–1.0) instead of an element id — used by the
    /// position-persistence path so reopening a book lands at
    /// the exact spot you stopped reading.
    var scrollFraction: ReaderViewModel.ScrollFractionRequest? = nil
    /// Live scroll-position callback. The injected JS posts
    /// `{type: "scroll", fraction: 0.42}` on each scroll event;
    /// this callback fires on the main actor with the new
    /// fraction. Caller debounces persistence.
    var onScrollUpdate: ((Double) -> Void)? = nil
    /// Inbound find request. When the nonce changes,
    /// `WKWebView.find(_:configuration:completionHandler:)` runs
    /// against the new query + direction; the completion handler
    /// posts the matchFound result back via `onFindResult`.
    var findRequest: FindRequest? = nil
    /// Find-result callback. Fires with `true` on a successful
    /// find (selection updated + visible in the WKWebView),
    /// `false` when no match exists. Caller surfaces a status
    /// label in the find bar.
    var onFindResult: ((Bool) -> Void)? = nil
    /// Copy-with-citation request nonce. When this changes, the
    /// coordinator runs a small JS snippet to grab the current
    /// selection and find its nearest paragraph anchor, then
    /// hands the result + chapter index to `onCitationContext`
    /// for Swift-side citation assembly + clipboard write.
    var copyCitationRequest: UUID? = nil
    /// Result callback for copy-with-citation. Fires with a
    /// `CitationContext` describing the user's selection (or
    /// `nil` when nothing is selected so the toolbar action
    /// can surface a "Select some text first." hint instead of
    /// silently no-op'ing).
    var onCitationContext: ((CitationContext?) -> Void)? = nil

    /// Bookmark-here request nonce. Coordinator runs JS that
    /// finds the topmost-visible `hu-p-N-M` anchor in the
    /// current viewport and posts it back via
    /// `onBookmarkContext`. Swift assembles the Annotation.
    var bookmarkRequest: UUID? = nil
    /// Result callback for the bookmark gesture. nil → no
    /// anchor found (chapter has no Humanist anchors or fully
    /// scrolled past); UI degrades to a chapter-level bookmark.
    var onBookmarkContext: ((String?) -> Void)? = nil

    /// Highlight-selection request. The Swift side mints the
    /// annotation id up front + passes it through so the JS
    /// can stamp `data-annotation-id` on the wrapping span;
    /// the same id then matches the persisted Annotation, so
    /// later "delete this highlight" gestures (Phase E) can
    /// strip the span by id.
    struct HighlightRequest: Equatable {
        let annotationId: UUID
        let nonce: UUID
    }
    var highlightRequest: HighlightRequest? = nil
    /// Result callback for the highlight gesture. nil → no
    /// selection (toolbar/keyboard fired with cursor only);
    /// non-nil → text + anchor + offsets for Swift-side
    /// persistence into AnnotationStore.
    var onHighlightCaptured: ((HighlightCapture?) -> Void)? = nil

    /// Right-click "Highlight" — same effect as the toolbar
    /// Highlight button. Set on the WKWebView subclass once in
    /// makeNSView and on every updateNSView pass (since the
    /// closure captures live SwiftUI bindings).
    var onContextHighlight: (() -> Void)? = nil
    /// Right-click "Add Note…" — wraps the selection AND opens
    /// the note editor for the freshly-minted annotation.
    var onContextAddNote: (() -> Void)? = nil
    /// Right-click "Copy with Citation" — same effect as ⇧⌘C.
    var onContextCopyCitation: (() -> Void)? = nil

    /// Annotations to restore into the current chapter on
    /// load. Filtered to highlights / passages whose chapterIdx
    /// matches the loaded spine index. Bookmarks aren't visual
    /// so they're excluded; restoration happens in didFinish.
    var chapterHighlights: [Annotation] = []

    /// Passage-attribute toggle request. When the user saves a
    /// note on an existing highlight (promoting it to passage)
    /// the wrap span's `data-passage` attribute needs to flip
    /// so the visual underline appears without a chapter
    /// reload. Same nonce pattern as the other request slots.
    var passageMarkerRequest: ReaderView.PassageMarkerRequest? = nil

    /// Paginated-mode flag. Coordinator applies CSS columns
    /// when this flips on, removes them when off. Initial
    /// application happens after didFinish so the page-count
    /// measurement runs against the laid-out document.
    var isPaginated: Bool = false
    /// Page-navigation request from the VM. Coordinator
    /// translates to JS calls (`humanistPagination.next()` /
    /// `.previous()` / `.toPage(N)`).
    var pageNavRequest: ReaderViewModel.PageNavRequest? = nil
    /// Callback for pagination measurement updates. JS posts
    /// `{type: "pagination", current: N, count: M}` after
    /// applying the column layout and after window-resize
    /// re-layouts; this routes to the VM's
    /// didReportPagination(currentPage:pageCount:).
    var onPaginationUpdate: ((Int, Int) -> Void)? = nil

    /// Bundled reading-appearance settings — font / line-height
    /// / margins / theme. Passed through as a struct so a
    /// single comparison drives whether to re-fire the JS
    /// variable-setter (vs. checking each independently in
    /// updateNSView).
    struct Appearance: Equatable {
        let fontStack: String
        let lineHeight: Double
        let marginEm: Double
        let themeName: String
    }
    var appearance: Appearance = Appearance(
        fontStack: ReaderFontFamily.serif.cssStack,
        lineHeight: 1.5, marginEm: 2.0, themeName: "system"
    )

    /// JS-side capture for a successful highlight gesture.
    struct HighlightCapture: Equatable {
        let annotationId: UUID
        let text: String
        let paragraphAnchorId: String?
        let startOffset: Int?
        let endOffset: Int?
    }

    /// What the WKWebView reports back for a copy-with-citation
    /// request. The coordinator builds this from a selection
    /// query; the Swift caller decides how to format it (the
    /// book title + chapter title resolution live on the VM).
    struct CitationContext: Equatable {
        /// Selected text, verbatim — preserved with whatever
        /// whitespace the user grabbed.
        let text: String
        /// Zero-based chapter index extracted from the nearest
        /// `hu-p-N-M` ancestor's id. nil when the EPUB doesn't
        /// carry Humanist per-paragraph anchors; caller falls
        /// back to citing the current spine index.
        let chapterIdx: Int?
        /// Paragraph index extracted from the same anchor.
        /// nil for the same reason as `chapterIdx`.
        let paragraphIdx: Int?
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "reader")
        // Inject the scroll-tracking script at document end so it
        // runs once the body exists. No-op on documents without
        // a scrollable body.
        userContent.addUserScript(WKUserScript(
            source: Self.scrollBridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        // Inject the pagination bridge at document end. The
        // module sits dormant until the Swift side calls
        // `humanistPagination.enter()` (via JS evaluation).
        userContent.addUserScript(WKUserScript(
            source: Self.paginationBridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        // Inject the highlight stylesheet at document start so
        // restored highlights paint immediately on first render
        // (vs. flashing unstyled until didFinish runs the
        // restore).
        userContent.addUserScript(WKUserScript(
            source: Self.highlightStylesheetJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // Reading-appearance stylesheet + JS variable-setter.
        // Document-start so the styles apply before first paint
        // (no FOUC when a saved Sepia/Dark theme reopens).
        userContent.addUserScript(WKUserScript(
            source: Self.appearanceBridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        cfg.userContentController = userContent
        let view = ReaderWKWebView(frame: .zero, configuration: cfg)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.fontSize = fontSize
        context.coordinator.onScrollUpdate = onScrollUpdate
        context.coordinator.readerView = view
        // Wire the right-click menu actions. These three closures
        // simply re-fire the same SwiftUI @State requests that
        // the toolbar / keyboard shortcut paths use, so the JS
        // wrap / capture pipeline is shared.
        view.onContextHighlight = onContextHighlight
        view.onContextAddNote = onContextAddNote
        view.onContextCopyCitation = onContextCopyCitation
        load(into: view)
        return view
    }

    /// Reading-appearance bridge: live-updates CSS variables on
    /// `<html>` so font / line-height / margins / theme changes
    /// don't require a chapter reload. The injected stylesheet
    /// reads those variables; user-popover sliders just rewrite
    /// the variable values via JS.
    private static let appearanceBridgeJS = """
    (function() {
      var s = document.createElement('style');
      s.id = 'humanist-reader-appearance-style';
      s.textContent =
        ':root { ' +
        '  --hu-reader-font-family: serif; ' +
        '  --hu-reader-line-height: 1.5; ' +
        '  --hu-reader-margin: 2em; ' +
        '}' +
        'body {' +
        '  font-family: var(--hu-reader-font-family) !important;' +
        '  line-height: var(--hu-reader-line-height) !important;' +
        '  padding-left: var(--hu-reader-margin) !important;' +
        '  padding-right: var(--hu-reader-margin) !important;' +
        '  transition: background-color 0.15s ease, color 0.15s ease;' +
        '}' +
        'html[data-hu-theme="sepia"] body {' +
        '  background-color: #f4ecd8 !important;' +
        '  color: #3b2f1a !important;' +
        '}' +
        'html[data-hu-theme="dark"] body {' +
        '  background-color: #1a1a1a !important;' +
        '  color: #e6e6e6 !important;' +
        '}' +
        'html[data-hu-theme="dark"] a { color: #6db4ff !important; }';
      document.documentElement.appendChild(s);
      window.humanistReaderAppearance = function(fontStack, lineHeight, marginEm, themeName) {
        var r = document.documentElement.style;
        r.setProperty('--hu-reader-font-family', fontStack);
        r.setProperty('--hu-reader-line-height', String(lineHeight));
        r.setProperty('--hu-reader-margin', marginEm + 'em');
        document.documentElement.setAttribute('data-hu-theme', themeName);
      };
    })();
    """

    /// Pagination bridge: CSS-columns-based "real reader" layout.
    /// Sits dormant on every chapter load. The Swift side calls
    /// `humanistPagination.enter()` to apply the column layout
    /// (which immediately re-measures + posts a pagination
    /// message back to Swift) and `.next()` / `.previous()` /
    /// `.toPage(N)` to navigate. `.exit()` reverts to scroll
    /// mode without reloading the chapter.
    ///
    /// The layout strategy is CSS multicol: `column-width: 100vw`
    /// + a fixed `height: 100vh` on the body, with horizontal
    /// overflow hidden. We track the current page via a
    /// `translateX(-N * 100vw)` transform on `<body>` so we get
    /// a clean snap-to-page rhythm without using the scroll
    /// position (CSS multicol's scrollLeft can be unreliable on
    /// re-layout).
    private static let paginationBridgeJS = """
    (function() {
      var STATE = {
        active: false,
        currentPage: 0,
        pageCount: 0,
      };
      function post(currentPage, pageCount) {
        try {
          if (window.webkit && window.webkit.messageHandlers
              && window.webkit.messageHandlers.reader) {
            window.webkit.messageHandlers.reader.postMessage({
              type: 'pagination',
              current: currentPage,
              count: pageCount,
            });
          }
        } catch (e) {}
      }
      function ensureStyle() {
        var s = document.getElementById('humanist-reader-pagination-style');
        if (s) return s;
        s = document.createElement('style');
        s.id = 'humanist-reader-pagination-style';
        s.textContent =
          'html.hu-paginated, html.hu-paginated body {' +
          '  height: 100vh !important;' +
          '  overflow: hidden !important;' +
          '  margin: 0 !important;' +
          '}' +
          'html.hu-paginated body {' +
          '  column-width: 100vw !important;' +
          '  column-gap: 0 !important;' +
          '  column-fill: auto !important;' +
          '  padding: 1.5em 2em !important;' +
          '  box-sizing: border-box !important;' +
          '  transition: transform 0.25s ease !important;' +
          '  will-change: transform;' +
          '}' +
          'html.hu-paginated body * {' +
          '  break-inside: avoid-column;' +
          '}' +
          'html.hu-paginated img, html.hu-paginated table {' +
          '  max-width: 100% !important;' +
          '  max-height: 90vh !important;' +
          '}';
        document.documentElement.appendChild(s);
        return s;
      }
      function measure() {
        // body.scrollWidth is the total laid-out width of all
        // columns; window.innerWidth is the page width.
        var pageW = window.innerWidth || 1;
        var total = document.body.scrollWidth;
        STATE.pageCount = Math.max(1, Math.round(total / pageW));
        if (STATE.currentPage >= STATE.pageCount) {
          STATE.currentPage = STATE.pageCount - 1;
        }
        if (STATE.currentPage < 0) STATE.currentPage = 0;
        applyTransform();
        post(STATE.currentPage, STATE.pageCount);
      }
      function applyTransform() {
        document.body.style.transform =
          'translateX(' + (-STATE.currentPage * 100) + 'vw)';
      }
      function onResize() {
        if (!STATE.active) return;
        // Brief debounce so a window-resize drag doesn't
        // hammer the measure loop.
        clearTimeout(window._humanistPagDebounce);
        window._humanistPagDebounce = setTimeout(measure, 100);
      }
      window.humanistPagination = {
        enter: function() {
          if (STATE.active) { measure(); return; }
          STATE.active = true;
          ensureStyle();
          document.documentElement.classList.add('hu-paginated');
          window.addEventListener('resize', onResize);
          // Defer measurement to next frame so the CSS has
          // applied before scrollWidth is read.
          requestAnimationFrame(measure);
        },
        exit: function() {
          if (!STATE.active) return;
          STATE.active = false;
          document.documentElement.classList.remove('hu-paginated');
          document.body.style.transform = '';
          window.removeEventListener('resize', onResize);
          STATE.currentPage = 0;
          STATE.pageCount = 0;
          post(0, 0);
        },
        next: function() {
          if (!STATE.active) return;
          if (STATE.currentPage < STATE.pageCount - 1) {
            STATE.currentPage += 1;
            applyTransform();
            post(STATE.currentPage, STATE.pageCount);
          }
        },
        previous: function() {
          if (!STATE.active) return;
          if (STATE.currentPage > 0) {
            STATE.currentPage -= 1;
            applyTransform();
            post(STATE.currentPage, STATE.pageCount);
          }
        },
        toPage: function(n) {
          if (!STATE.active) return;
          var p = Math.max(0, Math.min(n, STATE.pageCount - 1));
          STATE.currentPage = p;
          applyTransform();
          post(STATE.currentPage, STATE.pageCount);
        },
      };
    })();
    """

    /// CSS for the highlight span. Yellow, semi-transparent so
    /// underlying text stays clearly legible. Same single
    /// color choice we locked in the design — palette support
    /// can layer on later. `display: inline` because the wrap
    /// happens around inline ranges that may straddle existing
    /// inline elements.
    private static let highlightStylesheetJS = """
    (function() {
      var style = document.createElement('style');
      style.id = 'humanist-reader-highlight-style';
      style.textContent =
        '.hu-highlight { background-color: rgba(255, 235, 59, 0.45); ' +
        '  border-radius: 2px; ' +
        '  padding: 0 1px; ' +
        '  cursor: pointer; }' +
        '.hu-highlight[data-passage="1"] { ' +
        '  border-bottom: 2px solid rgba(255, 152, 0, 0.7); }';
      document.documentElement.appendChild(style);
    })();
    """

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.fontSize = fontSize
        context.coordinator.onScrollUpdate = onScrollUpdate
        context.coordinator.onFindResult = onFindResult
        context.coordinator.onCitationContext = onCitationContext
        // Re-bind the right-click menu closures so they capture
        // the current pass's SwiftUI bindings. WebReaderPane is
        // a value type that SwiftUI recreates per render; the
        // closures it carries become stale otherwise.
        if let reader = nsView as? ReaderWKWebView {
            reader.onContextHighlight = onContextHighlight
            reader.onContextAddNote = onContextAddNote
            reader.onContextCopyCitation = onContextCopyCitation
        }
        load(into: nsView, coordinator: context.coordinator)
        context.coordinator.applyFontSizeIfReady(view: nsView)
        // Stash the most recent pending anchor; the coordinator
        // flushes it either right now (page already loaded) or on
        // the next didFinish (load in flight).
        if let anchor = scrollAnchor,
           context.coordinator.lastFlushedAnchorNonce != anchor.nonce {
            context.coordinator.pendingAnchorID = anchor.elementID
            context.coordinator.pendingAnchorNonce = anchor.nonce
            context.coordinator.flushPendingAnchorIfReady(view: nsView)
        }
        if let req = scrollFraction,
           context.coordinator.lastFlushedFractionNonce != req.nonce {
            context.coordinator.pendingFraction = req.fraction
            context.coordinator.pendingFractionNonce = req.nonce
            context.coordinator.flushPendingFractionIfReady(view: nsView)
        }
        if let req = findRequest,
           context.coordinator.lastFlushedFindNonce != req.nonce {
            context.coordinator.lastFlushedFindNonce = req.nonce
            context.coordinator.executeFind(request: req, view: nsView)
        }
        if let req = copyCitationRequest,
           context.coordinator.lastFlushedCitationNonce != req {
            context.coordinator.lastFlushedCitationNonce = req
            context.coordinator.captureCitationContext(view: nsView)
        }
        context.coordinator.onBookmarkContext = onBookmarkContext
        if let req = bookmarkRequest,
           context.coordinator.lastFlushedBookmarkNonce != req {
            context.coordinator.lastFlushedBookmarkNonce = req
            context.coordinator.captureNearestVisibleAnchor(view: nsView)
        }
        context.coordinator.onHighlightCaptured = onHighlightCaptured
        context.coordinator.pendingChapterHighlights = chapterHighlights
        if let req = highlightRequest,
           context.coordinator.lastFlushedHighlightNonce != req.nonce {
            context.coordinator.lastFlushedHighlightNonce = req.nonce
            context.coordinator.captureHighlight(
                annotationId: req.annotationId, view: nsView
            )
        }
        if let req = passageMarkerRequest,
           context.coordinator.lastFlushedPassageMarkerNonce != req.nonce {
            context.coordinator.lastFlushedPassageMarkerNonce = req.nonce
            context.coordinator.updatePassageMarker(
                annotationId: req.annotationId,
                isPassage: req.isPassage,
                view: nsView
            )
        }
        context.coordinator.onPaginationUpdate = onPaginationUpdate
        // Push appearance to the JS variable-setter on every
        // pass. The setter is a cheap no-op when values match,
        // so we don't bother diffing here.
        context.coordinator.pendingAppearance = appearance
        context.coordinator.applyAppearanceIfReady(view: nsView)
        // Apply / remove the pagination layout when the binding
        // flips. Done after didFinish guards in the helper so
        // pre-load enable requests get deferred to the next
        // didFinish.
        context.coordinator.syncPagination(
            isPaginated: isPaginated, view: nsView
        )
        if let req = pageNavRequest,
           context.coordinator.lastFlushedPageNavNonce != req.nonce {
            context.coordinator.lastFlushedPageNavNonce = req.nonce
            context.coordinator.dispatchPageNav(
                request: req, view: nsView
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// JS injected on every chapter load. Tracks scroll position
    /// + posts it on a debounce so the Swift side gets one
    /// message per ~250ms of quiet instead of one per wheel
    /// tick. Posts `0` for pages that aren't scrollable
    /// (`scrollMaxY <= 0`) so the Swift side knows the chapter
    /// is fully visible without scrolling.
    ///
    /// Also posts a `selectionchange` event whenever the user's
    /// text selection state flips between empty and non-empty.
    /// The Swift side caches the flag so the WKWebView's right-
    /// click menu can decide whether to insert annotation
    /// actions without doing a JS round-trip at menu-open time.
    private static let scrollBridgeJS = """
    (function() {
      var pending = false;
      function post() {
        try {
          var maxY = (document.documentElement.scrollHeight
                      - document.documentElement.clientHeight);
          var f = 0;
          if (maxY > 0) { f = window.scrollY / maxY; }
          if (window.webkit
              && window.webkit.messageHandlers
              && window.webkit.messageHandlers.reader) {
            window.webkit.messageHandlers.reader.postMessage({
              type: 'scroll', fraction: f,
            });
          }
        } catch (e) {}
      }
      function schedulePost() {
        if (pending) return;
        pending = true;
        setTimeout(function() { pending = false; post(); }, 250);
      }
      window.addEventListener('scroll', schedulePost, { passive: true });
      // Fire one immediately so the Swift side knows the
      // starting position (typically 0 unless restored).
      post();

      // Selection-state bridge. Only post when the boolean
      // flips so a drag-select doesn't spam the Swift side.
      var lastHas = false;
      function postSelection() {
        try {
          var sel = window.getSelection();
          var has = !!(sel && !sel.isCollapsed
                       && sel.toString().trim().length > 0);
          if (has === lastHas) return;
          lastHas = has;
          if (window.webkit
              && window.webkit.messageHandlers
              && window.webkit.messageHandlers.reader) {
            window.webkit.messageHandlers.reader.postMessage({
              type: 'selectionchange', has: has,
            });
          }
        } catch (e) {}
      }
      document.addEventListener('selectionchange', postSelection);
    })();
    """

    private func load(into view: WKWebView, coordinator: Coordinator? = nil) {
        let resolvedURL = url.canonicalForFile
        let resolvedAccess = accessRoot.canonicalForFile
        let coord = coordinator ?? (view.navigationDelegate as? Coordinator)
        let urlChanged = coord?.loadedURL != resolvedURL
        let triggerChanged = coord?.loadedTrigger != reloadTrigger
        guard urlChanged || triggerChanged else { return }
        coord?.loadedURL = resolvedURL
        coord?.loadedTrigger = reloadTrigger
        // Reset isLoaded so a queued anchor doesn't try to flush
        // against the previous chapter's DOM while the new one
        // is loading. `didFinish` re-sets it after the next
        // navigation completes.
        coord?.isLoaded = false
        // The JS pagination module's state lives per-document;
        // a fresh chapter load means we'll need to re-enter
        // paginated mode against the new body in didFinish.
        coord?.paginationActive = false
        view.stopLoading()
        view.loadFileURL(resolvedURL, allowingReadAccessTo: resolvedAccess)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedURL: URL?
        var loadedTrigger: Int = -1
        var fontSize: Double = EditorSettingsDefaults.previewFontSize
        weak var lastFinishedView: WKWebView?
        /// Pending anchor id to scroll to. Set by `updateNSView`
        /// from the binding; flushed by `didFinish` once the
        /// page is loaded, or immediately by
        /// `flushPendingAnchorIfReady` when the load already
        /// completed (same-chapter citation taps).
        var pendingAnchorID: String?
        /// Nonce of the in-flight anchor request. Stored
        /// post-flush as `lastFlushedAnchorNonce` so identical
        /// repeat-tap requests skip re-flushing.
        var pendingAnchorNonce: UUID?
        /// Nonce of the most recently flushed anchor request.
        /// `updateNSView` compares against the binding's nonce
        /// to decide whether a new scroll should fire.
        var lastFlushedAnchorNonce: UUID?
        /// Pending scroll-fraction restore (0.0–1.0). Same shape
        /// as the anchor pair above; flushed by `didFinish` or
        /// `flushPendingFractionIfReady`.
        var pendingFraction: Double?
        var pendingFractionNonce: UUID?
        var lastFlushedFractionNonce: UUID?
        /// True once the WKWebView's didFinish has fired for the
        /// current `loadedURL`. Until then, anchor flushes get
        /// deferred — `getElementById` would otherwise return
        /// null before the document is parsed.
        var isLoaded: Bool = false
        /// Live scroll-update callback. Fires on the main actor
        /// with the new fraction each time the JS bridge posts
        /// a scroll event. nil → ignore (no listener wired).
        var onScrollUpdate: ((Double) -> Void)?
        /// Find-result callback. Fires after each
        /// `WKWebView.find(_:configuration:completionHandler:)`
        /// with the matchFound bool.
        var onFindResult: ((Bool) -> Void)?
        /// Nonce of the most recently executed find request.
        /// `updateNSView` compares against the binding's nonce
        /// to decide whether to fire a new find.
        var lastFlushedFindNonce: UUID?
        /// Citation-context callback. Fires once per copy-with-
        /// citation request with the JS-side selection + nearest
        /// hu-p-N-M anchor, or nil when no text is selected.
        var onCitationContext: ((CitationContext?) -> Void)?
        var lastFlushedCitationNonce: UUID?
        /// Bookmark-here callback. Fires with the topmost-visible
        /// hu-p-N-M anchor in the viewport, or nil when the
        /// chapter has no Humanist anchors / has been fully
        /// scrolled past.
        var onBookmarkContext: ((String?) -> Void)?
        var lastFlushedBookmarkNonce: UUID?
        /// Highlight-captured callback. Fires after JS wraps the
        /// selection in a `.hu-highlight` span; carries text +
        /// anchor + offsets for Swift-side persistence.
        var onHighlightCaptured: ((HighlightCapture?) -> Void)?
        var lastFlushedHighlightNonce: UUID?
        /// The most recent list of highlights / passages for
        /// the currently-loaded chapter. Snapshotted by
        /// `updateNSView` so didFinish has data to restore
        /// without re-reaching into the SwiftUI graph.
        var pendingChapterHighlights: [Annotation] = []
        /// Nonce of the most recently applied passage-marker
        /// update. Same compare-against-binding pattern as the
        /// other request slots.
        var lastFlushedPassageMarkerNonce: UUID?
        /// Current pagination state — true means the JS bridge
        /// has applied the column layout. Used to short-circuit
        /// redundant enter() / exit() calls on
        /// no-op updateNSView passes.
        var paginationActive: Bool = false
        /// Pagination-update callback. Fires whenever the JS
        /// bridge measures (initial apply + window resize)
        /// with the current page index + total page count.
        var onPaginationUpdate: ((Int, Int) -> Void)?
        /// Nonce of the most recently dispatched page-nav
        /// request. Compared against the binding so consecutive
        /// next / previous taps fire each time instead of
        /// being coalesced.
        var lastFlushedPageNavNonce: UUID?

        /// Pending appearance — last value from updateNSView.
        /// Flushed via humanistReaderAppearance() on every
        /// updateNSView pass + on every didFinish (so a fresh
        /// chapter load picks up the saved theme before paint).
        var pendingAppearance: Appearance?

        /// Weak ref to the WKWebView subclass we own. Set in
        /// `makeNSView`. Used by the selectionchange message
        /// handler to update the subclass's cached
        /// `hasSelection` so right-click menu decisions stay
        /// synchronous.
        weak var readerView: ReaderWKWebView?
        /// True while we're programmatically scrolling (anchor
        /// flush or fraction restore). The JS bridge can fire
        /// a scroll event from the scrollIntoView itself, which
        /// would otherwise feed back as "user scrolled to here"
        /// and persist the restored position immediately.
        var suppressScrollReports: Bool = false

        nonisolated func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastFinishedView = webView
                self.isLoaded = true
                self.applyFontSizeIfReady(view: webView)
                self.applyAppearanceIfReady(view: webView)
                self.restoreHighlights(view: webView)
                // Re-enter paginated mode on every chapter load
                // when the flag is on. JS module's `enter()` is
                // idempotent (no-op if already active) but we
                // need to call it AFTER the chapter's DOM is
                // parsed so column-width measurement runs
                // against the laid-out body.
                if self.pendingPaginationOn {
                    self.callPaginationEnter(view: webView)
                }
                self.flushPendingAnchorIfReady(view: webView)
                self.flushPendingFractionIfReady(view: webView)
            }
        }

        /// Latest desired pagination state — set by
        /// `syncPagination` and read by `didFinish`. Needed
        /// because pagination must apply AFTER the chapter's
        /// content is loaded, but `updateNSView` may run before
        /// the load completes (initial render).
        var pendingPaginationOn: Bool = false

        /// Sync the JS pagination state with the desired
        /// `isPaginated` from the binding. When the page is
        /// still loading, defers the enter() call to didFinish
        /// via `pendingPaginationOn`; immediate exit() is safe
        /// either way (no-op if not active).
        func syncPagination(isPaginated: Bool, view: WKWebView) {
            pendingPaginationOn = isPaginated
            if !isLoaded { return }
            if isPaginated && !paginationActive {
                callPaginationEnter(view: view)
            } else if !isPaginated && paginationActive {
                view.evaluateJavaScript(
                    "humanistPagination.exit();",
                    completionHandler: nil
                )
                paginationActive = false
            }
        }

        /// Run `humanistPagination.enter()`. Marks the
        /// coordinator's `paginationActive` so subsequent
        /// sync passes know not to re-enter.
        private func callPaginationEnter(view: WKWebView) {
            view.evaluateJavaScript(
                "humanistPagination.enter();",
                completionHandler: nil
            )
            paginationActive = true
        }

        /// Dispatch a page-navigation request to the JS bridge.
        /// Direction maps directly to the matching JS method;
        /// `.toPage(N)` becomes a `.toPage(N)` call.
        func dispatchPageNav(
            request: ReaderViewModel.PageNavRequest, view: WKWebView
        ) {
            let js: String
            switch request.direction {
            case .next:
                js = "humanistPagination.next();"
            case .previous:
                js = "humanistPagination.previous();"
            case .toPage(let n):
                js = "humanistPagination.toPage(\(n));"
            }
            view.evaluateJavaScript(js, completionHandler: nil)
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "reader",
                  let dict = message.body as? [String: Any]
            else { return }
            switch dict["type"] as? String {
            case "scroll":
                guard let fraction = dict["fraction"] as? Double
                else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.suppressScrollReports { return }
                    self.onScrollUpdate?(fraction)
                }
            case "pagination":
                guard let cur = dict["current"] as? Int,
                      let count = dict["count"] as? Int
                else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.onPaginationUpdate?(cur, count)
                }
            case "selectionchange":
                guard let has = dict["has"] as? Bool else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.readerView?.hasSelection = has
                }
            default:
                break
            }
        }

        /// Apply the pending appearance bundle by calling the JS
        /// variable-setter installed by `appearanceBridgeJS`.
        /// Idempotent — running with the same values is a cheap
        /// no-op visually. Safe to call before didFinish; the
        /// user-script setup at document start defines
        /// `humanistReaderAppearance` even though body content
        /// hasn't loaded yet.
        func applyAppearanceIfReady(view: WKWebView) {
            guard let app = pendingAppearance else { return }
            let escapedFont = stringLiteral(app.fontStack)
            let theme = stringLiteral(app.themeName)
            let js = """
            if (typeof window.humanistReaderAppearance === 'function') {
              humanistReaderAppearance(\(escapedFont), \(app.lineHeight), \(app.marginEm), \(theme));
            }
            """
            view.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Inject (or update) the `<style id="humanist-reader-override">`
        /// element with the current font size. Idempotent — running
        /// twice with the same value is cheap and a no-op visually.
        func applyFontSizeIfReady(view: WKWebView) {
            guard view.url != nil else { return }
            let css = "body { font-size: \(Int(fontSize))px !important; }"
            let js = """
            (function() {
              var s = document.getElementById('humanist-reader-override');
              if (!s) {
                s = document.createElement('style');
                s.id = 'humanist-reader-override';
                document.head.appendChild(s);
              }
              s.textContent = \(stringLiteral(css));
            })();
            """
            view.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Scroll the WKWebView to the element with id
        /// `pendingAnchorID` if the page has finished loading.
        /// Otherwise no-op — `didFinish` calls back into this
        /// method once the document parses. `getElementById`
        /// returning null (the EPUB lacks our `hu-p-*` anchors)
        /// is treated as a silent miss; same posture as the
        /// editor's preview pane.
        func flushPendingAnchorIfReady(view: WKWebView) {
            guard isLoaded,
                  let anchorID = pendingAnchorID,
                  let nonce = pendingAnchorNonce,
                  lastFlushedAnchorNonce != nonce
            else { return }
            let escaped = stringLiteral(anchorID)
            // Smooth scroll into view, biased toward the top so
            // the user lands above the fold even when the
            // surrounding paragraphs occupy the viewport.
            let js = """
            (function() {
              var el = document.getElementById(\(escaped));
              if (el) {
                el.scrollIntoView({ behavior: 'smooth', block: 'start' });
              }
            })();
            """
            // Suppress feedback for ~1s — the smooth scroll
            // generates intermediate scroll events that would
            // otherwise be interpreted as user scrolls.
            suppressScrollReports = true
            view.evaluateJavaScript(js, completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.suppressScrollReports = false
            }
            lastFlushedAnchorNonce = nonce
            pendingAnchorID = nil
            pendingAnchorNonce = nil
        }

        /// Restore a saved sub-chapter scroll position. Computes
        /// the target Y from the fraction × document height
        /// and jumps the WKWebView there. Like the anchor flush,
        /// silently no-ops on documents with `scrollMaxY == 0`
        /// (chapters that fit in the viewport).
        func flushPendingFractionIfReady(view: WKWebView) {
            guard isLoaded,
                  let fraction = pendingFraction,
                  let nonce = pendingFractionNonce,
                  lastFlushedFractionNonce != nonce
            else { return }
            let js = """
            (function() {
              var maxY = (document.documentElement.scrollHeight
                          - document.documentElement.clientHeight);
              if (maxY > 0) {
                window.scrollTo({
                  top: \(fraction) * maxY,
                  behavior: 'auto'
                });
              }
            })();
            """
            // Same suppression as anchor flush — the programmatic
            // scrollTo emits a scroll event we don't want to
            // mis-interpret.
            suppressScrollReports = true
            view.evaluateJavaScript(js, completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.suppressScrollReports = false
            }
            lastFlushedFractionNonce = nonce
            pendingFraction = nil
            pendingFractionNonce = nil
        }

        /// Wrap the current selection in a `.hu-highlight` span
        /// and report back the text + paragraph anchor + char
        /// offsets so Swift can persist a matching Annotation.
        /// The annotation id is minted in Swift first and passed
        /// through so the wrapping span carries
        /// `data-annotation-id` for later delete-by-id Phase E
        /// gestures.
        ///
        /// Falls back through three wrap strategies:
        ///   1. `surroundContents` — works when the selection
        ///      doesn't cross element boundaries (the common
        ///      case for inline-text highlights).
        ///   2. `extractContents` + `insertNode` — works for
        ///      cross-element ranges (selections spanning
        ///      `<em>` boundaries, etc.).
        ///   3. Skip wrapping — annotation still persists; the
        ///      restore path uses text-match to wrap on the
        ///      next chapter open.
        func captureHighlight(annotationId: UUID, view: WKWebView) {
            let idString = annotationId.uuidString
            let js = """
            (function() {
              var sel = window.getSelection();
              if (!sel || sel.isCollapsed || !sel.rangeCount) {
                return null;
              }
              var range = sel.getRangeAt(0);
              var text = range.toString();
              if (!text) return null;
              // Find containing hu-p-N-M paragraph.
              var node = range.commonAncestorContainer;
              while (node) {
                if (node.nodeType === 1 && node.id
                    && /^hu-p-\\d+-\\d+$/.test(node.id)) {
                  break;
                }
                node = node.parentNode;
              }
              var anchorId = node ? node.id : null;
              // Compute char offsets within the paragraph's
              // flat textContent.
              var startOffset = -1, endOffset = -1;
              if (node) {
                var preRange = document.createRange();
                preRange.setStart(node, 0);
                preRange.setEnd(range.startContainer, range.startOffset);
                startOffset = preRange.toString().length;
                endOffset = startOffset + text.length;
              }
              // Wrap the selection.
              var wrapper = document.createElement('span');
              wrapper.className = 'hu-highlight';
              wrapper.setAttribute('data-annotation-id', '\(idString)');
              try {
                range.surroundContents(wrapper);
              } catch (e1) {
                try {
                  wrapper.appendChild(range.extractContents());
                  range.insertNode(wrapper);
                } catch (e2) {
                  // Couldn't wrap; persistence still works via
                  // restore-by-text-match on next chapter load.
                }
              }
              sel.removeAllRanges();
              return JSON.stringify({
                text: text,
                anchorId: anchorId,
                startOffset: startOffset,
                endOffset: endOffset,
              });
            })();
            """
            view.evaluateJavaScript(js) { [weak self] result, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let raw = result as? String,
                          let data = raw.data(using: .utf8),
                          let dict = try? JSONSerialization
                            .jsonObject(with: data) as? [String: Any],
                          let text = dict["text"] as? String,
                          !text.isEmpty
                    else {
                        self.onHighlightCaptured?(nil)
                        return
                    }
                    let anchorId = dict["anchorId"] as? String
                    let startOffset = (dict["startOffset"] as? Int)
                        .flatMap { $0 >= 0 ? $0 : nil }
                    let endOffset = (dict["endOffset"] as? Int)
                        .flatMap { $0 >= 0 ? $0 : nil }
                    self.onHighlightCaptured?(HighlightCapture(
                        annotationId: annotationId,
                        text: text,
                        paragraphAnchorId: anchorId,
                        startOffset: startOffset,
                        endOffset: endOffset
                    ))
                }
            }
        }

        /// Restore stored highlights for the current chapter
        /// after the WKWebView finishes loading. Walks each
        /// stored Annotation, locates its paragraph by anchor
        /// id, then finds the matching text range — verbatim
        /// match first, character-offset fallback — and wraps
        /// it in a `.hu-highlight` span (with
        /// `data-passage="1"` when the annotation carries a
        /// note). Silent miss on chapters / paragraphs that no
        /// longer exist (book changed on disk; underlying
        /// XHTML rewritten) — the annotation stays in storage
        /// for the next chapter load to retry.
        func restoreHighlights(view: WKWebView) {
            // Build a JSON-passable list of (id, anchorId, text,
            // startOffset, endOffset, isPassage) tuples.
            let entries = pendingChapterHighlights.compactMap { annot -> [String: Any]? in
                guard annot.kind == .highlight || annot.kind == .passage,
                      let anchorId = annot.paragraphAnchorId,
                      let text = annot.selectedText,
                      !text.isEmpty
                else { return nil }
                var dict: [String: Any] = [
                    "id": annot.id.uuidString,
                    "anchorId": anchorId,
                    "text": text,
                    "isPassage": annot.kind == .passage,
                ]
                if let r = annot.selectionRange {
                    dict["startOffset"] = r.startOffset
                    dict["endOffset"] = r.endOffset
                }
                return dict
            }
            guard !entries.isEmpty else { return }
            guard let data = try? JSONSerialization.data(
                withJSONObject: entries
            ), let json = String(data: data, encoding: .utf8) else {
                return
            }
            let js = """
            (function() {
              var entries = \(json);
              entries.forEach(function(e) {
                var para = document.getElementById(e.anchorId);
                if (!para) return;
                // Skip if already restored — re-render of the
                // same chapter shouldn't double-wrap.
                if (para.querySelector(
                  '[data-annotation-id="' + e.id + '"]'
                )) return;
                var content = para.textContent;
                var start = content.indexOf(e.text);
                if (start === -1) {
                  // Verbatim match failed; fall back to offsets.
                  if (typeof e.startOffset !== 'number'
                      || typeof e.endOffset !== 'number') return;
                  if (e.endOffset > content.length) return;
                  start = e.startOffset;
                }
                var end = start + e.text.length;
                wrapTextRange(para, start, end, e.id, e.isPassage);
              });
              function wrapTextRange(root, start, end, id, isPassage) {
                var walker = document.createTreeWalker(
                  root, NodeFilter.SHOW_TEXT
                );
                var cursor = 0;
                var startNode, startOff, endNode, endOff;
                while (walker.nextNode()) {
                  var n = walker.currentNode;
                  var len = n.textContent.length;
                  if (startNode === undefined && cursor + len > start) {
                    startNode = n;
                    startOff = start - cursor;
                  }
                  if (cursor + len >= end) {
                    endNode = n;
                    endOff = end - cursor;
                    break;
                  }
                  cursor += len;
                }
                if (!startNode || !endNode) return;
                var range = document.createRange();
                range.setStart(startNode, startOff);
                range.setEnd(endNode, endOff);
                var wrapper = document.createElement('span');
                wrapper.className = 'hu-highlight';
                wrapper.setAttribute('data-annotation-id', id);
                if (isPassage) {
                  wrapper.setAttribute('data-passage', '1');
                }
                try {
                  range.surroundContents(wrapper);
                } catch (e1) {
                  try {
                    wrapper.appendChild(range.extractContents());
                    range.insertNode(wrapper);
                  } catch (e2) {}
                }
              }
            })();
            """
            view.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Toggle the `data-passage` attribute on the wrap span
        /// for an existing highlight. Promotion (note added →
        /// kind becomes .passage) adds the attribute; demotion
        /// (note cleared → kind back to .highlight) removes it.
        /// CSS keys off the attribute to draw the orange
        /// underline; updating it in-place avoids a full
        /// chapter reload to see the visual change.
        func updatePassageMarker(
            annotationId: UUID, isPassage: Bool, view: WKWebView
        ) {
            let idString = annotationId.uuidString
            let flag = isPassage ? "true" : "false"
            let js = """
            (function() {
              var el = document.querySelector(
                '[data-annotation-id="\(idString)"]'
              );
              if (!el) return;
              if (\(flag)) {
                el.setAttribute('data-passage', '1');
              } else {
                el.removeAttribute('data-passage');
              }
            })();
            """
            view.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Capture the topmost-visible `hu-p-N-M` anchor in the
        /// viewport for the bookmark-here gesture. Walks every
        /// anchor in document order; first one whose bottom is
        /// past the top viewport edge wins. Returns nil when
        /// the chapter has no Humanist anchors (third-party
        /// EPUB) or is short enough that no anchor sits in the
        /// visible region.
        func captureNearestVisibleAnchor(view: WKWebView) {
            let js = """
            (function() {
              var anchors = document.querySelectorAll('[id^="hu-p-"]');
              for (var i = 0; i < anchors.length; i++) {
                var rect = anchors[i].getBoundingClientRect();
                // First anchor whose bottom is below the top
                // viewport edge — i.e. visible or upcoming.
                if (rect.bottom > 0) {
                  return anchors[i].id;
                }
              }
              return null;
            })();
            """
            view.evaluateJavaScript(js) { [weak self] result, _ in
                DispatchQueue.main.async {
                    let anchor = result as? String
                    self?.onBookmarkContext?(anchor)
                }
            }
        }

        /// Capture the current text selection + nearest hu-p-N-M
        /// anchor for a copy-with-citation request. Posts the
        /// result (nil for empty selection) to onCitationContext
        /// for Swift-side assembly + clipboard write. JS does the
        /// DOM walk because finding the closest matching
        /// ancestor cleanly in Swift would mean serializing the
        /// whole DOM across the bridge.
        func captureCitationContext(view: WKWebView) {
            let js = """
            (function() {
              var sel = window.getSelection();
              if (!sel || sel.isCollapsed || !sel.rangeCount) {
                return null;
              }
              var text = sel.toString();
              if (!text) return null;
              // Walk up from the selection's common ancestor
              // looking for a hu-p-{N}-{M} id. Match by regex
              // because the element type might be a span / p /
              // div / etc. depending on how the renderer wrapped
              // the paragraph.
              var node = sel.getRangeAt(0).commonAncestorContainer;
              var chapterIdx = null;
              var paragraphIdx = null;
              while (node) {
                if (node.nodeType === 1 && node.id) {
                  var m = node.id.match(/^hu-p-(\\d+)-(\\d+)$/);
                  if (m) {
                    chapterIdx = parseInt(m[1], 10);
                    paragraphIdx = parseInt(m[2], 10);
                    break;
                  }
                }
                node = node.parentNode;
              }
              return JSON.stringify({
                text: text,
                chapterIdx: chapterIdx,
                paragraphIdx: paragraphIdx,
              });
            })();
            """
            view.evaluateJavaScript(js) { [weak self] result, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let raw = result as? String,
                          let data = raw.data(using: .utf8),
                          let dict = try? JSONSerialization
                            .jsonObject(with: data) as? [String: Any],
                          let text = dict["text"] as? String,
                          !text.isEmpty
                    else {
                        // No selection (or unexpected return
                        // shape). Surface nil so the caller can
                        // tell the user.
                        self.onCitationContext?(nil)
                        return
                    }
                    let chapter = dict["chapterIdx"] as? Int
                    let paragraph = dict["paragraphIdx"] as? Int
                    self.onCitationContext?(CitationContext(
                        text: text,
                        chapterIdx: chapter,
                        paragraphIdx: paragraph
                    ))
                }
            }
        }

        /// Execute a find request against the WKWebView. Uses
        /// the platform-native `find(_:configuration:
        /// completionHandler:)` so highlight + selection
        /// behavior matches every other macOS WebKit-based
        /// reader. The first match wraps to the start; the
        /// backward direction handles previous.
        ///
        /// Programmatic-scroll feedback is suppressed for ~1s
        /// after the find — the find's selectionchange + scroll
        /// would otherwise feed through the JS bridge as a
        /// user-initiated scroll and overwrite the saved
        /// position with the find result's offset.
        func executeFind(request: FindRequest, view: WKWebView) {
            let config = WKFindConfiguration()
            config.caseSensitive = false
            config.backwards = request.direction == .backward
            // Wrap behavior is the default for WKFindConfiguration
            // (matches user expectations from Safari + every
            // other Mac app). No need to set explicitly.
            suppressScrollReports = true
            view.find(request.query, configuration: config) { [weak self] result in
                DispatchQueue.main.async {
                    self?.onFindResult?(result.matchFound)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.suppressScrollReports = false
            }
        }

        /// Turn a Swift String into a safely-escaped JS string
        /// literal. Avoids the brittleness of hand-escaping quotes
        /// across two languages.
        private func stringLiteral(_ s: String) -> String {
            let data = (try? JSONSerialization.data(
                withJSONObject: [s], options: []
            )) ?? Data("[\"\"]".utf8)
            let str = String(data: data, encoding: .utf8) ?? "[\"\"]"
            return String(str.dropFirst().dropLast())
        }
    }
}

/// WKWebView subclass that injects three reader-specific items
/// at the top of the right-click menu when text is selected:
/// Highlight, Add Note…, Copy with Citation. System items
/// (Copy, Look Up, etc.) stay below. When no selection is
/// active the menu falls through to WebKit's default.
///
/// `hasSelection` is set by the Coordinator on every
/// `selectionchange` event so `willOpenMenu(_:with:)` can decide
/// synchronously without a JS round-trip. The closures route
/// each click back to ReaderView's @State requests via the
/// Coordinator, mirroring how the toolbar buttons fire them.
final class ReaderWKWebView: WKWebView {
    /// Cached selection state — true when the user has a non-
    /// empty text selection in the document. Kept in sync by the
    /// Coordinator's `selectionchange` message handler.
    var hasSelection: Bool = false

    /// "Highlight" menu-item action. Fires `highlightRequest` on
    /// ReaderView with `openNoteEditor: false`.
    var onContextHighlight: (() -> Void)?
    /// "Add Note…" menu-item action. Fires `highlightRequest`
    /// on ReaderView with `openNoteEditor: true` so the note
    /// editor opens immediately after the wrap completes.
    var onContextAddNote: (() -> Void)?
    /// "Copy with Citation" menu-item action. Bumps the
    /// `copyCitationRequest` nonce, identical to the toolbar
    /// + ⇧⌘C path.
    var onContextCopyCitation: (() -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // Only show annotation items when the user has actually
        // selected text. Right-clicking on whitespace or an
        // image falls through to the default menu.
        guard hasSelection else { return }

        // Three items + separator, inserted in reverse so the
        // final order at the top is: Highlight, Add Note…,
        // Copy with Citation, ──, [system items…].
        let separator = NSMenuItem.separator()
        let cite = NSMenuItem(
            title: "Copy with Citation",
            action: #selector(humanistContextCopyCitation(_:)),
            keyEquivalent: "C"
        )
        cite.keyEquivalentModifierMask = [.command, .shift]
        cite.target = self

        let addNote = NSMenuItem(
            title: "Add Note…",
            action: #selector(humanistContextAddNote(_:)),
            keyEquivalent: ""
        )
        addNote.target = self

        let highlight = NSMenuItem(
            title: "Highlight",
            action: #selector(humanistContextHighlight(_:)),
            keyEquivalent: "h"
        )
        highlight.keyEquivalentModifierMask = [.command, .control]
        highlight.target = self

        menu.insertItem(separator, at: 0)
        menu.insertItem(cite, at: 0)
        menu.insertItem(addNote, at: 0)
        menu.insertItem(highlight, at: 0)
    }

    @objc private func humanistContextHighlight(_ sender: Any?) {
        onContextHighlight?()
    }
    @objc private func humanistContextAddNote(_ sender: Any?) {
        onContextAddNote?()
    }
    @objc private func humanistContextCopyCitation(_ sender: Any?) {
        onContextCopyCitation?()
    }
}
