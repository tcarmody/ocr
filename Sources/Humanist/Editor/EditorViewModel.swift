import Foundation
import SwiftUI
import AppKit
import EPUB
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
        } catch {
            self.state = .failed(error.localizedDescription)
        }
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
    }

    /// Explicit user attach (toolbar action). Persists into the
    /// sidecar and marks the package dirty so Save flushes it.
    func attachSourcePDF(_ url: URL) {
        guard let pkg = package else { return }
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
