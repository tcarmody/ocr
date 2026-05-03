import Foundation
import AppKit
import EPUB
import UniformTypeIdentifiers

/// Per-window state for the EPUB editor: the open package + which file
/// the user is looking at + on-disk content of that file.
///
/// View-only for v1. Phase 6.B will add edit + save: the source pane's
/// edits will go through here so we can mark dirty / repack.
@MainActor
final class EditorViewModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: LoadState = .loading
    @Published private(set) var package: EPUBPackage?
    @Published var selectedFile: FileNode?

    /// Decoded text of `selectedFile` if it's a text-y file; nil
    /// otherwise. Used by the source pane.
    @Published private(set) var selectedSource: String?

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
            // Default selection: first XHTML in spine, fall back to nav,
            // fall back to first leaf in tree.
            self.selectedFile = Self.preferredInitialSelection(in: pkg)
            self.refreshSource()
        } catch {
            self.state = .failed(error.localizedDescription)
        }
    }

    func select(_ node: FileNode) {
        guard !node.isDirectory else { return }
        selectedFile = node
        refreshSource()
    }

    /// Opens the source .epub in the user's default file viewer (Finder).
    func revealInFinder() {
        guard let pkg = package else { return }
        NSWorkspace.shared.activateFileViewerSelecting([pkg.sourceURL])
    }

    // MARK: - source decoding

    private func refreshSource() {
        guard let node = selectedFile, !node.isDirectory else {
            selectedSource = nil
            return
        }
        if Self.isTextFile(node.id) {
            do {
                let data = try Data(contentsOf: node.id)
                selectedSource = String(data: data, encoding: .utf8)
                    ?? "(Could not decode \(node.name) as UTF-8)"
            } catch {
                selectedSource = "(Read failed: \(error.localizedDescription))"
            }
        } else {
            selectedSource = nil  // binary; preview pane shows it instead
        }
    }

    /// File-extension whitelist for "show this as text in the source
    /// pane." Anything else (images, fonts, audio) → preview only.
    static func isTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.textExtensions.contains(ext)
            // mimetype, container.xml, content.opf — no extension or odd ones
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
        // First try first spine item.
        if let firstSpineId = pkg.package.spine.first,
           let item = pkg.package.manifestById[firstSpineId] {
            let target = opfDir.appendingPathComponent(item.href).standardized
            if let node = findLeaf(in: pkg.fileTree, matching: target) {
                return node
            }
        }
        // Fall back to first XHTML leaf in the tree.
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
