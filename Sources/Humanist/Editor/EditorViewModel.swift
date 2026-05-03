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

    /// In-memory edit buffers, keyed by absolute file URL. Populated
    /// lazily on first read. Survives navigation between files.
    private var buffers: [URL: String] = [:]
    /// URLs whose buffer differs from disk (subset of `buffers` keys).
    private var dirtyURLs: Set<URL> = []

    init(epubURL: URL) {
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
        } catch {
            self.state = .failed(error.localizedDescription)
        }
    }

    func select(_ node: FileNode) {
        guard !node.isDirectory else { return }
        selectedFile = node
    }

    func revealInFinder() {
        guard let pkg = package else { return }
        NSWorkspace.shared.activateFileViewerSelecting([pkg.sourceURL])
    }

    // MARK: - source buffers

    /// Decoded text of the selected file from the in-memory buffer.
    /// Reads from disk on first access and caches.
    var selectedSource: String? {
        guard let url = selectedFile?.id, !(selectedFile?.isDirectory ?? true) else {
            return nil
        }
        if let buf = buffers[url] { return buf }
        guard Self.isTextFile(url) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8)
                ?? "(Could not decode \(url.lastPathComponent) as UTF-8)"
            buffers[url] = text
            return text
        } catch {
            return "(Read failed: \(error.localizedDescription))"
        }
    }

    /// SwiftUI binding for the source TextEditor. The setter mirrors
    /// edits into the buffer + dirty set; the getter is the same as
    /// `selectedSource` so first-read populates the buffer.
    var sourceBinding: Binding<String> {
        Binding(
            get: { [weak self] in self?.selectedSource ?? "" },
            set: { [weak self] in self?.updateSelectedSource($0) }
        )
    }

    private func updateSelectedSource(_ text: String) {
        guard let url = selectedFile?.id else { return }
        if buffers[url] == text { return }
        buffers[url] = text
        dirtyURLs.insert(url)
        isDirty = true
    }

    // MARK: - save (Phase 6.B)

    /// Write every dirty buffer to disk inside the working directory,
    /// then repack the working directory into the source .epub.
    /// Atomic at the .epub level: a successful return means readers
    /// will see the new contents on next open.
    func save() async {
        guard let pkg = package else { return }
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
            let target = opfDir.appendingPathComponent(item.href).standardized
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
        if !node.isDirectory && node.id.standardized == url { return node }
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
