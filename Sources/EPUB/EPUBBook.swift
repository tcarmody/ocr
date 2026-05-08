import Foundation

/// In-memory model of an unpacked EPUB. Complements / will eventually
/// replace `EPUBPackage`.
///
/// `EPUBPackage` is a thin wrapper around a working directory: the
/// editor parses the OPF up-front, then every chapter mutation goes
/// straight to disk through `PackageEditor`. That works, but a partial
/// failure midway through a multi-step op (Merge writes file A, deletes
/// file B, fails to update OPF) leaves the on-disk EPUB inconsistent
/// — and in our case, fatally so, since the editor's URL-keyed buffers
/// then disagree with the spine.
///
/// `EPUBBook` is the Sigil-style alternative: load the entire textual
/// content of the EPUB into memory (XHTML, nav, NCX, CSS), keep the
/// manifest + spine as in-memory mutable state, and only flush to disk
/// in a single `save()` call. Mutations on the in-memory model can't
/// half-corrupt disk; failure just throws and the user retries from a
/// clean snapshot.
///
/// Binary assets (images, fonts) stay on disk — we don't gain anything
/// by loading 50MB of cover art into RAM. Resources with binary content
/// carry a disk URL and are referenced from the book by id; rename/
/// delete operations move the file at save time.
///
/// This file is the foundation. The PackageEditor migration to operate
/// on `EPUBBook` instead of disk is a follow-up step.
public final class EPUBBook: @unchecked Sendable {

    public let id: UUID

    /// Original `.epub` file the user opened. Same semantics as
    /// `EPUBPackage.sourceURL`: kept for the window's "Save" target.
    public let sourceURL: URL

    /// Root of the unpacked working tree on disk. Files are loaded
    /// from here at `load(...)` and flushed back here on `save()`.
    public let workingDirectory: URL

    /// OPF path relative to `workingDirectory`. Frozen at load time —
    /// we don't support relocating the OPF.
    public let opfPathRelativeToRoot: String

    /// Verbatim OPF source as it was on disk when the book was
    /// loaded. The saver parses this and surgically rewrites
    /// `<manifest>` + `<spine>` (and metadata fields when dirty),
    /// preserving anything else — custom Dublin Core elements,
    /// `<meta>` properties, comments — that the model doesn't
    /// represent. Without this, callers would lose any OPF content
    /// outside our small struct.
    public let originalOPFText: String

    /// Dublin Core metadata. Mutable so the editor can rename the
    /// book, change the language, etc. Mutations set `metadataIsDirty`
    /// which causes the OPF metadata block to be rewritten at save.
    public var metadata: OPFReader.Metadata {
        didSet { metadataIsDirty = true }
    }

    /// Insertion-ordered list of resource IDs. The manifest in the
    /// serialized OPF is emitted in this order so saves are
    /// deterministic and readable diffs are possible.
    public private(set) var resourceOrder: [String]

    /// All manifest resources, keyed by stable id (the manifest @id
    /// in the OPF). Stable across renames — when a chapter file is
    /// renamed, only `Resource.hrefRelativeToOPF` changes, not the id.
    /// Editor-side maps that key by URL today should switch to keying
    /// by resource id when this layer takes over.
    public private(set) var resourcesByID: [String: Resource]

    /// Reading order: ordered subset of `resourceOrder` containing
    /// only resources that participate in the linear reading flow
    /// (typically all `application/xhtml+xml` chapters except nav).
    public var spine: [String] {
        didSet { structuralIsDirty = true }
    }

    /// Records of resources that have been removed since the last
    /// save. The saver deletes their files from disk if they exist.
    /// Reset to empty after save.
    private var pendingDeletions: [PendingDeletion] = []

    /// Pending file renames staged by `renameResource` and applied
    /// at save time. Each entry maps a resource id to the absolute
    /// disk URL where the file currently lives — the saver renames
    /// it to the resource's *current* `hrefRelativeToOPF` location,
    /// which the rename op already updated in memory. Reset to empty
    /// after save.
    private var pendingRenames: [PendingRename] = []

