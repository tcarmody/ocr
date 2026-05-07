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
    /// `nearHref`'s directory + extension. Format: `{dir}/chapter-
    /// split-NNNNN.{ext}`. Used by Split to name a new chapter
    /// in the same directory as the chapter being split. The check
    /// covers both manifest hrefs and any pre-existing on-disk files
    /// in the working directory — we don't want to clobber a sibling
    /// file the manifest forgot to declare.
    public func nextAvailableHref(near nearHref: String) -> String {
        let nearURL = URL(fileURLWithPath: nearHref)
        let dir = nearURL.deletingLastPathComponent().path
        let ext = nearURL.pathExtension.isEmpty ? "xhtml" : nearURL.pathExtension
        let usedHrefs = Set(resourcesByID.values.map(\.hrefRelativeToOPF))
        var i = 1
        while true {
            let basename = String(format: "chapter-split-%05d.\(ext)", i)
            let href: String = dir.isEmpty || dir == "."
                ? basename
                : "\(dir)/\(basename)"
            let absoluteOnDisk = opfDirectory.appendingPathComponent(href)
            let collidesOnDisk = FileManager.default
                .fileExists(atPath: absoluteOnDisk.path)
            if !usedHrefs.contains(href), !collidesOnDisk {
                return href
            }
            i += 1
        }
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

    /// Internal accessor used by the saver.
    func consumePendingDeletions() -> [PendingDeletion] {
        defer { pendingDeletions = [] }
        return pendingDeletions
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
        case missingNav

        public var errorDescription: String? {
            switch self {
            case .duplicateResourceID(let id):
                return "Duplicate manifest id: \(id)"
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
