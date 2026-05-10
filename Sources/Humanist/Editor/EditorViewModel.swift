import Foundation
import SwiftUI
import AppKit
import Document
import EPUB
import OCR
import PDFKit
import Pipeline
import UniformTypeIdentifiers

/// Per-window state for the EPUB editor: the open package + which file
/// the user is looking at + in-memory edit buffers + save action.
///
/// Edit model: when a file is first selected, its contents are read
/// from disk into an in-memory buffer. Subsequent edits update the
/// buffer; navigating away keeps it. Save flushes every dirty buffer
/// back to the working directory and re-zips it into the source EPUB.
/// One of the three central panes in the editor window. Used by the
/// VM and menu commands to address pane visibility uniformly.
enum EditorPane: String, CaseIterable {
    case pdf, source, wysiwyg, preview, chat
}

@MainActor
final class EditorViewModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum SaveState: Equatable {
        case idle
        case saving
        case failed(String)
    }

    @Published private(set) var state: LoadState = .loading
    @Published private(set) var saveState: SaveState = .idle
    /// In-memory representation of the open EPUB. Single source of
    /// truth for OPF metadata, manifest, spine, and per-resource
    /// (chapter / nav / CSS) text content. Edits run against the book
    /// in memory; `EPUBBookSaver.save(_:)` flushes them atomically.
    /// The book also owns the unpacked working directory's lifecycle
    /// (cleaned up on deinit unless ownership is handed off via
    /// `disownWorkingDirectory()`).
    @Published private(set) var book: EPUBBook?
    /// File-tree rooted at the book's working directory. Drives the
    /// sidebar. Rebuilt on open and after every chapter operation
    /// that adds / removes / renames files; the book itself doesn't
    /// hold the tree because the tree includes content outside the
    /// EPUB manifest (META-INF, sidecar files, mimetype) that the
    /// book model doesn't represent.
    @Published private(set) var fileTree: FileNode?
    @Published private(set) var selectedFile: FileNode?
    /// True when at least one buffer differs from disk OR has been
    /// modified since the last successful repack.
    @Published private(set) var isDirty: Bool = false

    /// Editable text of the currently selected file. Bound directly
    /// to the source `TextEditor` — using a real `@Published` is the
    /// SwiftUI-friendly way to keep edits flowing through the view
    /// hierarchy. Updates also write through to `buffers` + dirty
    /// tracking so Save flushes the right files.
    @Published var sourceText: String = ""

    /// Bumps after each debounced write of the current source buffer
    /// to the working directory. The preview pane watches this to
    /// reload the WKWebView so edits show up live without a Save.
    @Published private(set) var previewVersion: Int = 0

    /// Per-file XML / XHTML validation errors collected on the last
    /// `save()`. Empty when everything parsed cleanly. Surfaces in
    /// the source-pane footer so a broken edit is visible immediately
    /// instead of after a reader rejects the EPUB.
    @Published private(set) var validationIssues: [URL: String] = [:]

    /// Source PDF associated with this EPUB, if any. Auto-detected
    /// from a sibling .pdf on open or attached explicitly via
    /// `attachSourcePDF`. Persisted in the sidecar so the link
    /// survives close + reopen.
    @Published private(set) var sourcePDFURL: URL?
    /// Lazily-built PDFKit controller for the embedded PDF pane.
    /// Reset whenever `sourcePDFURL` changes.
    @Published private(set) var pdfController: PDFViewerController?

    /// Page-anchor map written by the converter into
    /// `META-INF/com.humanist.pagemap.json`. Non-nil → linked
    /// navigation is active. Nil → editor opened a non-Humanist EPUB
    /// (or one that predates the anchor-emitting pipeline) and sync
    /// stays dormant.
    @Published private(set) var pageMap: PageMap?
    /// Paragraph-level bbox sidecar produced by the converter when
    /// a chapter has paragraph entries. Tier 9 / paragraph-level
    /// alignment Pass B. Nil when the EPUB doesn't carry a map
    /// (third-party EPUBs, or EPUBs from the page-OCR Sonnet path
    /// — that path doesn't yield per-paragraph PDF coordinates).
    /// Used (when present) to drive paragraph-precision PDF↔source
    /// alignment + the Re-OCR Current Paragraph command.
    @Published private(set) var paragraphMap: ParagraphMap?
    /// Cloud Phase 6 sidecar — every Haiku post-OCR cleanup decision
    /// from the conversion. Nil when the cleanup feature wasn't run
    /// or no regions tripped the trigger gate. Surfaces in the
    /// editor's "Correction Trail" sheet.
    @Published private(set) var correctionTrail: CorrectionTrail?
    /// Transient feedback for the trail panel — populated by
    /// `applyCorrection` / `revertCorrection` when an action runs (or
    /// fails to find a unique text match). UI clears it manually.
    @Published var correctionTrailMessage: String?
    /// Anchor id the preview pane should scroll to. Bumped (or rather
    /// replaced with a new value carrying the same id but a fresh
    /// sequence number) every time we want the preview to re-scroll,
    /// so consecutive PDF page changes that map to the same anchor
    /// still register.
    @Published private(set) var scrollPreviewToAnchor: AnchorScrollRequest?
    /// Same shape, but routed to the CodeMirror source pane so the
    /// editor jumps to (and briefly flashes) the matching anchor in
    /// the XHTML. Driven by both the PDF-page-change observer and the
    /// preview-IntersectionObserver back-sync — the source pane
    /// follows whichever pane the user is steering with.
    @Published private(set) var scrollCodeToAnchor: AnchorScrollRequest?

    /// `hu-page-N` anchor the CodeMirror cursor currently sits inside
    /// (or `nil` until the file's first cursor activity). Used by
    /// "Re-OCR Current Page With…" to pick which PDF page to re-OCR
    /// based on what the user is reading in the source pane, not what
    /// they selected in the PDF, and by the explicit "Align Others
    /// to Source Cursor" command. Updated passively — the source
    /// pane never drives the others without an explicit command.
    @Published private(set) var currentSourceAnchor: String?
    /// Topmost `hu-page-N` anchor visible in the rendered preview.
    /// Updated passively by the IntersectionObserver bridge; consumed
    /// by the "Align Others to Preview Top" command. Nil before the
    /// preview has reported its first IO event.
    @Published private(set) var currentPreviewAnchor: String?
    /// Topmost `hu-p-{ch}-{para}` paragraph anchor in the source
    /// pane (where the cursor sits). Updated passively from the
    /// CodeMirror cursor change events. Drives the paragraph-level
    /// source ↔ preview snap when the user invokes
    /// "Align Others to Source Cursor".
    @Published private(set) var currentSourceParagraphAnchor: String?
    /// Topmost paragraph anchor visible in the rendered preview.
    /// Same shape as `currentPreviewAnchor` but at finer
    /// granularity; reported by the JS IntersectionObserver
    /// alongside the page-level anchor.
    @Published private(set) var currentPreviewParagraphAnchor: String?
    /// Last PDF page the embedded PDFView reported. Updated passively
    /// from `PDFViewPageChanged`; consumed by "Align Others to PDF
    /// Page". Nil before the user has navigated the PDF.
    @Published private(set) var currentPDFPage: Int?

    /// Tagged anchor scroll request — the `nonce` lets the preview
    /// pane's `onChange(of:)` fire even when the same anchor is
    /// targeted twice in a row (because the user clicked away in the
    /// PDF and back).
    struct AnchorScrollRequest: Equatable {
        let anchorId: String
        let xhtmlFile: String
        let nonce: Int
    }
    private var scrollNonce: Int = 0

    /// Re-OCR result the source-pane sheet shows. Non-nil ⇒ sheet is
    /// presented. The sheet is dismissed by setting this back to nil.
    @Published var reOCRResult: ReOCRResult?

    /// "Replace in Source" requests from the Re-OCR sheet. Bumped
    /// every time the user clicks the button; CodeEditorView watches
    /// the nonce and pushes the text into CodeMirror via the JS
    /// bridge.
    @Published private(set) var replaceSourceRequest: ReplaceSourceRequest?

    struct ReplaceSourceRequest: Equatable {
        let text: String
        let nonce: Int
    }
    private var replaceNonce: Int = 0

    /// "Replace Page in Source" requests from the Re-OCR sheet —
    /// splices the text between two `hu-page-N` anchors in the
    /// chapter file via the JS bridge.
    @Published private(set) var replacePageRequest: ReplacePageRequest?

    struct ReplacePageRequest: Equatable {
        let anchorId: String
        let text: String
        let nonce: Int
    }
    private var replacePageNonce: Int = 0

    /// Source-pane formatting toolbar requests (Bold / Italic /
    /// Heading / list / link / etc.). Each click on a toolbar button
    /// bumps the nonce so identical actions in a row still fire.
    @Published private(set) var formatRequest: FormatRequest?

    struct FormatRequest: Equatable {
        let action: Action
        let nonce: Int

        /// Shapes the toolbar / Format / Insert / Edit menus produce:
        ///   * `wrap(opening, closing)` — wrap selection (or insert
        ///     paired tags at cursor). Most buttons use this.
        ///   * `wrapList(listType)` — wrap each non-empty selected
        ///     line as a `<li>`, surrounded by `<ul>` or `<ol>`.
        ///   * `insert(text)` — insert raw text at the cursor; used
        ///     by self-closing inserts like `<hr/>` and Special
        ///     Character picks.
        ///   * `transform(kind)` — casing transform on the selection
        ///     (UPPER / lower / Title / Sentence).
        ///   * `removeFormatting` — strip every tag inside the
        ///     selection, leaving the inner text.
        ///   * `closingTag` — close the most-recently-opened
        ///     unclosed tag at the cursor.
        ///   * `gotoLine(line)` — jump cursor to a 1-based line.
        ///   * `insertFootnote` — insert a noteref + matching aside
        ///     skeleton with the next available `fn-N` id.
        enum Action: Equatable {
            case wrap(opening: String, closing: String)
            case wrapList(listType: String)
            case insert(text: String)
            case transform(kind: TransformKind)
            case removeFormatting
            case closingTag
            case gotoLine(line: Int)
            case insertFootnote
        }

        /// Casing transforms `humanistTransformSelection` understands.
        /// Raw value is the JS-side kind string.
        enum TransformKind: String, Equatable {
            case upper, lower, title, sentence
        }
    }
    private var formatNonce: Int = 0

    /// Find / replace dispatch from the Edit menu — routes to one
    /// of the four CodeMirror search commands via the JS bridge.
    /// The default Edit > Find menu group SwiftUI synthesizes
    /// otherwise eats ⌘F before it reaches the WebView, so all
    /// four flow through here.
    @Published private(set) var searchRequest: SearchRequest?

    struct SearchRequest: Equatable {
        let kind: Kind
        let nonce: Int
        enum Kind: String, Equatable {
            case find, findNext, findPrev, replace
        }
    }
    private var searchNonce: Int = 0

    struct ReOCRResult: Identifiable, Equatable {
        let id: UUID
        let engine: ReOCREngineKind
        /// PDF pages the selection spanned. Used for the sheet title
        /// (e.g. "Re-OCR with Vision · Page 7").
        let pageRange: ClosedRange<Int>
        /// Plain-text version of the OCR result for display in the
        /// sheet (and the Copy button). For the PDF-selection path
        /// this is the raw engine output; for the page path it's the
        /// reflowed paragraphs joined with blank lines.
        let text: String
        /// Well-formed XHTML fragment for "Replace Page in Source".
        /// Nil for the PDF-selection path (which inserts `text` into
        /// the source pane's current selection without wrapping).
        let replacementXHTML: String?
        /// What the sheet's primary "Replace…" button should target.
        let replaceTarget: ReplaceTarget

        enum ReplaceTarget: Equatable {
            /// PDF-selection path — replace whatever's selected in
            /// the source pane (CodeMirror's `replaceSelection`).
            case sourceSelection
            /// Source-page path — replace everything between the
            /// matching `<span id="hu-page-N">` anchors in the
            /// current chapter file.
            case pageInSource(anchorId: String)
        }
    }

    /// In-memory edit buffers, keyed by absolute file URL. Populated
    /// when a file is selected. Survives navigation between files.
    private var buffers: [URL: String] = [:]
    /// URLs whose buffer differs from disk (subset of `buffers` keys).
    private var dirtyURLs: Set<URL> = []
    /// Editor-only metadata (currently just the source PDF link).
    /// Mutations flush to the working dir immediately and mark the
    /// package dirty so Save round-trips them into the .epub.
    private var sidecar: HumanistSidecar = HumanistSidecar()
    /// Set of selectedFile URLs whose buffer has been initialized.
    /// Distinguishes "haven't read this file yet" from "read and
    /// buffer is empty string" so the auto-loader doesn't repeatedly
    /// touch the disk.
    private var loadedFiles: Set<URL> = []
    /// Pending live-preview write. Cancelled and rescheduled on every
    /// keystroke so a burst of typing collapses into one disk write +
    /// one preview reload after the user pauses.
    private var livePreviewTask: Task<Void, Never>?
    /// Debounce window for the live-preview write. Long enough that
    /// fast typing doesn't churn the disk; short enough to feel live.
    private static let livePreviewDebounce: Duration = .milliseconds(300)

    /// Pane visibility state. Lives on the VM (rather than the View's
    /// `@SceneStorage`) so menu bar commands can read/toggle it via
    /// `@FocusedValue`. Persisted globally so the user's chosen layout
    /// carries across windows + launches.
    @Published var showPDFPane: Bool {
        didSet {
            UserDefaults.standard.set(showPDFPane, forKey: Self.defaultsKey(.pdf))
        }
    }
    @Published var showSourcePane: Bool {
        didSet {
            UserDefaults.standard.set(showSourcePane, forKey: Self.defaultsKey(.source))
        }
    }
    @Published var showPreviewPane: Bool {
        didSet {
            UserDefaults.standard.set(showPreviewPane, forKey: Self.defaultsKey(.preview))
        }
    }
    /// Rich WYSIWYG pane. Off by default — the source + preview
    /// combo is the well-trod editing path; users opt into the
    /// WYSIWYG view explicitly.
    @Published var showWYSIWYGPane: Bool {
        didSet {
            UserDefaults.standard.set(showWYSIWYGPane, forKey: Self.defaultsKey(.wysiwyg))
        }
    }
    /// Chat-with-book pane. Off by default — Cloud-only feature
    /// that costs API tokens per query.
    @Published var showChatPane: Bool {
        didSet {
            UserDefaults.standard.set(showChatPane, forKey: Self.defaultsKey(.chat))
        }
    }
    /// Per-book chat session. Lazy: created the first time the
    /// chat pane is shown so opening an EPUB stays cheap. Reset
    /// when the book is reloaded from disk.
    @Published private(set) var chatViewModel: BookChatViewModel?

    /// Absolute URL of the book's stylesheet inside the unpacked
    /// working directory. The WYSIWYG pane uses this to render
    /// chapter content with the same typography the EPUB reader
    /// will use. Returns nil before the book is loaded.
    var bookCSSURL: URL? {
        guard let book = book else { return nil }
        let url = book.workingDirectory
            .appendingPathComponent("OEBPS/css/book.css")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func defaultsKey(_ pane: EditorPane) -> String {
        "humanist.editor.show.\(pane.rawValue)"
    }

    private static func defaultPaneVisibility(_ pane: EditorPane) -> Bool {
        if let v = UserDefaults.standard.object(forKey: defaultsKey(pane)) as? Bool {
            return v
        }
        // WYSIWYG and Chat are opt-in (extra column eats horizontal
        // space; chat additionally costs API tokens). The others
        // are on by default.
        switch pane {
        case .wysiwyg, .chat: return false
        case .pdf, .source, .preview: return true
        }
    }

    func isPaneVisible(_ pane: EditorPane) -> Bool {
        switch pane {
        case .pdf:     return showPDFPane
        case .source:  return showSourcePane
        case .wysiwyg: return showWYSIWYGPane
        case .preview: return showPreviewPane
        case .chat:    return showChatPane
        }
    }

    func togglePane(_ pane: EditorPane) {
        switch pane {
        case .pdf:     showPDFPane.toggle()
        case .source:  showSourcePane.toggle()
        case .wysiwyg: showWYSIWYGPane.toggle()
        case .preview: showPreviewPane.toggle()
        case .chat:
            showChatPane.toggle()
            if showChatPane { ensureChatViewModel() }
        }
    }

    /// Build the chat view-model on first show. Recreated when
    /// `reloadBookFromDisk` runs so the chat sees the freshest
    /// chapter texts (and the keyword index re-builds against
    /// them).
    private func ensureChatViewModel() {
        guard chatViewModel == nil, let book = book else { return }
        chatViewModel = BookChatViewModel(book: book, epubURL: book.sourceURL)
    }

    init(epubURL: URL) {
        self.showPDFPane = Self.defaultPaneVisibility(.pdf)
        self.showSourcePane = Self.defaultPaneVisibility(.source)
        self.showWYSIWYGPane = Self.defaultPaneVisibility(.wysiwyg)
        self.showPreviewPane = Self.defaultPaneVisibility(.preview)
        self.showChatPane = Self.defaultPaneVisibility(.chat)
        Task { await self.load(epubURL: epubURL) }
    }

    /// Tear-down. Closing an editor window normally drops the last
    /// `@StateObject` reference to this VM, which fires deinit. We
    /// cancel the live-preview task and remove the PDFKit page-change
    /// observer here so neither survives the window — without these,
    /// each closed window leaves a notification closure (capturing
    /// the PDFView, which retains the PDFDocument) and a debounce
    /// task running in the background.
    deinit {
        livePreviewTask?.cancel()
        if let token = pdfPageObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func load(epubURL: URL) async {
        self.state = .loading
        do {
            let book = try await Task.detached(priority: .userInitiated) {
                try EPUBBook.open(epubURL: epubURL)
            }.value
            self.book = book
            self.fileTree = FileNode.walk(book.workingDirectory, spineOrder: book.spineURLOrder)
            self.state = .ready
            self.selectedFile = Self.preferredInitialSelection(
                in: book, fileTree: self.fileTree
            )
            self.loadSourceForSelectedFile()
            self.attachInitialSourcePDF(epubURL: epubURL, book: book)
            self.pageMap = PageMap.read(workingDirectory: book.workingDirectory)
            self.paragraphMap = ParagraphMap.read(
                workingDirectory: book.workingDirectory
            )
            self.correctionTrail = CorrectionTrail.read(
                workingDirectory: book.workingDirectory
            )
            // R-Custom-Styles: pick up the user's previously applied
            // styling (if any) from the book.css sentinel.
            self.loadBookStyle()
        } catch {
            self.state = .failed(error.localizedDescription)
        }
    }

    // MARK: - linked navigation (Phase 7.D, simplified to one-way)
    //
    // The three panes are independent. Each tracks its own current
    // location passively (cursor anchor / preview top anchor / PDF
    // page) but never auto-drives the others — that bidirectional
    // auto-sync was the source of two bugs (typing in the source
    // pane echoed through preview and yanked the cursor back; some
    // user-driven scrolls were swallowed by stale suppression flags).
    //
    // Cross-pane alignment is now an explicit user action via three
    // commands in the Document menu: "Align Others to Source
    // Cursor", "Align Others to PDF Page", "Align Others to Preview
    // Top". Each one drives the *other* two panes one-shot from the
    // named pane's current location. The driver pane itself is
    // never moved by these commands, so they can't echo.
    //
    // Initial alignment on file switch (clicking a chapter in the
    // browser) still happens — that's a one-shot align, not the
    // continuous sync we removed.

    /// Token for the PDF-page-change observer. Now used only to
    /// keep `currentPDFPage` up to date for the alignment commands;
    /// no cross-pane drive happens from this notification.
    /// `nonisolated(unsafe)` is honest here: the token is opaque
    /// (used only as a key for `removeObserver`), set once on the
    /// main actor, and read only from this view-model's deinit
    /// (which is nonisolated by default in Swift 6). No race exists
    /// even in principle.
    private nonisolated(unsafe) var pdfPageObserver: (any NSObjectProtocol)?

    private func observePDFPageChanges() {
        if let token = pdfPageObserver {
            NotificationCenter.default.removeObserver(token)
        }
        guard let pdfView = pdfController?.pdfView else { return }
        pdfPageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let page = pdfView.currentPage,
                      let pdfPage = pdfView.document?.index(for: page)
                else { return }
                self.currentPDFPage = pdfPage
            }
        }
    }

    /// CodeMirror-side cursor-anchor reporter. Passive — just keeps
    /// `currentSourceAnchor` fresh. The cross-pane drive moved to
    /// `alignOthersToSourceCursor`.
    func didMoveCursorToAnchor(_ anchorId: String) {
        currentSourceAnchor = anchorId
    }

    /// Same shape, but for paragraph anchors (`hu-p-*`). Drives
    /// the paragraph-level source ↔ preview snap.
    func didMoveCursorToParagraph(_ paragraphId: String) {
        currentSourceParagraphAnchor = paragraphId
    }

    /// CodeMirror-side cursor-offset reporter. Updated on every
    /// cursor activity. Used by the Chapter Split command to pick a
    /// safe split boundary near the user's cursor.
    func didMoveCursor(offset: Int) {
        currentSourceCursorOffset = offset
    }

    /// Latest UTF-16 offset from the start of the source pane's
    /// document. Updated on every CodeMirror cursor activity. Nil
    /// when the editor hasn't reported a position yet.
    @Published private(set) var currentSourceCursorOffset: Int?

    /// Preview-IO callback. Passive — just keeps
    /// `currentPreviewAnchor` fresh. The cross-pane drive moved to
    /// `alignOthersToPreviewTop`.
    func didReportPreviewAnchor(_ anchorId: String) {
        currentPreviewAnchor = anchorId
    }

    /// Same shape, but for paragraph anchors (`hu-p-*`). Drives
    /// the paragraph-level source ↔ preview snap.
    func didReportPreviewParagraph(_ paragraphId: String) {
        currentPreviewParagraphAnchor = paragraphId
    }

    /// Scroll source + preview to the anchor that owns the cursor's
    /// current line in the source pane. PDF jumps to the
    /// corresponding page. The source pane itself is not touched —
    /// the cursor stays exactly where the user put it.
    func alignOthersToSourceCursor() {
        guard let anchorId = currentSourceAnchor else { return }
        alignOthers(to: anchorId, drivingPane: .source)
    }

    /// Scroll source + preview to the anchor for the PDF's
    /// currently-visible page. PDF stays put.
    func alignOthersToPDFPage() {
        guard let map = pageMap,
              let pdfPage = currentPDFPage,
              let entry = bestAnchor(for: pdfPage, in: map)
        else { return }
        alignOthers(to: entry.anchorId, drivingPane: .pdf)
    }

    /// Scroll source + PDF to the preview's topmost anchor. Preview
    /// stays put.
    func alignOthersToPreviewTop() {
        guard let anchorId = currentPreviewAnchor else { return }
        alignOthers(to: anchorId, drivingPane: .preview)
    }

    /// Programmatically navigate to a specific paragraph anchor —
    /// fired by chat citation chips when the citation carries a
    /// paragraph index. Selects the chapter file (if not already
    /// selected) and posts a scroll request to land both source +
    /// preview panes on `<p id="hu-p-{chapterIdx}-{paragraphIdx}">`.
    /// The PDF pane stays put; per-paragraph PDF coordinates aren't
    /// always available, and the chat path doesn't need them anyway.
    func requestParagraphScroll(resourceID: String, paragraphIdx: Int) {
        guard let book = book,
              let resource = book.resourcesByID[resourceID],
              let tree = fileTree,
              let chapterIdx = book.spine.firstIndex(of: resourceID)
        else { return }
        let url = book.absoluteURL(for: resource).canonicalForFile
        let anchorId = "hu-p-\(chapterIdx)-\(paragraphIdx)"
        // Switch chapter only when the citation points elsewhere.
        if selectedFile?.id.canonicalForFile != url,
           let node = Self.findLeaf(in: tree, matching: url) {
            select(node)
        }
        scrollNonce &+= 1
        let req = AnchorScrollRequest(
            anchorId: anchorId,
            xhtmlFile: resource.hrefRelativeToOPF,
            nonce: scrollNonce
        )
        scrollPreviewToAnchor = req
        scrollCodeToAnchor = req
    }

    /// One-shot alignment to a chapter file's first page anchor —
    /// called when the user clicks a chapter in the file-tree
    /// sidebar so the user lands in the right place across all
    /// three panes.
    func alignAllToCurrentFile() {
        guard let book = book, let file = selectedFile else { return }
        guard let map = pageMap else { return }
        let prefix = book.workingDirectory.canonicalForFile.path
        let fileRel = file.id.canonicalForFile.path
            .replacingOccurrences(of: prefix + "/", with: "")
        guard let entry = map.entries.first(where: { $0.xhtmlFile == fileRel })
        else { return }
        alignOthers(to: entry.anchorId, drivingPane: .none)
    }

    /// Drives PDF + preview + source as appropriate for `to`,
    /// skipping whichever pane is the driver (that pane is the
    /// authoritative source of the anchor and shouldn't be moved).
    /// `.none` updates all three (used for file-switch initial
    /// alignment).
    private func alignOthers(to anchorId: String, drivingPane: AlignmentDriver) {
        guard let map = pageMap, let book = book, let tree = fileTree else { return }
        guard let entry = map.entries.first(where: { $0.anchorId == anchorId })
        else { return }
        // File switch when the anchor lives in a different chapter
        // than the current selection. Always allowed — switching
        // file isn't really "driving the source pane", it's
        // selecting which file the source pane shows.
        let fileURL = book.workingDirectory
            .appendingPathComponent(entry.xhtmlFile)
            .canonicalForFile
        if selectedFile?.id.canonicalForFile != fileURL,
           let node = Self.findLeaf(in: tree, matching: fileURL) {
            select(node)
        }
        scrollNonce &+= 1
        // Pass A of paragraph-level alignment: when source ↔ preview
        // are both within the same chapter as the page anchor we're
        // aligning to, prefer the finer-grained paragraph anchor
        // for the source / preview scroll request — lands on the
        // exact paragraph the user is editing rather than the top
        // of the page. Driver pane reports its own paragraph
        // anchor; the other panes scroll to that. PDF stays page-
        // granularity since paragraph bbox isn't available yet
        // (Pass B).
        let preferredAnchorId: String
        switch drivingPane {
        case .source:
            preferredAnchorId = currentSourceParagraphAnchor ?? entry.anchorId
        case .preview:
            preferredAnchorId = currentPreviewParagraphAnchor ?? entry.anchorId
        case .pdf, .none:
            preferredAnchorId = entry.anchorId
        }
        let req = AnchorScrollRequest(
            anchorId: preferredAnchorId,
            xhtmlFile: entry.xhtmlFile,
            nonce: scrollNonce
        )
        if drivingPane != .preview {
            scrollPreviewToAnchor = req
        }
        if drivingPane != .source {
            scrollCodeToAnchor = req
        }
        if drivingPane != .pdf,
           let pdfView = pdfController?.pdfView,
           let document = pdfView.document,
           entry.pdfPage >= 0, entry.pdfPage < document.pageCount,
           let page = document.page(at: entry.pdfPage),
           pdfView.currentPage !== page {
            pdfView.go(to: page)
        }
    }

    /// Identifier for "which pane is driving" — used by `alignOthers`
    /// to skip moving the driver pane. `.none` means an external
    /// trigger (file-switch initial align) and all three should
    /// update. Distinct from the file-level `EditorPane` enum
    /// (which controls pane visibility): this one identifies the
    /// authoritative source of an alignment action.
    enum AlignmentDriver: Sendable, Equatable {
        case source, pdf, preview, none
    }

    // MARK: - re-OCR selection (menu enrichment)

    enum ReOCRError: LocalizedError {
        case noPDFAttached
        case noSelection
        case noSourceAnchor
        case engineUnavailable(ReOCREngineKind)
        case renderFailed
        case ocrFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPDFAttached:
                return "No source PDF is attached to this EPUB."
            case .noSelection:
                return "Select text in the PDF pane first, then re-OCR."
            case .noSourceAnchor:
                return "Move the source-pane cursor into a Humanist-converted page (look for `<span id=\"hu-page-…\">` markers), then try again."
            case .engineUnavailable(let kind):
                return "\(kind.displayName) is not installed on this machine."
            case .renderFailed:
                return "Could not render the selection from the PDF."
            case .ocrFailed(let s):
                return "OCR failed: \(s)"
            }
        }
    }

    /// Render the user's current PDF selection at high DPI, run it
    /// through the chosen engine, and surface the result in the
    /// re-OCR sheet (`reOCRResult`). Throws `ReOCRError` if there's
    /// no selection or the engine isn't installed; otherwise returns
    /// silently after publishing the result.
    func reOCRSelection(engine kind: ReOCREngineKind) async throws {
        guard pdfController != nil else { throw ReOCRError.noPDFAttached }
        guard let selection = pdfController?.pdfView.currentSelection,
              !selection.pages.isEmpty
        else { throw ReOCRError.noSelection }
        guard kind.isAvailable, let engine = kind.makeEngine() else {
            throw ReOCRError.engineUnavailable(kind)
        }

        // Selection can span pages — OCR each page's slice and
        // concatenate. Track page indices for the sheet title.
        var combined: [String] = []
        var firstPage = Int.max, lastPage = Int.min
        for page in selection.pages {
            let bounds = selection.bounds(for: page)
            guard let image = PDFRegionRenderer.render(page: page, region: bounds)
            else { throw ReOCRError.renderFailed }
            let hints = OCRHints(
                languages: selectedBCP47Languages(),
                quality: .accurate
            )
            do {
                let result = try await engine.recognize(image: image, hints: hints)
                combined.append(formatObservations(result.observations))
            } catch {
                throw ReOCRError.ocrFailed(String(describing: error))
            }
            if let pageIndex = page.document?.index(for: page) {
                firstPage = min(firstPage, pageIndex)
                lastPage = max(lastPage, pageIndex)
            }
        }

        let text = combined.joined(separator: "\n\n")
        let range: ClosedRange<Int>
        if firstPage <= lastPage {
            range = firstPage...lastPage
        } else {
            range = 0...0
        }
        reOCRResult = ReOCRResult(
            id: UUID(), engine: kind, pageRange: range,
            text: text, replacementXHTML: nil,
            replaceTarget: .sourceSelection
        )
    }

    /// Re-OCR the entire PDF page that contains the cursor in the
    /// source pane. Runs the same render + layout + region-aware
    /// reflow that the bulk converter does, so the result preserves
    /// columns, paragraph reflow, header/footer suppression, and
    /// dehyphenation — not raw line-by-line OCR.
    ///
    /// Pulls the source PDF from the editor's attached `pdfController`
    /// rather than re-loading it through PDFKit, so the URL in scope
    /// is whatever the user attached (sidecar lookup, sibling
    /// detection, manual override).
    func reOCRCurrentSourcePage(engine kind: ReOCREngineKind) async throws {
        guard let sourcePDFURL else { throw ReOCRError.noPDFAttached }

        // Find the anchor the source cursor is in. Fall back to the
        // first anchor in the currently-selected file if the cursor
        // hasn't reported one yet (e.g. file just opened).
        let anchorId = currentSourceAnchor
            ?? firstAnchorIdInSelectedFile()
        guard let anchorId,
              let entry = pageMap?.entries.first(where: { $0.anchorId == anchorId })
        else { throw ReOCRError.noSourceAnchor }

        guard kind.isAvailable, let engine = kind.makeEngine() else {
            throw ReOCRError.engineUnavailable(kind)
        }

        let langs = selectedBCP47Languages()
        let pipeline = PDFToEPUBPipeline()
        let docLanguage = book?.metadata.language
            .flatMap { BCP47(rawValue: $0) } ?? langs.first ?? .en

        do {
            let result = try await pipeline.reOCRSinglePage(
                pdfURL: sourcePDFURL,
                pageIndex: entry.pdfPage,
                engine: engine,
                languages: langs
            )
            // Drop the leading page-anchor block from the reflow
            // output — the source already has that anchor; only the
            // body content gets spliced in between consecutive
            // anchors.
            let bodyBlocks = result.blocks.filter {
                if case .anchor = $0 { return false } else { return true }
            }
            let displayText = paragraphPlainText(bodyBlocks)
            let xhtml = XHTMLFragmentRenderer.render(
                blocks: bodyBlocks, language: docLanguage
            )
            reOCRResult = ReOCRResult(
                id: UUID(), engine: kind,
                pageRange: entry.pdfPage...entry.pdfPage,
                text: displayText, replacementXHTML: xhtml,
                replaceTarget: .pageInSource(anchorId: anchorId)
            )
        } catch {
            throw ReOCRError.ocrFailed(String(describing: error))
        }
    }

    /// Join paragraph / heading blocks into a plain-text view for
    /// display in the Re-OCR sheet. Anchors are skipped (they're
    /// invisible in the rendered output anyway). Figures contribute
    /// only their caption text — the image itself isn't representable
    /// in a plain-text preview. Tables flatten to caption + rows
    /// joined by tabs / newlines so the user can still read them.
    private func paragraphPlainText(_ blocks: [Block]) -> String {
        var lines: [String] = []
        for block in blocks {
            switch block {
            case .heading(_, let runs):
                lines.append(runs.map(\.text).joined())
            case .paragraph(let runs):
                lines.append(runs.map(\.text).joined())
            case .figure(_, _, let caption):
                let text = caption.map(\.text).joined()
                if !text.isEmpty { lines.append(text) }
            case .table(let rows, let caption):
                let captionText = caption.map(\.text).joined()
                if !captionText.isEmpty { lines.append(captionText) }
                let rowLines = rows.map { row in
                    row.map { $0.runs.map(\.text).joined() }.joined(separator: "\t")
                }
                if !rowLines.isEmpty {
                    lines.append(rowLines.joined(separator: "\n"))
                }
            case .anchor:
                continue
            }
        }
        return lines.joined(separator: "\n\n")
    }

    /// First `hu-page-*` anchor whose pagemap entry points at the
    /// currently selected file. Used as a fallback when the source
    /// cursor hasn't fired a cursor-anchor message yet.
    private func firstAnchorIdInSelectedFile() -> String? {
        guard let book = book, let map = pageMap, let file = selectedFile else {
            return nil
        }
        let prefix = book.workingDirectory.canonicalForFile.path
        let fileRel = file.id.canonicalForFile.path
            .replacingOccurrences(of: prefix + "/", with: "")
        return map.entries.first(where: { $0.xhtmlFile == fileRel })?.anchorId
    }

    /// "Replace Page in Source" — bumps the publish nonce so
    /// CodeEditorView pushes the splice through the JS bridge.
    func replacePageInSource(anchorId: String, text: String) {
        replacePageNonce &+= 1
        replacePageRequest = ReplacePageRequest(
            anchorId: anchorId, text: text, nonce: replacePageNonce
        )
    }

    /// Map the EPUB's metadata language to a BCP-47 list for the
    /// engine. Vision and Surya read these as recognition hints;
    /// Tesseract uses them to load tessdata.
    private func selectedBCP47Languages() -> [BCP47] {
        if let raw = book?.metadata.language,
           let bcp = BCP47(rawValue: raw) {
            return [bcp]
        }
        return [.en]
    }

    /// Sort observations top-to-bottom, then left-to-right within a
    /// row (small Y tolerance), and join their text. Matches what the
    /// converter does internally; the user can paste the result
    /// directly into the source pane.
    private func formatObservations(_ obs: [TextObservation]) -> String {
        let sorted = obs.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > 0.005 { return a.box.midY > b.box.midY }
            return a.box.minX < b.box.minX
        }
        return sorted
            .map { $0.text }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - PDF pane navigation

    /// True when the embedded PDF pane has a document loaded — used
    /// by menu / toolbar to enable PDF zoom + page-nav commands.
    var canNavigatePDF: Bool {
        pdfController?.pdfView.document != nil
    }

    /// Push `text` into the source pane, replacing the current
    /// selection (or inserting at the caret if there's none). Used
    /// by the Re-OCR sheet's "Replace in Source" button.
    // MARK: - Bulk Re-OCR (V-Refresh)

    /// V-Refresh "Re-OCR All Pages" coordinator. Holds its own
    /// `@Published progress` + `confirmation` and walks the page
    /// map; lifted out of the VM so this file stays focused on
    /// file/buffer/save state. See `BulkReOCRCoordinator.swift`.
    private(set) lazy var bulkReOCR: BulkReOCRCoordinator = {
        BulkReOCRCoordinator(vm: self)
    }()

    /// Convenience for the coordinator: snapshot of the user's
    /// current language picker for use in re-OCR calls.
    func languagesForReOCR() -> [BCP47] {
        selectedBCP47Languages()
    }

    /// Post-save callback the coordinator fires after a successful
    /// bulk write. Refreshes the file tree, reloads the selected
    /// file from disk, bumps the preview version, and marks the
    /// package dirty so the editor reflects the new contents.
    func didCompleteBulkReOCR() {
        refreshFileTree()
        reloadSelectedFileFromDisk()
        previewVersion += 1
        isDirty = true
    }

    func replaceSourceSelection(with text: String) {
        replaceNonce &+= 1
        replaceSourceRequest = ReplaceSourceRequest(text: text, nonce: replaceNonce)
    }

    // MARK: - Source-pane formatting toolbar (Phase 7+)

    /// Wrap the current selection in `opening` / `closing`, or
    /// insert paired tags at the cursor when no selection. Backbone
    /// for Bold, Italic, Heading, Blockquote, Code, Sup/Sub.
    func formatWrap(opening: String, closing: String) {
        formatNonce &+= 1
        formatRequest = FormatRequest(
            action: .wrap(opening: opening, closing: closing),
            nonce: formatNonce
        )
    }

    /// Wrap the current selection (line by line) as a list of the
    /// requested type ("ul" or "ol"). Empty lines drop out; nothing
    /// selected → inserts an empty single-item list.
    func formatList(_ listType: String) {
        formatNonce &+= 1
        formatRequest = FormatRequest(
            action: .wrapList(listType: listType),
            nonce: formatNonce
        )
    }

    /// Insert raw `text` at the cursor (replacing selection if any).
    /// Used for self-closing tag inserts — `<hr/>`, etc.
    func formatInsert(_ text: String) {
        formatNonce &+= 1
        formatRequest = FormatRequest(
            action: .insert(text: text),
            nonce: formatNonce
        )
    }

    /// Wrap selection with `<a href="…">…</a>`. Selection becomes
    /// the link text; when empty, the URL is also used as the
    /// visible text.
    func formatLink(href: String) {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let escaped = Self.xhtmlEscape(trimmed)
        formatWrap(
            opening: "<a href=\"\(escaped)\">",
            closing: "</a>"
        )
    }

    /// Wrap selection in `<span xml:lang="…" lang="…">…</span>` —
    /// used to mark inline foreign-language text in academic books
    /// (Greek quotation in an English paragraph, etc.). Lang code
    /// gets the same dual-attribute treatment XHTMLWriter uses for
    /// per-run language tagging.
    func formatLanguageSpan(lang: String) {
        let trimmed = lang.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let escaped = Self.xhtmlEscape(trimmed)
        formatWrap(
            opening: "<span xml:lang=\"\(escaped)\" lang=\"\(escaped)\">",
            closing: "</span>"
        )
    }

    /// Apply a casing transform to the source pane's selection. No-op
    /// when nothing is selected (the JS bridge does the actual check).
    func formatTransform(_ kind: FormatRequest.TransformKind) {
        formatNonce &+= 1
        formatRequest = FormatRequest(
            action: .transform(kind: kind), nonce: formatNonce
        )
    }

    /// Strip every tag from the source pane's selection.
    func formatRemoveFormatting() {
        formatNonce &+= 1
        formatRequest = FormatRequest(
            action: .removeFormatting, nonce: formatNonce
        )
    }

    /// Insert a closing tag for the most-recently-opened unclosed tag
    /// at the cursor. Self-closing tags (`<br/>`, `<hr/>`) are skipped
    /// by the bridge.
    func insertClosingTag() {
        formatNonce &+= 1
        formatRequest = FormatRequest(
            action: .closingTag, nonce: formatNonce
        )
    }

    /// Insert a noteref + matching `<aside class="footnote">` skeleton
    /// with the next available `fn-N` id. The user fills in the body
    /// text.
    func insertFootnote() {
        formatNonce &+= 1
        formatRequest = FormatRequest(
            action: .insertFootnote, nonce: formatNonce
        )
    }

    /// Jump the source pane's cursor to a 1-based line number.
    /// Out-of-range numbers clamp at the bridge level.
    func gotoLine(_ line: Int) {
        formatNonce &+= 1
        formatRequest = FormatRequest(
            action: .gotoLine(line: line), nonce: formatNonce
        )
    }

    /// Open the source pane's find dialog (⌘F-equivalent).
    func openFind() { dispatchSearch(.find) }
    /// Move to the next find match (⌘G).
    func findNext() { dispatchSearch(.findNext) }
    /// Move to the previous find match (⇧⌘G).
    func findPrev() { dispatchSearch(.findPrev) }
    /// Open the find-and-replace dialog (⌥⌘F).
    func openReplace() { dispatchSearch(.replace) }

    private func dispatchSearch(_ kind: SearchRequest.Kind) {
        searchNonce &+= 1
        searchRequest = SearchRequest(kind: kind, nonce: searchNonce)
    }

    // MARK: - Document spell check (NSSpellChecker-driven)

    /// Active spell-check session, or nil when the panel is
    /// dismissed. The sheet observes this; setting non-nil
    /// presents the panel.
    @Published var spellCheckSession: SpellCheckSession?

    /// Drives the Insert > Special Character sheet. View-side toggle
    /// — `EditorView` watches this and presents the sheet when true.
    @Published var showSpecialCharacterPicker: Bool = false

    /// Drives the Edit > Goto Line sheet. Same pattern as
    /// `showSpecialCharacterPicker`.
    @Published var showGotoLineSheet: Bool = false

    /// Drives the Insert > Footnote Manager sheet.
    @Published var showFootnoteManager: Bool = false

    /// Drives the Document > Chapter Manager sheet.
    @Published var showChapterManager: Bool = false

    /// Incremented by `equalizePanes()` so `EditorView` knows to
    /// resize all visible panes to equal widths.
    @Published private(set) var equalizePanesSignal: Int = 0

    func equalizePanes() { equalizePanesSignal += 1 }

    /// Bumped after every successful `save()`. `WYSIWYGView` watches
    /// this and reloads its WebView if the body text changed since the
    /// last time the WYSIWYG was loaded — keeps the two panes in sync
    /// after Source-pane edits are saved.
    @Published private(set) var wysiwygReloadToken: Int = 0

    /// Read a chapter's text from the in-memory buffer (if modified)
    /// or from disk. Returns nil when the file can't be read.
    func readChapterText(_ url: URL) -> String? {
        let canonical = url.canonicalForFile
        if let buf = buffers[canonical] { return buf }
        return try? String(contentsOf: canonical, encoding: .utf8)
    }

    /// Write modified text for a chapter back into the buffer so
    /// Save will flush it. Also updates `sourceText` when the
    /// chapter is currently selected.
    func writeChapterText(_ text: String, to url: URL) {
        let canonical = url.canonicalForFile
        buffers[canonical] = text
        dirtyURLs.insert(canonical)
        isDirty = true
        if selectedFile?.id.canonicalForFile == canonical {
            sourceText = text
        }
    }

    // MARK: - Custom styles (R-Custom-Styles)

    /// Drives the Tools > Customize Style sheet. Same view-flag
    /// pattern as `showValidationSheet`.
    @Published var showStyleSheet: Bool = false

    /// User's per-book style choices. Loaded from the EPUB's
    /// `book.css` on open via the `humanist-style:` sentinel
    /// comment; nil when the EPUB predates this feature or carries
    /// no custom style. Editing the sheet's controls updates this
    /// in place; the user must hit "Apply" to flush a regenerated
    /// `book.css` into the working directory.
    @Published var bookStyle: BookStyle = .default

    /// Apply `bookStyle` to the EPUB's `book.css`: read the current
    /// CSS (if any), regenerate the override block + sentinel, and
    /// write the result through the dirty-buffer pipeline so
    /// Save flushes it into the EPUB. Bumps `previewVersion` so
    /// the WKWebView reloads with the new styling.
    ///
    /// Returns true on success; false when the EPUB has no
    /// `OEBPS/css/book.css` (atypical — books built by Humanist
    /// always have it, but a third-party EPUB might not). Caller
    /// surfaces a "stylesheet missing" error in that case.
    @discardableResult
    func applyBookStyle(_ style: BookStyle) -> Bool {
        guard let book = book else { return false }
        let cssURL = book.workingDirectory
            .appendingPathComponent("OEBPS/css/book.css")
            .canonicalForFile
        let existing: String?
        if let buffered = buffers[cssURL] {
            existing = buffered
        } else if let onDisk = try? String(contentsOf: cssURL, encoding: .utf8) {
            existing = onDisk
        } else {
            return false
        }
        let updated = BookCSSBuilder.apply(style: style, to: existing)
        buffers[cssURL] = updated
        dirtyURLs.insert(cssURL)
        bookStyle = style
        isDirty = true
        // Bump preview so the WKWebView reloads with the new CSS.
        previewVersion += 1
        return true
    }

    /// Read the persisted style from `book.css` on open. Mirrors
    /// the load path for other sidecar-shaped data (page map,
    /// correction trail). Defaults to `.default` when the CSS has
    /// no sentinel — the user just hasn't customized this book yet.
    func loadBookStyle() {
        guard let book = book else { return }
        let cssURL = book.workingDirectory
            .appendingPathComponent("OEBPS/css/book.css")
            .canonicalForFile
        guard let css = try? String(contentsOf: cssURL, encoding: .utf8) else {
            bookStyle = .default
            return
        }
        bookStyle = BookCSSBuilder.parse(css) ?? .default
    }

    // MARK: - EPUB validation (Phase 5b)

    /// Drives the Tools > Validate EPUB sheet.
    @Published var showValidationSheet: Bool = false

    /// Last validation report, or nil when validation hasn't run
    /// yet.
    @Published var validationReport: EPUBValidator.Report?

    /// Last validation error message (e.g. "epubcheck not
    /// installed"), or nil when the last run succeeded.
    @Published var validationError: String?

    /// True while validation is mid-flight.
    @Published var isValidating: Bool = false

    /// Save the EPUB if dirty, then run epubcheck against the
    /// on-disk file. Mutates `validationReport` / `validationError`
    /// as a side effect; the sheet observes those.
    func validateEPUB() async {
        guard let book = book else { return }
        // Save first if dirty — validation always runs against the
        // on-disk file so the user sees what readers will see.
        if isDirty {
            await save()
            // If save failed, surface that error and bail.
            if case .failed(let msg) = saveState {
                validationError = "Couldn't save before validation: \(msg)"
                showValidationSheet = true
                return
            }
        }
        let epubURL = book.sourceURL
        isValidating = true
        validationError = nil
        validationReport = nil
        showValidationSheet = true
        let report: EPUBValidator.Report?
        let errorMsg: String?
        do {
            let r = try await Task.detached(priority: .userInitiated) {
                try EPUBValidator().validate(epubURL: epubURL)
            }.value
            report = r
            errorMsg = nil
        } catch {
            report = nil
            errorMsg = error.localizedDescription
        }
        isValidating = false
        validationReport = report
        validationError = errorMsg
    }

    /// Open the file referenced by a validation message and jump to
    /// its line. epubcheck reports paths relative to the EPUB root
    /// (e.g. `OEBPS/chapter-001.xhtml`); resolve against the working
    /// dir and find the matching FileNode.
    func openValidationMessage(_ message: EPUBValidator.Message) {
        guard let book = book, let tree = fileTree,
              let path = message.path, !path.isEmpty
        else { return }
        let absolute = book.workingDirectory
            .appendingPathComponent(path)
            .canonicalForFile
        if let node = Self.findNode(in: tree, url: absolute) {
            select(node)
            if let line = message.line {
                DispatchQueue.main.async { [weak self] in
                    self?.gotoLine(line)
                }
            }
        }
    }

    // MARK: - Find in Files (Phase 5b)

    /// Drives the Search > Find in Files sheet.
    @Published var showFindInFilesSheet: Bool = false

    @Published var findInFilesQuery: String = ""
    @Published var findInFilesReplaceText: String = ""
    @Published var findInFilesCaseSensitive: Bool = false
    @Published var findInFilesRegex: Bool = false
    @Published var findInFilesResults: [PackageSearch.Hit] = []
    /// Last error from the find/replace engine (typically a regex
    /// parse failure). Surfaced inline in the sheet, not as an
    /// alert.
    @Published var findInFilesError: String?
    /// "Replaced N matches in M files" status, set after a successful
    /// Replace All. The sheet shows it briefly; nil otherwise.
    @Published var findInFilesReplaceStatus: String?

    /// Run the current find query across every text-bearing file in
    /// the working directory. Reads dirty buffers when present so
    /// in-flight edits are part of the search.
    func runFindInFiles() {
        guard let book = book else {
            findInFilesResults = []
            return
        }
        flushSourceTextToBuffer()
        let urls = PackageSearch.textFileURLs(in: book.workingDirectory)
        let buffersCopy = buffers
        let provider: (URL) -> String? = { url in
            if let buf = buffersCopy[url] { return buf }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        do {
            findInFilesError = nil
            findInFilesReplaceStatus = nil
            findInFilesResults = try PackageSearch().search(
                in: urls,
                query: findInFilesQuery,
                caseSensitive: findInFilesCaseSensitive,
                regex: findInFilesRegex,
                contentProvider: provider
            )
        } catch {
            findInFilesError = error.localizedDescription
            findInFilesResults = []
        }
    }

    /// Replace every match across every text-bearing file. Updated
    /// content lands in the in-memory buffer + dirty set so the
    /// user's next Save flushes it. Re-runs the search after so the
    /// results list reflects the new state (typically empty when
    /// query and replacement don't overlap).
    func replaceAllInFiles() {
        guard let book = book else { return }
        flushSourceTextToBuffer()
        let urls = PackageSearch.textFileURLs(in: book.workingDirectory)
        let buffersCopy = buffers
        let provider: (URL) -> String? = { url in
            if let buf = buffersCopy[url] { return buf }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        do {
            let results = try PackageSearch().replaceAll(
                in: urls,
                query: findInFilesQuery,
                replacement: findInFilesReplaceText,
                caseSensitive: findInFilesCaseSensitive,
                regex: findInFilesRegex,
                contentProvider: provider
            )
            var totalReplacements = 0
            for r in results {
                buffers[r.fileURL] = r.newContent
                dirtyURLs.insert(r.fileURL)
                totalReplacements += r.replacementCount
                // If the user is currently editing this file, push
                // the new content into the live source-text binding
                // so the editor reflects the replacement immediately.
                if r.fileURL == selectedFile?.id {
                    sourceText = r.newContent
                }
            }
            isDirty = isDirty || !results.isEmpty
            findInFilesError = nil
            let fileCount = results.count
            findInFilesReplaceStatus = totalReplacements == 0
                ? "No matches found."
                : "Replaced \(totalReplacements) match\(totalReplacements == 1 ? "" : "es") in \(fileCount) file\(fileCount == 1 ? "" : "s")."
            // Re-run search so the results list reflects the new
            // state.
            runFindInFiles()
        } catch {
            findInFilesError = error.localizedDescription
        }
    }

    /// Open the file containing `hit` and jump the source pane's
    /// cursor to the hit's line. Doesn't dismiss the find sheet —
    /// the user typically clicks several results in a row.
    func openFindHit(_ hit: PackageSearch.Hit) {
        // Find the FileNode in the tree matching the hit's URL.
        guard let tree = fileTree else { return }
        if let node = Self.findNode(in: tree, url: hit.fileURL) {
            select(node)
        }
        // Defer the goto-line dispatch by one runloop so the file
        // switch + content push lands first.
        let line = hit.line
        DispatchQueue.main.async { [weak self] in
            self?.gotoLine(line)
        }
    }

    private static func findNode(in node: FileNode, url: URL) -> FileNode? {
        if node.id.canonicalForFile.path == url.canonicalForFile.path {
            return node
        }
        guard let children = node.children else { return nil }
        for child in children {
            if let hit = findNode(in: child, url: url) { return hit }
        }
        return nil
    }

    /// Run a fresh `NSSpellChecker` pass over the current source
    /// text and present the document-spelling sheet. Misspellings
    /// inside XHTML tags (attribute values, element names) are
    /// filtered out by the session's tag-aware walker.
    func openSpellCheck() {
        let session = SpellCheckSession()
        session.scan(text: sourceText)
        spellCheckSession = session
    }

    /// Apply a replacement at the spell-check session's current
    /// cursor, then refresh the session against the updated source.
    /// The whole-buffer assignment piggybacks on the standard
    /// `sourceText` change path so dirty tracking + CodeMirror
    /// re-push happen automatically.
    func applySpellingReplacement(_ replacement: String) {
        guard let session = spellCheckSession,
              let updated = session.applyReplacement(
                  replacement, to: sourceText
              )
        else { return }
        sourceText = updated
        session.scan(text: sourceText)
    }

    /// Replace straight quotes / apostrophes with typographic curly
    /// equivalents in the loaded source text. `SmartQuoter` walks
    /// the XHTML and only transforms characters outside tags, so
    /// attribute values and the document's structural quoting
    /// stay byte-stable.
    ///
    /// Whole-buffer assignment (rather than going through the JS
    /// bridge for a per-character transform) — preserves the user's
    /// existing CodeMirror cursor position approximately, and the
    /// existing dirty-tracking + buffer-flush machinery picks the
    /// edit up via the standard `sourceText` change path.
    func smartQuoteSourceText() {
        let updated = SmartQuoter.smartQuote(sourceText)
        guard updated != sourceText else { return }
        sourceText = updated
    }

    // MARK: - Correction trail actions (Cloud Phase 6)

    /// Switch the editor's selected file to the XHTML chapter that
    /// owns this trail entry (per the pagemap join), and scroll the
    /// source pane to the entry's page anchor. Returns `true` when
    /// the navigation succeeded — `false` when the pagemap doesn't
    /// resolve the entry's anchor (which would mean the trail and
    /// pagemap got out of sync, shouldn't happen in practice).
    @discardableResult
    func revealInSource(entry: CorrectionTrail.Entry) -> Bool {
        guard let book = book, let tree = fileTree, let map = pageMap else { return false }
        guard let mapEntry = map.entries.first(
            where: { $0.anchorId == entry.anchorId }
        ) else { return false }
        let fileURL = book.workingDirectory
            .appendingPathComponent(mapEntry.xhtmlFile)
            .canonicalForFile
        if selectedFile?.id.canonicalForFile != fileURL,
           let node = Self.findLeaf(in: tree, matching: fileURL) {
            select(node)
        }
        scrollNonce &+= 1
        scrollCodeToAnchor = AnchorScrollRequest(
            anchorId: mapEntry.anchorId,
            xhtmlFile: mapEntry.xhtmlFile,
            nonce: scrollNonce
        )
        return true
    }

    /// Apply the trail entry's suggested correction. Used for entries
    /// the guardrail rejected — the source currently has the original
    /// text and the user wants Haiku's suggestion instead.
    func applyCorrection(_ entry: CorrectionTrail.Entry) {
        revealInSource(entry: entry)
        replaceInLoadedSource(
            find: entry.original,
            with: entry.suggested,
            actionLabel: "apply"
        )
    }

    /// Revert the trail entry — restore the original OCR text. Used
    /// for accepted entries where the user disagrees with Haiku's
    /// correction and wants the pre-cleanup version back.
    func revertCorrection(_ entry: CorrectionTrail.Entry) {
        revealInSource(entry: entry)
        replaceInLoadedSource(
            find: entry.suggested,
            with: entry.original,
            actionLabel: "revert"
        )
    }

    /// Try to replace `find` with `with` in the currently-loaded
    /// `sourceText`. Tries the literal string first, then an
    /// entity-escaped variant (covers the common `& < > "` cases).
    /// Surfaces user-facing feedback in `correctionTrailMessage`.
    ///
    /// This is best-effort: the text we're matching on came from the
    /// pipeline's joined-observations buffer, which doesn't always
    /// survive reflow + XHTML serialization byte-for-byte. When the
    /// match is missing or ambiguous, we tell the user to apply
    /// manually rather than silently mangling the file.
    private func replaceInLoadedSource(
        find: String, with: String, actionLabel: String
    ) {
        let candidates = [find, Self.xhtmlEscape(find)]
        for candidate in candidates {
            let count = sourceText.components(separatedBy: candidate).count - 1
            switch count {
            case 1:
                sourceText = sourceText.replacingOccurrences(
                    of: candidate, with: Self.xhtmlEscape(with)
                )
                correctionTrailMessage =
                    "Correction \(actionLabel) applied. Save (⌘S) to persist."
                return
            case 0:
                continue
            default:
                correctionTrailMessage = """
                    Cannot \(actionLabel) automatically — text appears \
                    \(count) times in this file. Use Reveal in Source \
                    and replace it by hand.
                    """
                return
            }
        }
        correctionTrailMessage = """
            Cannot \(actionLabel) automatically — text from the OCR \
            stage didn't survive reflow byte-for-byte. Use Reveal in \
            Source, then copy the suggested text and replace by hand.
            """
    }

    /// Minimal XHTML entity-escape. Covers the four characters that
    /// need escaping inside element content (`<`, `>`, `&`) plus
    /// double-quote — enough for the common cases. Apostrophes are
    /// left alone (XHTML doesn't require escaping them in content).
    static func xhtmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    func pdfZoomIn()    { pdfController?.pdfView.zoomIn(nil) }
    func pdfZoomOut()   { pdfController?.pdfView.zoomOut(nil) }
    func pdfFitPage()   { pdfController?.fitPage() }
    func pdfNextPage()  { pdfController?.pdfView.goToNextPage(nil) }
    func pdfPrevPage()  { pdfController?.pdfView.goToPreviousPage(nil) }

    // MARK: - reload preview / save as

    /// Force the preview pane to re-fetch the current file. Useful
    /// after the user edited a CSS or asset file the preview depends
    /// on but didn't change the chapter file's `previewVersion`.
    func reloadPreview() {
        previewVersion &+= 1
    }

    /// Write the current state of the EPUB to a different path
    /// without disturbing the original. Flushes pending edits and
    /// repacks; doesn't switch the editor's `sourceURL`, so further
    /// Save calls still target the original.
    func saveAs(to outputURL: URL) async {
        guard let book = book else { return }
        flushSourceTextToBuffer()
        let buffersCopy = buffers
        let workingDir = book.workingDirectory
        saveState = .saving
        do {
            try await Task.detached(priority: .userInitiated) {
                for (url, text) in buffersCopy {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                }
                try EPUBRepacker().repack(workingDirectory: workingDir, to: outputURL)
            }.value
            saveState = .idle
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    /// Pick the anchor whose `pdfPage` is closest to `target` without
    /// going over. Defends against gaps in the pagemap (e.g. blank
    /// pages that produced no anchor) — clicking page 7 should still
    /// land you near page 7's content even if 7 itself isn't anchored.
    private func bestAnchor(for target: Int, in map: PageMap) -> PageMap.Entry? {
        var best: PageMap.Entry?
        for entry in map.entries {
            if entry.pdfPage > target { continue }
            if best == nil || entry.pdfPage > best!.pdfPage {
                best = entry
            }
        }
        return best ?? map.entries.first
    }

    /// Resolve the source PDF on first load. Order:
    ///   1. Sidecar inside the EPUB (`META-INF/com.humanist.json`).
    ///   2. A sibling `.pdf` matching the EPUB's basename.
    ///   3. Nothing — user can attach later.
    /// Auto-detect from a sibling does NOT mark the package dirty;
    /// only an explicit attach writes to the sidecar.
    private func attachInitialSourcePDF(epubURL: URL, book: EPUBBook) {
        sidecar = HumanistSidecar.read(workingDirectory: book.workingDirectory)
        if let resolved = sidecar.resolveSourcePDF(epubURL: epubURL) {
            setSourcePDF(resolved)
            return
        }
        let sibling = epubURL
            .deletingPathExtension()
            .appendingPathExtension("pdf")
        if FileManager.default.fileExists(atPath: sibling.path) {
            setSourcePDF(sibling)
        }
    }

    private func setSourcePDF(_ url: URL?) {
        sourcePDFURL = url
        // Only build the PDFKit controller when the source is
        // actually a PDF. For other formats (HTML / DOCX / RTF /
        // etc.) the embedded "Source PDF" pane stays inert and the
        // user opens the document via "Show Original in New Window"
        // — the standalone SourceViewer dispatches by extension.
        if let url, url.pathExtension.lowercased() == "pdf" {
            pdfController = PDFViewerController(pdfURL: url)
        } else {
            pdfController = nil
        }
        // The previous controller's observer is now dangling — re-bind
        // page-change notifications to the new pdfView (or detach if
        // the user removed the source PDF altogether).
        observePDFPageChanges()
    }

    /// Explicit user attach (toolbar action). Persists into the
    /// sidecar and marks the package dirty so Save flushes it.
    func attachSourcePDF(_ url: URL) {
        guard let book = book else { return }
        RecentsStore.add(url)
        setSourcePDF(url)
        // Prefer a relative path when the PDF lives next to the EPUB.
        // Compare canonically — `/var/...` vs `/private/var/...` and
        // similar symlink quirks would otherwise misclassify an
        // adjacent file as remote and store an absolute path.
        let epubDir = book.sourceURL.deletingLastPathComponent().canonicalForFile
        let stored: String
        if url.deletingLastPathComponent().canonicalForFile == epubDir {
            stored = url.lastPathComponent
        } else {
            stored = url.path
        }
        sidecar.sourcePDFPath = stored
        try? sidecar.write(workingDirectory: book.workingDirectory)
        isDirty = true
    }

    func detachSourcePDF() {
        guard let book = book else { return }
        setSourcePDF(nil)
        sidecar.sourcePDFPath = nil
        try? sidecar.write(workingDirectory: book.workingDirectory)
        isDirty = true
    }

    // MARK: - Chapter operations (Phase 5b)

    /// Last error from a chapter operation. Surfaced as an alert by
    /// the editor view.
    @Published var chapterOperationError: String?

    /// Split the current chapter file at the source pane's cursor
    /// position. Snaps forward to the next safe element boundary so
    /// we don't break tags. After the split, the OPF spine has a
    /// new entry inserted right after the current chapter and
    /// `nav.xhtml` is regenerated. The file selection stays on the
    /// (now-shorter) original file.
    func splitChapterAtCursor() async {
        guard let book = book, let file = selectedFile else { return }
        guard let cursorOffset = currentSourceCursorOffset else {
            chapterOperationError = "Move the cursor to where you want to split, then try again."
            return
        }
        flushSourceTextToBuffer()
        do {
            // Pull in-progress buffer edits into the book so the
            // split operates on the latest text.
            flushDirtyBuffersToBook()
            guard let resource = book.resource(at: file.id) else {
                throw EditError.notInManifest(file.id)
            }
            let editor = BookPackageEditor(book: book)
            _ = try editor.splitChapter(
                resourceID: resource.id, splitOffset: cursorOffset
            )
            // Atomic flush of every book mutation (split body of
            // original, new chapter file, OPF, regenerated nav).
            // Up to this point disk hasn't been touched — a throw
            // here leaves the working tree exactly as it was.
            try EPUBBookSaver().save(book)

            refreshFileTree()
            // The chapters we just flushed match disk now; clear
            // the editor's per-buffer dirty flags so save() doesn't
            // re-write them.
            dirtyURLs.remove(file.id)
            // The on-disk file changed — reload its content into
            // the source pane bypassing the flush-then-load path
            // `select(_:)` uses (that would stash the pre-split
            // CodeMirror buffer back over our just-written file).
            reloadSelectedFileFromDisk()
            // Bump preview so the WKWebView re-fetches the
            // truncated chapter file.
            previewVersion += 1
            isDirty = true
        } catch {
            chapterOperationError = error.localizedDescription
        }
    }

    /// Merge the current chapter with the next chapter in the spine.
    /// The next chapter's file is deleted; nav.xhtml is regenerated.
    /// File selection stays on the merged file (the original).
    func mergeChapterWithNext() async {
        guard let book = book, let file = selectedFile else { return }
        flushSourceTextToBuffer()
        do {
            flushDirtyBuffersToBook()
            guard let resource = book.resource(at: file.id) else {
                throw EditError.notInManifest(file.id)
            }
            let editor = BookPackageEditor(book: book)
            try editor.mergeWithNextChapter(at: resource.id)
            try EPUBBookSaver().save(book)

            refreshFileTree()
            // The merged file is now identical to disk; the deleted
            // next chapter's URL no longer corresponds to a resource.
            // Walk buffers and drop any URLs the book doesn't recognize.
            scrubBuffersForResourcesRemovedFromBook()
            dirtyURLs.remove(file.id)
            // The on-disk file now contains both chapters' bodies —
            // reload its content into the source pane bypassing the
            // flush-then-load path `select(_:)` uses (that would
            // stash the pre-merge CodeMirror buffer back over our
            // just-written merged content).
            reloadSelectedFileFromDisk()
            // Bump preview so the WKWebView re-fetches the merged
            // chapter file.
            previewVersion += 1
            isDirty = true
        } catch {
            chapterOperationError = error.localizedDescription
        }
    }

    /// Errors surfaced by chapter-level operations beyond what
    /// `BookPackageEditor` produces. These cover invariant breaks
    /// at the editor↔book boundary (file selected for an op but
    /// no longer in the manifest, etc.).
    enum EditError: LocalizedError {
        case notInManifest(URL)

        var errorDescription: String? {
            switch self {
            case .notInManifest(let url):
                return "\(url.lastPathComponent) isn't in the EPUB's manifest."
            }
        }
    }

    /// In-flight Rename Chapter prompt state. Held on the
    /// view-model so the alert UI in `EditorView` can bind a
    /// TextField directly to `newBaseName`. The ID lets SwiftUI's
    /// `.alert(item:)` reset the field when the user opens a
    /// rename for a different chapter mid-flow.
    struct PendingRename: Identifiable {
        let id = UUID()
        /// File URL the user right-clicked. Captured up-front so
        /// the rename targets the same chapter even if selection
        /// changes during the prompt.
        let url: URL
        /// Manifest @id of the resource being renamed.
        let resourceID: String
        /// Filename stem at the time the prompt opened (no
        /// directory, no extension).
        let originalStem: String
        /// Extension (e.g. `xhtml`) — preserved verbatim across
        /// the rename. The user types the stem only.
        let extensionOnly: String
        /// Bound to the alert's TextField. Defaults to the
        /// original stem.
        var newBaseName: String
    }

    /// Reload the selected file's source from disk after an on-disk
    /// edit (Split / Merge / Regenerate-TOC). Bypasses the flush
    /// `select(_:)` performs for ordinary file switches — that
    /// flush would stash the stale pre-edit CodeMirror buffer back
    /// over the disk write, undoing the operation visually even
    /// though the file on disk is correct.
    ///
    /// Invariants on entry: the selected file's URL still exists
    /// on disk (the caller already wrote to it) and has the
    /// post-edit content. We drop any in-memory buffer + dirty
    /// flag, re-read from disk into both `buffers[url]` and
    /// `sourceText`. CodeMirror's binding to `sourceText` updates
    /// on the next render.
    private func reloadSelectedFileFromDisk() {
        guard let url = selectedFile?.id,
              !(selectedFile?.isDirectory ?? true),
              Self.isTextFile(url) else { return }
        buffers.removeValue(forKey: url)
        dirtyURLs.remove(url)
        do {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8)
                ?? "(Could not decode \(url.lastPathComponent) as UTF-8)"
            buffers[url] = text
            sourceText = text
        } catch {
            sourceText = "(Reload failed: \(error.localizedDescription))"
        }
    }

    /// Regenerate `nav.xhtml` from the current spine. Each chapter's
    /// title is extracted from its first heading; chapters with no
    /// heading fall back to "Chapter N".
    func regenerateTableOfContents() async {
        guard let book = book else { return }
        flushSourceTextToBuffer()
        do {
            // Sync user edits into the book so heading extraction
            // sees the latest chapter content.
            flushDirtyBuffersToBook()
            try BookPackageEditor(book: book).regenerateNav()
            try EPUBBookSaver().save(book)
            refreshFileTree()
            // If the user was viewing nav.xhtml, it just got
            // overwritten — reload from disk so they see the result.
            reloadSelectedFileFromDisk()
            previewVersion += 1
            isDirty = true
        } catch {
            chapterOperationError = error.localizedDescription
        }
    }

    /// Whether the current selection has a chapter to merge with —
    /// drives menu-item enable/disable state. Returns true only when
    /// the selected file is a spine entry that isn't last.
    var canMergeWithNextChapter: Bool {
        guard let book = book, let file = selectedFile else { return false }
        guard let resource = book.resource(at: file.id) else { return false }
        return book.nextSpineResourceID(after: resource.id) != nil
    }

    /// Whether the selected file is a spine entry — drives the
    /// Split menu item's enable state.
    var canSplitCurrentChapter: Bool {
        guard let book = book, let file = selectedFile else { return false }
        guard let resource = book.resource(at: file.id) else { return false }
        return book.spine.contains(resource.id)
    }

    /// Whether the selected chapter can move up one position in the
    /// spine. False when the chapter isn't in the spine, or when
    /// it's already first.
    var canMoveCurrentChapterUp: Bool {
        canMoveCurrentChapter(direction: .up)
    }

    /// Whether the selected chapter can move down one position in
    /// the spine. False when the chapter isn't in the spine, or
    /// when it's already last.
    var canMoveCurrentChapterDown: Bool {
        canMoveCurrentChapter(direction: .down)
    }

    /// Same predicate as `canMoveCurrentChapterUp/Down` but parametric
    /// — used by `BookBrowser` to enable / disable context-menu
    /// items for an arbitrary node, not just the selection.
    func canMoveChapter(at url: URL, direction: EPUBBook.SpineMoveDirection) -> Bool {
        guard let book = book else { return false }
        guard let resource = book.resource(at: url) else { return false }
        guard let idx = book.spine.firstIndex(of: resource.id) else { return false }
        switch direction {
        case .up:   return idx > 0
        case .down: return idx + 1 < book.spine.count
        }
    }

    private func canMoveCurrentChapter(direction: EPUBBook.SpineMoveDirection) -> Bool {
        guard let file = selectedFile else { return false }
        return canMoveChapter(at: file.id, direction: direction)
    }

    /// Move the currently selected chapter one position up in the
    /// spine. Updates manifest order to match (so the sidebar's
    /// alphabetical view still tracks reading order isn't perfect
    /// — the file is on disk under its existing name — but the
    /// in-memory manifest order, which drives the OPF, follows the
    /// new reading order). Saves the book so disk + .epub repack
    /// reflect the change without a separate Save.
    func moveCurrentChapterUp() {
        guard let file = selectedFile else { return }
        moveChapter(at: file.id, direction: .up)
    }

    /// Mirror of `moveCurrentChapterUp` for the down direction.
    func moveCurrentChapterDown() {
        guard let file = selectedFile else { return }
        moveChapter(at: file.id, direction: .down)
    }

    /// Pending Rename Chapter alert state. Set by
    /// `beginRenameChapter(at:)`; cleared by commit / cancel. The
    /// view binds an alert + TextField to the optional and reads
    /// `originalBaseName` to seed the input.
    @Published var pendingRename: PendingRename?

    /// Whether the resource at `url` can be renamed. True for any
    /// text resource in the manifest. Binary resources (images,
    /// fonts) could in principle be renamed too but the rename UI
    /// targets chapter files; we'll lift this restriction if the
    /// user asks.
    func canRenameChapter(at url: URL) -> Bool {
        guard let book = book else { return false }
        guard let resource = book.resource(at: url) else { return false }
        return resource.isText
    }

    /// Open the Rename Chapter prompt for the resource at `url`.
    /// Seeds the alert's text field with the current basename
    /// (stem only — no path, no extension). The view is responsible
    /// for binding to and updating `pendingRename.newBaseName`.
    func beginRenameChapter(at url: URL) {
        guard let book = book, let resource = book.resource(at: url) else { return }
        let href = resource.hrefRelativeToOPF
        let basename: String
        if let lastSlash = href.lastIndex(of: "/") {
            basename = String(href[href.index(after: lastSlash)...])
        } else {
            basename = href
        }
        let stem: String
        let ext: String
        if let lastDot = basename.lastIndex(of: "."),
           lastDot != basename.startIndex {
            stem = String(basename[..<lastDot])
            ext = String(basename[basename.index(after: lastDot)...])
        } else {
            stem = basename
            ext = "xhtml"
        }
        pendingRename = PendingRename(
            url: url,
            resourceID: resource.id,
            originalStem: stem,
            extensionOnly: ext,
            newBaseName: stem
        )
    }

    /// Cancel the pending rename without changes.
    func cancelRenameChapter() {
        pendingRename = nil
    }

    /// Commit the pending rename. Validates the new basename, runs
    /// the rename through the book (with internal-link rewriting),
    /// saves, and refreshes the file tree. No-op when the pending
    /// rename is nil or the new basename equals the old.
    func commitRenameChapter() {
        guard let pending = pendingRename, let book = book else { return }
        defer { pendingRename = nil }

        let trimmed = pending.newBaseName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if trimmed == pending.originalStem { return }
        guard Self.isValidBasename(trimmed) else {
            chapterOperationError = "Filename must not contain slashes, colons, or other path characters."
            return
        }

        // Construct the new href. Keep the same directory + extension
        // as the original; the user only typed the stem.
        let oldHref: String
        if let resource = book.resourcesByID[pending.resourceID] {
            oldHref = resource.hrefRelativeToOPF
        } else {
            return
        }
        let dir: String
        if let lastSlash = oldHref.lastIndex(of: "/") {
            dir = String(oldHref[..<lastSlash])
        } else {
            dir = ""
        }
        let newBasename = "\(trimmed).\(pending.extensionOnly)"
        let newHref = dir.isEmpty ? newBasename : "\(dir)/\(newBasename)"

        flushSourceTextToBuffer()
        flushDirtyBuffersToBook()
        do {
            _ = try book.renameResource(
                id: pending.resourceID,
                newHrefRelativeToOPF: newHref
            )
            try EPUBBookSaver().save(book)

            // The selected file's URL just changed on disk. Update
            // editor-side state to track the new path.
            if let resource = book.resourcesByID[pending.resourceID] {
                let newAbsoluteURL = book.absoluteURL(for: resource)
                if let oldBuffer = buffers.removeValue(forKey: pending.url) {
                    buffers[newAbsoluteURL] = oldBuffer
                }
                dirtyURLs.remove(pending.url)
            }
            refreshFileTree()
            // Re-select the renamed node so the source pane and
            // sidebar both follow the rename.
            if let book = self.book,
               let resource = book.resourcesByID[pending.resourceID],
               let tree = self.fileTree {
                let newURL = book.absoluteURL(for: resource)
                if let node = Self.findLeaf(in: tree, matching: newURL) {
                    selectedFile = node
                    loadSourceForSelectedFile()
                }
            }
            previewVersion += 1
            isDirty = true
        } catch {
            chapterOperationError = error.localizedDescription
        }
    }

    /// Filename input must be plain — no slashes (would change the
    /// directory), no colons or NUL characters (illegal on macOS),
    /// no leading dot (hidden file). Tightening to alphanumerics +
    /// `_-.` keeps EPUB-friendly basenames.
    private static func isValidBasename(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix(".") else { return false }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_-. "))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Sidebar drag-and-drop reorder: take the chapter at
    /// `sourceURL` and insert it immediately before the chapter at
    /// `targetURL`. Both must be spine entries; non-spine drops
    /// (or drops onto the same chapter) are no-ops.
    ///
    /// "Insert before" matches the sidebar's visual semantic: the
    /// row the user dropped onto stays where it is, and the
    /// dragged row appears above it. Dropping onto your own row,
    /// or onto the row immediately above you (no-op move), gets
    /// short-circuited by `EPUBBook.moveInSpine(id:toIndex:)`.
    func moveChapter(at sourceURL: URL, before targetURL: URL) {
        guard let book = book else { return }
        guard let source = book.resource(at: sourceURL),
              let target = book.resource(at: targetURL)
        else { return }
        guard let targetIdx = book.spine.firstIndex(of: target.id) else { return }
        flushSourceTextToBuffer()
        flushDirtyBuffersToBook()
        book.moveInSpine(id: source.id, toIndex: targetIdx)
        do {
            try EPUBBookSaver().save(book)
            refreshFileTree()
            previewVersion += 1
            isDirty = true
        } catch {
            chapterOperationError = error.localizedDescription
        }
    }

    /// Move the chapter referenced by `url` one position in the
    /// spine. Used by both the menu-bar and sidebar context-menu
    /// commands.
    func moveChapter(at url: URL, direction: EPUBBook.SpineMoveDirection) {
        guard let book = book else { return }
        guard let resource = book.resource(at: url) else { return }
        guard canMoveChapter(at: url, direction: direction) else { return }
        flushSourceTextToBuffer()
        flushDirtyBuffersToBook()
        book.moveInSpine(id: resource.id, direction: direction)
        do {
            try EPUBBookSaver().save(book)
            // The OPF on disk now lists chapters in the new order.
            // Files on disk are unchanged (we don't rename for a
            // reorder), but the sidebar sorts chapter rows by spine
            // index so it needs a tree-walk refresh to reflect the
            // new order.
            refreshFileTree()
            previewVersion += 1
            isDirty = true
        } catch {
            chapterOperationError = error.localizedDescription
        }
    }

    /// Rebuild the file-tree sidebar after a chapter operation that
    /// changed which files exist on disk (Split / Merge add or remove
    /// chapter files; Regenerate-TOC rewrites nav.xhtml). The book
    /// itself is already up to date in memory — only the tree view
    /// needs to be refreshed.
    private func refreshFileTree() {
        guard let book = book else { return }
        fileTree = FileNode.walk(book.workingDirectory, spineOrder: book.spineURLOrder)
    }

    /// Re-read the in-memory book from disk. Called after the editor's
    /// `save()` writes user-buffer-driven edits to disk so a subsequent
    /// Merge / Split sees the latest content. Without this, the book
    /// would still hold load-time text after a save, and operations on
    /// it would silently overwrite the user's last typed-and-saved
    /// edits with the older snapshot.
    private func reloadBookFromDisk() throws {
        guard let oldBook = book else { return }
        let fresh = try EPUBBookLoader().load(
            sourceURL: oldBook.sourceURL,
            workingDirectory: oldBook.workingDirectory
        )
        // The fresh book is taking over ownership of the same working
        // directory. Disown the old instance first so its deinit
        // doesn't delete the directory out from under the new one.
        oldBook.disownWorkingDirectory()
        self.book = fresh
        self.fileTree = FileNode.walk(fresh.workingDirectory, spineOrder: fresh.spineURLOrder)
        // Keep the chat transcript across saves; just retire the
        // stale keyword index so the next query rebuilds against
        // the freshest text.
        chatViewModel?.bookDidReload(fresh)
    }

    /// Sync every dirty source-pane buffer into the corresponding
    /// `Resource.text` in the book. Invoked before any chapter-level
    /// operation so `BookPackageEditor` works against the user's
    /// latest typing rather than load-time content. Resources whose
    /// text already matches the buffer are left untouched (no
    /// spurious dirty marks).
    private func flushDirtyBuffersToBook() {
        guard let book = book else { return }
        for url in dirtyURLs {
            guard let text = buffers[url] else { continue }
            guard let resource = book.resource(at: url),
                  resource.isText
            else { continue }
            if resource.text != text {
                resource.text = text
            }
        }
    }

    /// Drop in-memory editor state for any URL whose corresponding
    /// resource is no longer in the book (e.g. the next chapter after
    /// Merge). Without this, `save()` would re-write the file from a
    /// stale buffer and the operation would appear to revert.
    private func scrubBuffersForResourcesRemovedFromBook() {
        guard let book = book else { return }
        let validPaths: Set<String> = Set(
            book.resourcesByID.values.map { resource in
                book.absoluteURL(for: resource)
                    .canonicalForFile.standardizedFileURL.path
            }
        )
        let staleURLs = buffers.keys.filter { url in
            !validPaths.contains(url.canonicalForFile.standardizedFileURL.path)
        }
        for url in staleURLs {
            buffers.removeValue(forKey: url)
            dirtyURLs.remove(url)
        }
    }

    func select(_ node: FileNode) {
        guard !node.isDirectory else { return }
        let isFileSwitch = selectedFile?.id != node.id
        // Stash the current file's edits before switching.
        flushSourceTextToBuffer()
        selectedFile = node
        loadSourceForSelectedFile()
        // One-shot align: when the user picks a chapter from the
        // browser, align the PDF + preview to that chapter's first
        // page anchor (if it has one). No continuous sync — that
        // bidirectional model produced two bugs and was removed.
        if isFileSwitch {
            alignAllToCurrentFile()
        }
    }

    /// Copy the live `sourceText` back into `buffers` for the file the
    /// user was just on. Called before switching files and inside
    /// Save so the in-memory truth and on-disk truth converge.
    private func flushSourceTextToBuffer() {
        guard let prev = selectedFile?.id, !(selectedFile?.isDirectory ?? true) else {
            return
        }
        guard Self.isTextFile(prev) else { return }
        if buffers[prev] != sourceText {
            buffers[prev] = sourceText
            dirtyURLs.insert(prev)
            isDirty = true
        }
    }

    /// Populate `sourceText` for the newly-selected file: from the
    /// in-memory buffer if we've touched the file already, otherwise
    /// from disk (and cache the result).
    private func loadSourceForSelectedFile() {
        guard let url = selectedFile?.id, !(selectedFile?.isDirectory ?? true),
              Self.isTextFile(url) else {
            sourceText = ""
            return
        }
        if let buf = buffers[url] {
            sourceText = buf
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8)
                ?? "(Could not decode \(url.lastPathComponent) as UTF-8)"
            buffers[url] = text
            loadedFiles.insert(url)
            sourceText = text
        } catch {
            sourceText = "(Read failed: \(error.localizedDescription))"
        }
    }

    func revealInFinder() {
        guard let book = book else { return }
        NSWorkspace.shared.activateFileViewerSelecting([book.sourceURL])
    }

    // MARK: - source buffers

    /// Whether the source pane should accept edits for the current
    /// selection (text file selected). Used by the View to decide
    /// between TextEditor and the binary placeholder.
    var canEditSelectedFile: Bool {
        guard let url = selectedFile?.id, !(selectedFile?.isDirectory ?? true) else {
            return false
        }
        return Self.isTextFile(url)
    }

    /// Mirror `sourceText` back into the buffer + dirty set on every
    /// keystroke. Called by the EditorView's `.onChange(of: vm.sourceText)`
    /// hook because @Published doesn't expose a willSet/didSet path
    /// from outside the type and we want the dirty bit to track
    /// real-time edits.
    func didEditSourceText() {
        guard let url = selectedFile?.id else { return }
        if buffers[url] != sourceText {
            buffers[url] = sourceText
            dirtyURLs.insert(url)
            isDirty = true
        }
        scheduleLivePreviewRefresh()
    }

    /// Debounce + flush the current `sourceText` to its file on disk
    /// and bump `previewVersion` so the preview pane reloads. Runs on
    /// every keystroke; the previous task is cancelled so a burst of
    /// typing produces exactly one disk write at the trailing edge.
    private func scheduleLivePreviewRefresh() {
        livePreviewTask?.cancel()
        livePreviewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.livePreviewDebounce)
            guard !Task.isCancelled, let self else { return }
            self.flushSelectedFileToDisk()
            self.previewVersion &+= 1
        }
    }

    /// Write the current `sourceText` to the working-dir copy of the
    /// selected file. Ignores binaries and silently no-ops on write
    /// failure — Save still has to succeed for the user to consider
    /// data persisted, so this path is best-effort.
    private func flushSelectedFileToDisk() {
        guard let url = selectedFile?.id, Self.isTextFile(url) else { return }
        guard let buf = buffers[selectedFile?.id ?? url] else { return }
        try? buf.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - save (Phase 6.B)

    /// Write every dirty buffer to disk inside the working directory,
    /// then repack the working directory into the source .epub.
    /// Atomic at the .epub level: a successful return means readers
    /// will see the new contents on next open.
    func save() async {
        guard let book = book else { return }
        // Pull the current TextEditor's contents into the buffer so a
        // file the user is actively editing isn't missed.
        flushSourceTextToBuffer()
        // Pre-flight: parse XML / XHTML files and surface any errors
        // in `validationIssues`. Save still proceeds — a broken edit
        // shouldn't block writing (the user may want to fix it from
        // the on-disk file) — but the strip in the source pane makes
        // the failure visible immediately.
        validationIssues = Self.validateXMLBuffers(buffers, dirty: dirtyURLs)
        saveState = .saving
        let buffersCopy = buffers
        let dirtyCopy = dirtyURLs
        let workingDir = book.workingDirectory
        let outURL = book.sourceURL

        do {
            try await Task.detached(priority: .userInitiated) {
                // Flush dirty buffers to disk first.
                for url in dirtyCopy {
                    if let text = buffersCopy[url] {
                        try text.write(to: url, atomically: true, encoding: .utf8)
                    }
                }
                // Then repack everything under workingDir into the EPUB.
                try EPUBRepacker().repack(workingDirectory: workingDir, to: outURL)
            }.value
            self.dirtyURLs.removeAll()
            // After save, the working directory matches the user's
            // edited buffers. Reload the in-memory book so its
            // resource texts reflect the saved disk state — without
            // this, a subsequent Merge / Split would operate on
            // load-time content and silently revert the just-saved
            // edits.
            try? self.reloadBookFromDisk()
            self.isDirty = false
            self.saveState = .idle
            self.wysiwygReloadToken &+= 1
            // Keep linked exports in sync. Best-effort: only
            // regenerates sibling files that already exist (next to
            // the EPUB or in the configured output folder), so the
            // user's "no siblings" preference is preserved.
            if let updated = self.book {
                await SiblingRegenerator.regenerateExisting(
                    for: updated, epubURL: outURL
                )
            }
        } catch {
            self.saveState = .failed(error.localizedDescription)
        }
    }

    // MARK: - validation

    /// Validate the dirty XHTML / XML buffers against `XMLDocument`.
    /// Returns a `[fileURL: error message]` dict for the failures.
    /// CSS, JS, and other non-XML text files are skipped — there's
    /// no Foundation parser for them and we'd rather miss a CSS typo
    /// than spam the UI with false positives.
    static func validateXMLBuffers(
        _ buffers: [URL: String],
        dirty: Set<URL>
    ) -> [URL: String] {
        var out: [URL: String] = [:]
        for url in dirty {
            guard isXMLFile(url), let text = buffers[url] else { continue }
            if let err = validateXML(text) {
                out[url] = err
            }
        }
        return out
    }

    /// Try to parse `text` as a standalone XML document. Returns nil
    /// on success, an error message on failure. Foundation's parser
    /// surfaces the line and column in the error description.
    static func validateXML(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else {
            return "Not valid UTF-8"
        }
        do {
            _ = try XMLDocument(data: data)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Files that should be parsed as XML on save.
    static func isXMLFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "xhtml" || ext == "html" || ext == "htm"
            || ext == "xml" || ext == "opf" || ext == "ncx" || ext == "svg"
            || url.lastPathComponent == "container.xml"
    }

    // MARK: - file kind classification

    /// File-extension whitelist for "show this as text in the source
    /// pane and accept edits." Anything else (images, fonts, audio) is
    /// preview-only.
    static func isTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.textExtensions.contains(ext)
            || url.lastPathComponent == "mimetype"
            || url.lastPathComponent == "container.xml"
            || ext == "opf" || ext == "ncx"
    }

    private static let textExtensions: Set<String> = [
        "xhtml", "html", "htm", "xml", "css", "js", "json", "txt", "svg", "smil"
    ]

    // MARK: - initial selection heuristic

    private static func preferredInitialSelection(
        in book: EPUBBook, fileTree: FileNode?
    ) -> FileNode? {
        guard let tree = fileTree else { return nil }
        if let firstSpineId = book.spine.first,
           let resource = book.resourcesByID[firstSpineId] {
            let target = book.absoluteURL(for: resource).canonicalForFile
            if let node = findLeaf(in: tree, matching: target) {
                return node
            }
        }
        return firstLeaf(in: tree, where: { node in
            let ext = node.id.pathExtension.lowercased()
            return ext == "xhtml" || ext == "html"
        }) ?? firstLeaf(in: tree, where: { _ in true })
    }

    private static func findLeaf(in node: FileNode, matching url: URL) -> FileNode? {
        // Both sides canonicalized so /var ↔ /private/var doesn't
        // sink the comparison. (FileNode.walk already yields canonical
        // URLs because the book canonicalizes its working dir, but
        // belt-and-suspenders here costs nothing.)
        if !node.isDirectory && node.id.canonicalForFile == url { return node }
        guard let children = node.children else { return nil }
        for c in children {
            if let m = findLeaf(in: c, matching: url) { return m }
        }
        return nil
    }

    private static func firstLeaf(in node: FileNode, where pred: (FileNode) -> Bool) -> FileNode? {
        if !node.isDirectory && pred(node) { return node }
        guard let children = node.children else { return nil }
        for c in children {
            if let m = firstLeaf(in: c, where: pred) { return m }
        }
        return nil
    }
}
