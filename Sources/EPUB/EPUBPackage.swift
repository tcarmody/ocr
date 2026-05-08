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
    /// Whether this instance owns the working directory's lifecycle
    /// (i.e. should clean it up on deinit). True for newly-opened
    /// packages; the editor flips it to false on the OLD instance
    /// before reassigning to a fresh package that shares the same
    /// directory — otherwise the old deinit deletes the directory
    /// out from under the new instance, leaving every chapter URL
    /// pointing at a removed file. See `disownWorkingDirectory()`.
    private var ownsWorkingDirectory: Bool = true

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

    /// Mark this instance as no longer owning the working directory.
    /// Used by the editor when replacing a stale `EPUBPackage`
    /// instance (after Split / Merge / Regenerate-TOC) with a freshly-
    /// parsed one that shares the same on-disk directory: the new
    /// instance takes over ownership, the old one bows out without
    /// running cleanup. Idempotent.
    public func disownWorkingDirectory() {
        ownsWorkingDirectory = false
    }

    deinit {
        // Best-effort cleanup, only when this instance still owns
        // the directory. If `disownWorkingDirectory` was called, a
        // sibling instance is still using the directory and will
        // handle its own cleanup later. If the user crashed before
        // deinit fired the temp dir lives until the OS sweeps temp
        // on reboot, which is acceptable.
        guard ownsWorkingDirectory else { return }
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
        let rawWorkingDir = try unpacker.unpack(
            epubURL: epubURL,
            into: FileManager.default.temporaryDirectory
        )
        // Canonicalize once at the boundary so workingDirectory and
        // every URL FileNode.walk yields share the same form. Without
        // this the working dir is `/var/folders/...` (symlink) but the
        // tree URLs are `/private/var/folders/...` (resolved by
        // FileManager), and downstream comparisons / prefix checks /
        // dictionary lookups break in confusing ways.
        let workingDir = rawWorkingDir.canonicalForFile
        let pkg = try OPFReader().read(rootDir: workingDir)
        let tree = FileNode.walk(workingDir)
        return EPUBPackage(
            sourceURL: epubURL.canonicalForFile,
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
    ///
    /// `spineOrder`, when supplied, lets chapter files appear in the
    /// reading order recorded by the OPF spine instead of alphabetical
    /// order — necessary so user reorderings (drag-drop, Move Up/Down)
    /// show up in the sidebar. Files whose canonical URL is not in the
    /// map fall back to alphabetical, sorted *below* spine-indexed
    /// siblings so chapters cluster at the top.
    public static func walk(
        _ url: URL,
        spineOrder: [URL: Int]? = nil
    ) -> FileNode {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let name = url.lastPathComponent
        guard isDir else {
            return FileNode(id: url, name: name, isDirectory: false, children: nil)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let nodes = contents.map { walk($0, spineOrder: spineOrder) }
        let sorted = nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            let aIdx = spineOrder?[a.id]
            let bIdx = spineOrder?[b.id]
            switch (aIdx, bIdx) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true   // spine before non-spine
            case (nil, _?):    return false
            case (nil, nil):
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        return FileNode(id: url, name: name, isDirectory: true, children: sorted)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
