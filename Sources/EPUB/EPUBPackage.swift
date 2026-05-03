import Foundation

/// One opened EPUB on disk: an unpacked working tree plus parsed
/// manifest/spine. Owns its working directory and removes it on
/// deinit. The editor holds one of these per open window.
public final class EPUBPackage: Identifiable, @unchecked Sendable {
    public let id: UUID
    /// Original .epub file the user opened.
    public let sourceURL: URL
    /// Root of the unpacked working tree.
    public let workingDirectory: URL
    /// Parsed package document (metadata, manifest, spine).
    public let package: OPFReader.Package
    /// File-tree rooted at `workingDirectory`. Built once on open;
    /// editing operations that change the tree (Phase 6.B+) will
    /// invalidate this.
    public let fileTree: FileNode

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        workingDirectory: URL,
        package: OPFReader.Package,
        fileTree: FileNode
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.workingDirectory = workingDirectory
        self.package = package
        self.fileTree = fileTree
    }

    deinit {
        // Best-effort cleanup. If the user crashed before deinit fired
        // the temp dir lives until the OS sweeps temp on reboot, which
        // is acceptable.
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    /// Convenience: what to show in the window title bar.
    public var displayTitle: String {
        package.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? sourceURL.deletingPathExtension().lastPathComponent
    }

    /// Open `epubURL`, unpack into a temp directory, parse OPF.
    public static func open(epubURL: URL) throws -> EPUBPackage {
        let unpacker = EPUBUnpacker()
        let workingDir = try unpacker.unpack(
            epubURL: epubURL,
            into: FileManager.default.temporaryDirectory
        )
        let pkg = try OPFReader().read(rootDir: workingDir)
        let tree = FileNode.walk(workingDir)
        return EPUBPackage(
            sourceURL: epubURL,
            workingDirectory: workingDir,
            package: pkg,
            fileTree: tree
        )
    }
}

/// Hierarchical file-tree node for the editor sidebar. Directories have
/// non-nil `children`; leaves have nil. SwiftUI's `OutlineGroup` uses
/// nil-vs-non-nil to decide which rows expand.
public struct FileNode: Identifiable, Sendable, Hashable {
    public let id: URL
    public let name: String
    public let isDirectory: Bool
    public let children: [FileNode]?

    public init(id: URL, name: String, isDirectory: Bool, children: [FileNode]?) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
    }

    /// Walk a directory recursively, sorting directories first then by
    /// name so the tree reads consistently in the sidebar.
    public static func walk(_ url: URL) -> FileNode {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let name = url.lastPathComponent
        guard isDir else {
            return FileNode(id: url, name: name, isDirectory: false, children: nil)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let nodes = contents.map { walk($0) }
        let sorted = nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return FileNode(id: url, name: name, isDirectory: true, children: sorted)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