    /// True if the manifest, spine, or metadata changed since the
    /// last save. Tracked separately from per-resource text
    /// dirtiness because a structural mutation (insert / remove /
    /// reorder) requires re-serializing the OPF even if no resource
    /// text changed.
    public private(set) var structuralIsDirty: Bool = false

    /// True when `metadata` was mutated since the last save. Folded
    /// into `isDirty` and forces an OPF rewrite.
    public private(set) var metadataIsDirty: Bool = false

    /// Whether this instance owns the working directory's lifecycle.
    /// Defaults true for newly-loaded books; set to false on the
    /// outgoing instance when reassigning ownership to a freshly-
    /// loaded book that shares the same on-disk directory. Mirrors
    /// `EPUBPackage.disownWorkingDirectory()`.
    private var ownsWorkingDirectory: Bool = true

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        workingDirectory: URL,
        opfPathRelativeToRoot: String,
        originalOPFText: String,
        metadata: OPFReader.Metadata,
        resourceOrder: [String],
        resourcesByID: [String: Resource],
        spine: [String]
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.workingDirectory = workingDirectory
        self.opfPathRelativeToRoot = opfPathRelativeToRoot
        self.originalOPFText = originalOPFText
        self.metadata = metadata
        self.resourceOrder = resourceOrder
        self.resourcesByID = resourcesByID
        self.spine = spine
    }

    deinit {
        guard ownsWorkingDirectory else { return }
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    public func disownWorkingDirectory() {
        ownsWorkingDirectory = false
    }

    // MARK: - Open from .epub

    /// Open `epubURL`, unpack into a temp directory, parse OPF + load
    /// every text resource into memory. The returned book owns the
    /// working directory's lifecycle (cleaned up on deinit unless
    /// `disownWorkingDirectory()` is called).
    ///
    /// Mirrors `EPUBPackage.open(epubURL:)` so callers can swap the
    /// disk-only model for the in-memory one without touching the
    /// surrounding open + cleanup flow.
    public static func open(epubURL: URL) throws -> EPUBBook {
        let unpacker = EPUBUnpacker()
        let rawWorkingDir = try unpacker.unpack(
            epubURL: epubURL,
            into: FileManager.default.temporaryDirectory
        )
        let workingDir = rawWorkingDir.canonicalForFile
        return try EPUBBookLoader().load(
            sourceURL: epubURL.canonicalForFile,
            workingDirectory: workingDir
        )
    }

    // MARK: - Derived

    /// Combined dirty flag — true if anything has been mutated since
    /// the last save. Useful for the editor's title-bar indicator.
    public var isDirty: Bool {
        if structuralIsDirty || metadataIsDirty { return true }
        if !pendingDeletions.isEmpty { return true }
        return resourcesByID.values.contains(where: { $0.isDirty })
    }

    /// What to show in the window title bar. Falls back to the source
    /// file's basename when no `<dc:title>` is set. Matches the
    /// EPUBPackage.displayTitle semantics.
    public var displayTitle: String {
        if let raw = metadata.title {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return sourceURL.deletingPathExtension().lastPathComponent
    }

    /// Absolute URL of the OPF file on disk.
    public var opfURL: URL {
        workingDirectory.appendingPathComponent(opfPathRelativeToRoot)
    }

    /// Directory the OPF lives in. Manifest hrefs are relative to
    /// this directory.
    public var opfDirectory: URL {
        opfURL.deletingLastPathComponent()
    }

    /// Resolve a manifest href (relative to the OPF) to an absolute
    /// URL on disk. Used by callers that need to read images or
    /// other resources directly from the working directory.
    public func absoluteURL(for resource: Resource) -> URL {
        opfDirectory.appendingPathComponent(resource.hrefRelativeToOPF)
    }

    /// Resources in `resourceOrder` order. Convenience for callers
    /// that want to walk the manifest deterministically.
    public var orderedResources: [Resource] {
        resourceOrder.compactMap { resourcesByID[$0] }
    }

    /// Map of canonical on-disk path → spine index, suitable for
    /// passing to `FileNode.walk(_:spineOrder:)` so the sidebar shows
    /// chapters in reading order rather than alphabetical order.
    /// Keyed by path string — URL hashing isn't enough because two
    /// equivalent file URLs can hash differently depending on how
    /// they were constructed (resolved/standardized form etc.).
    public var spineURLOrder: [String: Int] {
        var out: [String: Int] = [:]
        for (idx, resourceID) in spine.enumerated() {
            guard let resource = resourcesByID[resourceID] else { continue }
            let path = absoluteURL(for: resource)
                .canonicalForFile.standardizedFileURL.path
            out[path] = idx
        }
        return out
    }

    /// Manifest entry flagged with `properties="nav"`, if present.
    public var navResource: Resource? {
        resourcesByID.values.first(where: {
            ($0.properties ?? "").contains("nav")
        })
    }

    /// Look up a resource by its absolute URL on disk. Used by editor
    /// callers that hold a chapter URL and need the corresponding
    /// resource id. Returns nil when the URL doesn't match any
    /// manifest item.
    public func resource(at absoluteURL: URL) -> Resource? {
        let target = absoluteURL.canonicalForFile.standardizedFileURL.path
        for resource in resourcesByID.values {
            let candidate = self.absoluteURL(for: resource)
                .canonicalForFile.standardizedFileURL.path
            if candidate == target { return resource }
        }
        return nil
    }

    /// The resource id that follows `id` in the spine, or nil when
    /// `id` is the last spine entry (or not in the spine at all).
    public func nextSpineResourceID(after id: String) -> String? {
        guard let idx = spine.firstIndex(of: id),
              idx + 1 < spine.count
        else { return nil }
        return spine[idx + 1]
    }

    /// Manifest @id not currently in use. Generates `prefix-001`,
    /// `prefix-002`, … until it finds a free slot.
    public func nextAvailableResourceID(prefix: String) -> String {
        var i = 1
        while true {
            let candidate = String(format: "\(prefix)-%03d", i)
            if resourcesByID[candidate] == nil { return candidate }
            i += 1
        }
    }

    /// Href (relative to the OPF) not currently in use, derived from
    /// `nearHref`'s basename so the new file sorts immediately after
    /// the source file in alphabetical (sidebar) order. Format:
    /// `{dir}/{stem}_split_NNN.{ext}`.
    ///
    /// The `_` separator (0x5F) sorts after `.` (0x2E), which means
    /// `ch05_split_001.xhtml` falls between `ch05.xhtml` and
    /// `ch06.xhtml` in lexicographic order. Without this, the
    /// pre-PR scheme (`chapter-split-NNNNN.xhtml`) clustered every
    /// split's output at the end of the directory regardless of
    /// which source it came from, and the user lost the visual
    /// "this new chapter belongs right next to its source" cue.
    ///
    /// Collision check covers both manifest hrefs and any
    /// pre-existing on-disk files — we don't want to clobber a
    /// sibling the manifest forgot to declare.
    public func nextAvailableHref(near nearHref: String) -> String {
        // Parse the href as a string. `URL(fileURLWithPath:)` would
        // resolve relative paths against the current working
        // directory, which is wrong for OPF-relative hrefs — we'd
        // end up minting names like `/Users/tim/Workspace/ocr/ch02_
        // split_001.xhtml` and the sidebar sort would put the new
        // file in the wrong place.
        let (dir, stem, ext) = Self.parseHrefParts(nearHref)
        let usedHrefs = Set(resourcesByID.values.map(\.hrefRelativeToOPF))
        var i = 1
        while true {
            let basename = "\(stem)_split_\(String(format: "%03d", i)).\(ext)"
            let href: String = dir.isEmpty ? basename : "\(dir)/\(basename)"
            let absoluteOnDisk = opfDirectory.appendingPathComponent(href)
            let collidesOnDisk = FileManager.default
                .fileExists(atPath: absoluteOnDisk.path)
            if !usedHrefs.contains(href), !collidesOnDisk {
                return href
            }
            i += 1
        }
    }

    /// Split a relative href like `text/chapter-005.xhtml` into
    /// `(dir: "text", stem: "chapter-005", ext: "xhtml")`. Empty
    /// `dir` for top-level hrefs. Falls back to `xhtml` extension
    /// when none is present.
    private static func parseHrefParts(
        _ href: String
    ) -> (dir: String, stem: String, ext: String) {
        let dir: String
        let filename: String
        if let lastSlash = href.lastIndex(of: "/") {
            dir = String(href[..<lastSlash])
            filename = String(href[href.index(after: lastSlash)...])
        } else {
            dir = ""
            filename = href
        }
        if let lastDot = filename.lastIndex(of: "."),
           lastDot != filename.startIndex {
            return (
                dir: dir,
                stem: String(filename[..<lastDot]),
                ext: String(filename[filename.index(after: lastDot)...])
            )
        }
        return (dir: dir, stem: filename, ext: "xhtml")
    }

    // MARK: - Mutations (used by future BookPackageEditor)

    /// Insert a new resource into the manifest at the end of the
    /// order. Throws if `resource.id` already exists. Doesn't add
    /// to the spine — caller chooses whether to splice into spine
    /// separately.
    public func appendResource(_ resource: Resource) throws {
        if resourcesByID[resource.id] != nil {
            throw BookError.duplicateResourceID(resource.id)
        }
        resourcesByID[resource.id] = resource
        resourceOrder.append(resource.id)
        structuralIsDirty = true
    }

    /// Insert a new resource into the manifest immediately after
    /// `anchorID` in `resourceOrder`. Throws if `resource.id` already
    /// exists. Falls back to `appendResource` semantics when
    /// `anchorID` isn't found. Doesn't touch the spine.
    ///
    /// Used by Split so the new chapter shows up adjacent to the
    /// source in the OPF manifest (and therefore in any UI that
    /// walks manifest order).
    public func insertResource(_ resource: Resource, after anchorID: String) throws {
        if resourcesByID[resource.id] != nil {
            throw BookError.duplicateResourceID(resource.id)
        }
        resourcesByID[resource.id] = resource
        if let idx = resourceOrder.firstIndex(of: anchorID) {
            resourceOrder.insert(resource.id, at: idx + 1)
        } else {
            resourceOrder.append(resource.id)
        }
        structuralIsDirty = true
    }

    /// Remove a resource from the manifest, the spine (if present),
    /// and stage its on-disk file for deletion at save time. Idempotent
    /// — removing an unknown id is a no-op.
    public func removeResource(id: String) {
        guard let resource = resourcesByID.removeValue(forKey: id) else { return }
        resourceOrder.removeAll { $0 == id }
        spine.removeAll { $0 == id }
        let absoluteURL = opfDirectory
            .appendingPathComponent(resource.hrefRelativeToOPF)
        pendingDeletions.append(.init(id: id, diskURL: absoluteURL))
        structuralIsDirty = true
    }

    /// Insert `id` into the spine immediately after `anchorID`. If
    /// `anchorID` isn't in the spine, appends to the end. Used by
    /// Split.
    public func insertInSpine(id: String, after anchorID: String) {
        guard !spine.contains(id) else { return }
        if let idx = spine.firstIndex(of: anchorID) {
            spine.insert(id, at: idx + 1)
        } else {
            spine.append(id)
        }
    }

    /// Direction of a one-position spine move. `up` swaps with the
    /// previous spine entry; `down` swaps with the next.
    public enum SpineMoveDirection {
        case up
        case down
    }

    /// Move a spine entry by one position. No-op when the resource
    /// isn't in the spine, or when it's already at the boundary in
    /// the requested direction. The manifest order (`resourceOrder`)
    /// is also updated so any UI that walks the manifest sees the
    /// chapter in its new spine position.
    public func moveInSpine(id: String, direction: SpineMoveDirection) {
        guard let idx = spine.firstIndex(of: id) else { return }
        switch direction {
        case .up:
            guard idx > 0 else { return }
            spine.swapAt(idx, idx - 1)
        case .down:
            guard idx + 1 < spine.count else { return }
            spine.swapAt(idx, idx + 1)
        }
        // Mirror the spine reorder in the manifest's resourceOrder
        // so the sidebar's manifest-order view matches reading
        // order. Other (non-spine) manifest entries keep their
        // relative position.
        syncManifestOrderToSpine()
    }

    /// Move a spine entry to an arbitrary target slot. `toIndex` is
    /// the post-removal target — same convention as SwiftUI's
    /// `Array.move(fromOffsets:toOffset:)` and `List.onMove`. So
    /// "move chapter at index 5 to before chapter at index 2" is
    /// `moveInSpine(id: spine[5], toIndex: 2)`. "Move to the end"
    /// is `toIndex: spine.count`. Out-of-range / identity moves are
    /// no-ops. Used by drag-and-drop reorder in the sidebar.
    public func moveInSpine(id: String, toIndex: Int) {
        guard let from = spine.firstIndex(of: id) else { return }
        guard toIndex >= 0, toIndex <= spine.count else { return }
        // Identity move: e.g. dropping chapter onto itself, or
        // inserting at exactly its current spot. Don't churn
        // structural-dirty flags for nothing.
        if toIndex == from || toIndex == from + 1 { return }
        let removed = spine.remove(at: from)
        // Adjust insertion point if it was after the removal
        // position — `toIndex` was computed against the array
        // length pre-remove.
        let adjusted = toIndex > from ? toIndex - 1 : toIndex
        spine.insert(removed, at: adjusted)
        syncManifestOrderToSpine()
    }

    /// Reorder `resourceOrder` so spine entries appear in spine
    /// order, with each non-spine entry pinned to its current
    /// position relative to its neighboring spine entries. Used
    /// after a spine move so the manifest order tracks reading
    /// order without losing where the nav / cover / image entries
    /// sit.
    private func syncManifestOrderToSpine() {
        var spineQueue = spine
        var rebuilt: [String] = []
        for id in resourceOrder {
            if spine.contains(id) {
                if let next = spineQueue.first {
                    rebuilt.append(next)
                    spineQueue.removeFirst()
                }
            } else {
                rebuilt.append(id)
            }
        }
        // Belt-and-suspenders: append any spine entry we somehow
        // missed (shouldn't happen since spine ⊆ resourceOrder).
        rebuilt.append(contentsOf: spineQueue)
        resourceOrder = rebuilt
        structuralIsDirty = true
    }

    /// Rename a resource — updates its `hrefRelativeToOPF`, rewrites
    /// every internal `href` / `src` link in the book that points
    /// to the old href so they continue to resolve, and stages a
    /// disk-side file rename for the next save.
    ///
    /// `newHrefRelativeToOPF` must be unique within the manifest.
    /// Same-href no-ops cleanly. Throws `BookError.duplicateHref`
    /// when the new href collides with another resource.
    ///
    /// Returns the number of internal links rewritten across the
    /// book — useful for surfacing "rewrote N links" feedback in
    /// the UI.
    @discardableResult
    public func renameResource(
        id: String, newHrefRelativeToOPF: String
    ) throws -> Int {
        guard let resource = resourcesByID[id] else {
            throw BookError.unknownResourceID(id)
        }
        let oldHref = resource.hrefRelativeToOPF
        if oldHref == newHrefRelativeToOPF { return 0 }

        // Collision check — exclude the resource being renamed.
        for other in resourcesByID.values where other.id != id {
            if other.hrefRelativeToOPF == newHrefRelativeToOPF {
                throw BookError.duplicateHref(newHrefRelativeToOPF)
            }
        }

        let oldDiskURL = absoluteURL(for: resource)

        // Update the resource itself. After this, hrefRelativeToOPF
        // is the new path; any later call that constructs an
        // absolute URL from this resource will use the new path.
        resource.hrefRelativeToOPF = newHrefRelativeToOPF
        resource.isDirty = true

        // Rewrite internal links across every other text resource.
        // The resource being renamed isn't included — same-doc
        // hrefs (if any) are out of scope; intra-doc fragments are
        // not affected by the file rename.
        var totalChanges = 0
        for other in resourcesByID.values where other.id != id {
            guard let oldText = other.text else { continue }
            let result = LinkRewriter.rewrite(
                text: oldText,
                baseHref: other.hrefRelativeToOPF,
                oldTargetHref: oldHref,
                newTargetHref: newHrefRelativeToOPF
            )
            if result.changes > 0 {
                other.text = result.text  // sets dirty
                totalChanges += result.changes
            }
        }

        // Coalesce successive renames: if this id was already
        // pending a rename, keep the original `oldDiskURL` (the
        // file on disk hasn't moved yet) and drop the intermediate.
        if pendingRenames.contains(where: { $0.id == id }) == false {
            pendingRenames.append(.init(id: id, oldDiskURL: oldDiskURL))
        }
        structuralIsDirty = true
        return totalChanges
    }

    /// Internal accessor used by the saver.
    func consumePendingDeletions() -> [PendingDeletion] {
        defer { pendingDeletions = [] }
        return pendingDeletions
    }

    /// Internal accessor used by the saver.
    func consumePendingRenames() -> [PendingRename] {
        defer { pendingRenames = [] }
        return pendingRenames
    }

    /// Internal: clear all dirty flags. Called by the saver after a
    /// successful flush. Don't call this from outside the saver — it
    /// throws away the dirty record without writing anything.
    func clearDirtyFlags() {
        structuralIsDirty = false
        metadataIsDirty = false
        for resource in resourcesByID.values {
            resource.isDirty = false
        }
    }

    public enum BookError: Error, LocalizedError {
        case duplicateResourceID(String)
        case duplicateHref(String)
        case unknownResourceID(String)
        case missingNav

        public var errorDescription: String? {
            switch self {
            case .duplicateResourceID(let id):
                return "Duplicate manifest id: \(id)"
            case .duplicateHref(let href):
                return "Another manifest item already uses the path \"\(href)\"."
            case .unknownResourceID(let id):
                return "No manifest item with id=\(id)."
            case .missingNav:
                return "EPUB has no manifest item with properties=\"nav\""
            }
        }
    }

    /// Pending file delete to apply at save time.
    struct PendingDeletion {
        let id: String
        let diskURL: URL
    }

    /// Pending file rename to apply at save time. `oldDiskURL` is
    /// where the file lived when the rename was staged; the saver
    /// renames it to wherever the resource's current
    /// `hrefRelativeToOPF` resolves to.
    struct PendingRename {
        let id: String
        let oldDiskURL: URL
    }
}

/// One manifest entry, with stable identity and mutable content. The
/// manifest @id is the resource's identity — renaming the file
/// changes `hrefRelativeToOPF` but not `id`, so callers can hold
/// stable references to a resource across rename operations.
///
/// Class type so resources can be referenced from multiple places
/// (e.g. by the editor's selection state) without the in-memory
/// model fragmenting into copies.
public final class Resource {

    public let id: String
    public var hrefRelativeToOPF: String
    public var mediaType: String
    public var properties: String?
    public var content: Content
    /// True when `content` (or any other persisted attribute that
    /// affects this resource's serialized form on disk) has changed
    /// since the last save. The saver writes only resources where
    /// this is true, then resets to false.
    public var isDirty: Bool

    public enum Content {
        /// Text resource (XHTML, CSS, nav, NCX). Mutated in memory;
        /// flushed to disk by `EPUBBook.save()` when `isDirty` is true.
        case text(String)
        /// Binary resource (images, fonts). Lives on disk at the URL.
        /// `EPUBBook.save()` does not write through binary content —
        /// edits to binaries (cropping, replacement) need to update
        /// the file on disk separately and bump `isDirty` so the saver
        /// at least updates the manifest.
        case binary(diskURL: URL)
    }

    public init(
        id: String,
        hrefRelativeToOPF: String,
        mediaType: String,
        properties: String? = nil,
        content: Content,
        isDirty: Bool = false
    ) {
        self.id = id
        self.hrefRelativeToOPF = hrefRelativeToOPF
        self.mediaType = mediaType
        self.properties = properties
        self.content = content
        self.isDirty = isDirty
    }

    /// Convenience accessor for text content. Returns nil when the
    /// resource is binary. Setting marks the resource dirty and
    /// switches its content to text — callers should avoid setting
    /// text on a binary resource unless they intend the conversion.
    public var text: String? {
        get {
            if case .text(let s) = content { return s }
            return nil
        }
        set {
            guard let new = newValue else { return }
            content = .text(new)
            isDirty = true
        }
    }

    public var isText: Bool {
        if case .text = content { return true }
        return false
    }

    /// True when this resource is the EPUB nav document.
    public var isNav: Bool {
        (properties ?? "").contains("nav")
    }
}
