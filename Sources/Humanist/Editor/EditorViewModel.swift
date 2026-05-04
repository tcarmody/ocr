import Foundation
import SwiftUI
import AppKit
import Document
import EPUB
import OCR
import PDFKit
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
    case pdf, source, preview
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
    @Published private(set) var package: EPUBPackage?
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
    /// they selected in the PDF.
    @Published private(set) var currentSourceAnchor: String?

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

    struct ReOCRResult: Identifiable, Equatable {
        let id: UUID
        let engine: ReOCREngineKind
        /// PDF pages the selection spanned. Used for the sheet title
        /// (e.g. "Re-OCR with Vision · Page 7").
        let pageRange: ClosedRange<Int>
        /// Recognized text, joined top-to-bottom-then-left-to-right.
        let text: String
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

    private static func defaultsKey(_ pane: EditorPane) -> String {
        "humanist.editor.show.\(pane.rawValue)"
    }

    private static func defaultPaneVisibility(_ pane: EditorPane) -> Bool {
        if let v = UserDefaults.standard.object(forKey: defaultsKey(pane)) as? Bool {
            return v
        }
        return true  // all panes on by default
    }

    func isPaneVisible(_ pane: EditorPane) -> Bool {
        switch pane {
        case .pdf:     return showPDFPane
        case .source:  return showSourcePane
        case .preview: return showPreviewPane
        }
    }

    func togglePane(_ pane: EditorPane) {
        switch pane {
        case .pdf:     showPDFPane.toggle()
        case .source:  showSourcePane.toggle()
        case .preview: showPreviewPane.toggle()
        }
    }

    init(epubURL: URL) {
        self.showPDFPane = Self.defaultPaneVisibility(.pdf)
        self.showSourcePane = Self.defaultPaneVisibility(.source)
        self.showPreviewPane = Self.defaultPaneVisibility(.preview)
        Task { await self.load(epubURL: epubURL) }
    }

    func load(epubURL: URL) async {
        self.state = .loading
        do {
            let pkg = try await Task.detached(priority: .userInitiated) {
                try EPUBPackage.open(epubURL: epubURL)
            }.value
            self.package = pkg
            self.state = .ready
            self.selectedFile = Self.preferredInitialSelection(in: pkg)
            self.loadSourceForSelectedFile()
            self.attachInitialSourcePDF(epubURL: epubURL, package: pkg)
            self.pageMap = PageMap.read(workingDirectory: pkg.workingDirectory)
        } catch {
            self.state = .failed(error.localizedDescription)
        }
    }

    // MARK: - linked navigation (Phase 7.D)

    /// Token for the current PDF-page-change observer. Tearing it
    /// down on detach/reload prevents stale callbacks firing into a
    /// dead PDFView.
    private var pdfPageObserver: NSObjectProtocol?
    /// True while we're driving the PDF programmatically (preview
    /// scrolled, we're moving the PDF to match). Suppresses the
    /// page-change → preview-scroll feedback that would otherwise
    /// fire back at us.
    private var suppressPDFToPreviewSync: Bool = false

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
                guard !self.suppressPDFToPreviewSync else { return }
                guard let page = pdfView.currentPage,
                      let pdfPage = pdfView.document?.index(for: page)
                else { return }
                self.scrollPreviewTo(pdfPage: pdfPage)
            }
        }
    }

    /// PDF → preview: find the anchor for `pdfPage`, switch the
    /// selected file if the anchor lives in a different chapter, and
    /// publish a scroll request.
    func scrollPreviewTo(pdfPage: Int) {
        guard let map = pageMap, let pkg = package else { return }
        guard let entry = bestAnchor(for: pdfPage, in: map) else { return }
        // Switch file if needed. Path is stored relative to the EPUB
        // root in the sidecar; resolve against the working dir.
        let fileURL = pkg.workingDirectory
            .appendingPathComponent(entry.xhtmlFile)
            .canonicalForFile
        if selectedFile?.id.canonicalForFile != fileURL,
           let node = Self.findLeaf(in: pkg.fileTree, matching: fileURL) {
            select(node)
        }
        scrollNonce &+= 1
        let req = AnchorScrollRequest(
            anchorId: entry.anchorId,
            xhtmlFile: entry.xhtmlFile,
            nonce: scrollNonce
        )
        scrollPreviewToAnchor = req
        scrollCodeToAnchor = req
    }

    /// Preview → PDF: called by the IntersectionObserver bridge when
    /// the topmost-visible anchor in the rendered XHTML changes.
    /// Looks up the matching PDF page and scrolls the PDF view.
    /// Suppresses the inverse callback during the transition so the
    /// two directions don't fight each other.
    /// Code → others sync. Called by `CodeEditorView` when the
    /// CodeMirror cursor crosses into a new `hu-page-N` anchor's
    /// region. Drives the PDF page + preview scroll without
    /// republishing the code-scroll request (the cursor is already
    /// where it needs to be).
    func didMoveCursorToAnchor(_ anchorId: String) {
        currentSourceAnchor = anchorId
        guard let map = pageMap,
              let entry = map.entries.first(where: { $0.anchorId == anchorId })
        else { return }
        // PDF: jump to matching page if not already there. Suppress
        // the page-change → preview-scroll callback so it doesn't
        // republish a code-scroll request that ping-pongs us back.
        if let pdfView = pdfController?.pdfView,
           let document = pdfView.document,
           entry.pdfPage >= 0, entry.pdfPage < document.pageCount,
           let page = document.page(at: entry.pdfPage),
           pdfView.currentPage !== page {
            suppressPDFToPreviewSync = true
            pdfView.go(to: page)
            DispatchQueue.main.async { [weak self] in
                self?.suppressPDFToPreviewSync = false
            }
        }
        // Preview: scroll to the anchor. Don't republish
        // `scrollCodeToAnchor` — the code is already there.
        scrollNonce &+= 1
        scrollPreviewToAnchor = AnchorScrollRequest(
            anchorId: entry.anchorId,
            xhtmlFile: entry.xhtmlFile,
            nonce: scrollNonce
        )
    }

    func scrollPDFTo(anchorId: String) {
        guard let map = pageMap,
              let entry = map.entries.first(where: { $0.anchorId == anchorId })
        else { return }
        // Code editor follows the preview's current scroll position
        // too — preview is the source of truth in this direction, but
        // we still want the source pane to track. (Preview is already
        // showing the anchor, so don't republish its scroll request.)
        scrollNonce &+= 1
        scrollCodeToAnchor = AnchorScrollRequest(
            anchorId: entry.anchorId,
            xhtmlFile: entry.xhtmlFile,
            nonce: scrollNonce
        )
        // Drive the PDF to match.
        guard let pdfView = pdfController?.pdfView,
              let document = pdfView.document,
              entry.pdfPage >= 0, entry.pdfPage < document.pageCount,
              let page = document.page(at: entry.pdfPage)
        else { return }
        if pdfView.currentPage === page { return }  // already there
        suppressPDFToPreviewSync = true
        pdfView.go(to: page)
        // Release suppression on next runloop tick — by then the
        // PDFViewPageChangedNotification has already fired and been
        // ignored.
        DispatchQueue.main.async { [weak self] in
            self?.suppressPDFToPreviewSync = false
        }
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
            text: text, replaceTarget: .sourceSelection
        )
    }

    /// Re-OCR the entire PDF page that contains the cursor in the
    /// source pane. This is the workflow most users want most of the
    /// time: pick a bad section in the EPUB, re-OCR with a different
    /// engine, replace the whole page in source. No PDF-selection
    /// dance, no length-mismatch headaches.
    func reOCRCurrentSourcePage(engine kind: ReOCREngineKind) async throws {
        guard let pdfController else { throw ReOCRError.noPDFAttached }
        guard let pdfDoc = pdfController.pdfView.document
        else { throw ReOCRError.noPDFAttached }

        // Find the anchor the source cursor is in. Fall back to the
        // first anchor in the currently-selected file if the cursor
        // hasn't reported one yet (e.g. file just opened).
        let anchorId = currentSourceAnchor
            ?? firstAnchorIdInSelectedFile()
        guard let anchorId,
              let entry = pageMap?.entries.first(where: { $0.anchorId == anchorId })
        else { throw ReOCRError.noSourceAnchor }
        guard entry.pdfPage >= 0,
              entry.pdfPage < pdfDoc.pageCount,
              let page = pdfDoc.page(at: entry.pdfPage)
        else { throw ReOCRError.noPDFAttached }

        guard kind.isAvailable, let engine = kind.makeEngine() else {
            throw ReOCRError.engineUnavailable(kind)
        }

        let bounds = page.bounds(for: .mediaBox)
        guard let image = PDFRegionRenderer.render(page: page, region: bounds)
        else { throw ReOCRError.renderFailed }

        let hints = OCRHints(
            languages: selectedBCP47Languages(),
            quality: .accurate
        )
        do {
            let result = try await engine.recognize(image: image, hints: hints)
            let text = formatObservations(result.observations)
            reOCRResult = ReOCRResult(
                id: UUID(), engine: kind, pageRange: entry.pdfPage...entry.pdfPage,
                text: text, replaceTarget: .pageInSource(anchorId: anchorId)
            )
        } catch {
            throw ReOCRError.ocrFailed(String(describing: error))
        }
    }

    /// First `hu-page-*` anchor whose pagemap entry points at the
    /// currently selected file. Used as a fallback when the source
    /// cursor hasn't fired a cursor-anchor message yet.
    private func firstAnchorIdInSelectedFile() -> String? {
        guard let pkg = package, let map = pageMap, let file = selectedFile else {
            return nil
        }
        let prefix = pkg.workingDirectory.canonicalForFile.path
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
        if let raw = package?.package.metadata.language,
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
    func replaceSourceSelection(with text: String) {
        replaceNonce &+= 1
        replaceSourceRequest = ReplaceSourceRequest(text: text, nonce: replaceNonce)
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
        guard let pkg = package else { return }
        flushSourceTextToBuffer()
        let buffersCopy = buffers
        let workingDir = pkg.workingDirectory
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
    private func attachInitialSourcePDF(epubURL: URL, package: EPUBPackage) {
        sidecar = HumanistSidecar.read(workingDirectory: package.workingDirectory)
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
        pdfController = url.map { PDFViewerController(pdfURL: $0) }
        // The previous controller's observer is now dangling — re-bind
        // page-change notifications to the new pdfView (or detach if
        // the user removed the source PDF altogether).
        observePDFPageChanges()
    }

    /// Explicit user attach (toolbar action). Persists into the
    /// sidecar and marks the package dirty so Save flushes it.
    func attachSourcePDF(_ url: URL) {
        guard let pkg = package else { return }
        RecentsStore.add(url)
        setSourcePDF(url)
        // Prefer a relative path when the PDF lives next to the EPUB.
        // Compare canonically — `/var/...` vs `/private/var/...` and
        // similar symlink quirks would otherwise misclassify an
        // adjacent file as remote and store an absolute path.
        let epubDir = pkg.sourceURL.deletingLastPathComponent().canonicalForFile
        let stored: String
        if url.deletingLastPathComponent().canonicalForFile == epubDir {
            stored = url.lastPathComponent
        } else {
            stored = url.path
        }
        sidecar.sourcePDFPath = stored
        try? sidecar.write(workingDirectory: pkg.workingDirectory)
        isDirty = true
    }

    func detachSourcePDF() {
        guard let pkg = package else { return }
        setSourcePDF(nil)
        sidecar.sourcePDFPath = nil
        try? sidecar.write(workingDirectory: pkg.workingDirectory)
        isDirty = true
    }

    func select(_ node: FileNode) {
        guard !node.isDirectory else { return }
        // Stash the current file's edits before switching.
        flushSourceTextToBuffer()
        selectedFile = node
        loadSourceForSelectedFile()
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
        guard let pkg = package else { return }
        NSWorkspace.shared.activateFileViewerSelecting([pkg.sourceURL])
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
        guard let pkg = package else { return }
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
        let workingDir = pkg.workingDirectory
        let outURL = pkg.sourceURL

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
            self.isDirty = false
            self.saveState = .idle
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

    private static func preferredInitialSelection(in pkg: EPUBPackage) -> FileNode? {
        let opfDir = pkg.workingDirectory
            .appendingPathComponent(pkg.package.opfPathRelativeToRoot)
            .deletingLastPathComponent()
        if let firstSpineId = pkg.package.spine.first,
           let item = pkg.package.manifestById[firstSpineId] {
            let target = opfDir.appendingPathComponent(item.href).canonicalForFile
            if let node = findLeaf(in: pkg.fileTree, matching: target) {
                return node
            }
        }
        return firstLeaf(in: pkg.fileTree, where: { node in
            let ext = node.id.pathExtension.lowercased()
            return ext == "xhtml" || ext == "html"
        }) ?? firstLeaf(in: pkg.fileTree, where: { _ in true })
    }

    private static func findLeaf(in node: FileNode, matching url: URL) -> FileNode? {
        // Both sides canonicalized so /var ↔ /private/var doesn't
        // sink the comparison. (FileNode.walk already yields canonical
        // URLs because EPUBPackage canonicalizes its working dir, but
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
