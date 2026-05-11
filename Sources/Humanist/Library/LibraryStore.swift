import Foundation
import Combine
import EPUB  // canonicalForFile
import Pipeline  // BookGenre

/// R-Library. JSON-backed list of every EPUB the user has
/// converted in this app, surfaced through the dedicated Library
/// browser window. Distinct from `RecentsStore` (last-10 menu cap)
/// and from `JobStore` (per-conversion queue, transient — Clear
/// Done removes finished rows).
///
/// Entries are written when a conversion finishes successfully,
/// updated on every editor-open of the resulting EPUB, and pruned
/// only by explicit user action (Remove from Library) — the file
/// itself isn't touched.
///
/// R-Library-Chat-Plus Collections: the store persists named
/// groupings of books (`BookCollection`).
///
/// R-Library-Sync (Phase A): the catalog file lives in
/// `~/Library/Application Support/Humanist/library.json` by
/// default. When the user enables "Share library across machines"
/// in Settings + has a configured output root, the file moves to
/// `<outputRoot>/.humanist/library.json` so a cloud-synced folder
/// can carry the catalog between Macs. Entry epub URLs additionally
/// store a `relativePath` from the output root when applicable, so
/// the same JSON resolves correctly on each machine even when the
/// absolute home-dir / iCloud-path differs.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var collections: [BookCollection] = []

    /// Where the JSON actually lives on disk. Set at init based on
    /// `shareAcrossMachines` + output-root state. Stays stable
    /// across reads/writes for the store's lifetime — toggling the
    /// sync setting at runtime requires app relaunch (the
    /// migration helper performs the move + reload cleanly there).
    let storeURL: URL

    /// True when the store is currently reading + writing under an
    /// output-root location. Drives entry-resolution to prefer
    /// `relativePath` over the stored absolute URL on load.
    let sharingAcrossMachines: Bool

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
            self.sharingAcrossMachines = false
        } else {
            let resolved = LibraryStore.resolveStoreURL()
            self.storeURL = resolved.url
            self.sharingAcrossMachines = resolved.sharing
        }
        load()
    }

    /// Resolve where library.json should live. Honors the
    /// `shareAcrossMachines` Settings toggle: when on + an output
    /// root is configured, returns `<outputRoot>/.humanist/library.json`.
    /// Otherwise the historical Application Support location.
    static func resolveStoreURL() -> (url: URL, sharing: Bool) {
        let shareEnabled = UserDefaults.standard.bool(
            forKey: ConversionSettingsKeys.shareLibraryAcrossMachines
        )
        if shareEnabled,
           let root = ConversionOutputResolver.currentRoot() {
            let dir = root
                .appendingPathComponent(".humanist", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            return (dir.appendingPathComponent("library.json"), true)
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("Humanist", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return (dir.appendingPathComponent("library.json"), false)
    }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        var loadedEntries: [LibraryEntry] = []
        var loadedCollections: [BookCollection] = []
        if let payload = try? decoder.decode(StoredPayload.self, from: data) {
            loadedEntries = payload.entries
            loadedCollections = payload.collections
        } else if let legacy = try? decoder.decode([LibraryEntry].self, from: data) {
            // Pre-BookCollections file shape: a bare array of entries.
            loadedEntries = legacy
        } else {
            return
        }
        // R-Auto-Collections Phase 1: backfill conversionType on
        // legacy entries that pre-date the stamping. Cheap
        // heuristic: an EPUB with a .pdf sibling at the same
        // basename was almost certainly produced via the OCR
        // pipeline (.print is the dominant case; manuscript +
        // early-print are rare enough that the user can re-
        // convert + restamp if they care). No sibling PDF →
        // .digital (imported or document-ingest). Re-stamping
        // happens automatically as soon as the user re-converts
        // / re-imports the book.
        loadedEntries = loadedEntries.map { entry in
            guard entry.conversionType == nil else { return entry }
            var copy = entry
            copy.conversionType = Self.inferConversionType(for: entry.epubURL)
            return copy
        }
        // R-Library-Sync resolution: when sharing is on + the
        // entry has a `relativePath`, rewrite the in-memory
        // `epubURL` to the current machine's `<root>/<relativePath>`
        // before the existence check. This is the load-bearing
        // step that makes a synced catalog portable across Macs.
        let resolved = sharingAcrossMachines
            ? loadedEntries.map(Self.resolveAgainstOutputRoot)
            : loadedEntries
        // Drop entries whose .epub no longer exists on disk so the
        // window doesn't show dead rows. Same posture as
        // RecentsStore.urls.
        let filtered = resolved.filter {
            FileManager.default.fileExists(atPath: $0.epubURL.path)
        }
        let liveIDs = Set(filtered.map(\.id))
        // Garbage-collect collection memberships pointing at entries
        // that vanished from disk between sessions; drop empty
        // collections that result.
        let prunedCollections = loadedCollections.map { collection -> BookCollection in
            var c = collection
            c.bookIDs = c.bookIDs.filter { liveIDs.contains($0) }
            return c
        }
        entries = filtered
        collections = prunedCollections
        let entriesPruned = filtered.count != loadedEntries.count
        let totalMembershipBefore = loadedCollections.reduce(0) { $0 + $1.bookIDs.count }
        let totalMembershipAfter = prunedCollections.reduce(0) { $0 + $1.bookIDs.count }
        if entriesPruned || totalMembershipAfter != totalMembershipBefore {
            // Persisted shape diverged from filtered — write the
            // pruned wrapper back so the next launch starts clean.
            save()
        }
    }

    /// Heuristic backfill for legacy entries without a stamped
    /// `conversionType`. An EPUB whose basename matches a PDF on
    /// disk (somewhere reasonable) is `.print`; otherwise
    /// `.digital`. Imperfect — the user can re-convert / re-import
    /// to overwrite — but covers the common layouts:
    ///
    ///  * Sibling: PDF + EPUB in the same directory.
    ///  * Configured output root: PDFs at `<root>/foo.pdf`,
    ///    EPUBs at `<root>/Books/foo.epub` (the canonical layout
    ///    when a configured output folder is set). Also accepts
    ///    the `.split.pdf` variant Humanist's split-PDF tool
    ///    emits, since `<root>/Books/foo.epub` was likely
    ///    produced from `<root>/foo.split.pdf`.
    static func inferConversionType(for epubURL: URL) -> BookConversionType {
        let pdfSibling = epubURL
            .deletingPathExtension()
            .appendingPathExtension("pdf")
        if FileManager.default.fileExists(atPath: pdfSibling.path) {
            return .print
        }
        // Check at the configured output root — the
        // PDFs-at-root + EPUBs-under-Books/ layout that most
        // Humanist users have once an output folder is set.
        if let root = ConversionOutputResolver.currentRoot() {
            let basename = epubURL
                .deletingPathExtension()
                .lastPathComponent
            // Direct match: <root>/<basename>.pdf
            let direct = root
                .appendingPathComponent(basename)
                .appendingPathExtension("pdf")
            if FileManager.default.fileExists(atPath: direct.path) {
                return .print
            }
            // `.split` variant: the EPUB at
            // `Books/Foo.split.epub` came from `Foo.split.pdf`,
            // which itself was a split off `Foo.pdf`. Either is
            // evidence of a print source.
            let stripped = basename
                .replacingOccurrences(of: ".split", with: "")
            if stripped != basename {
                let strippedPDF = root
                    .appendingPathComponent(stripped)
                    .appendingPathExtension("pdf")
                if FileManager.default.fileExists(atPath: strippedPDF.path) {
                    return .print
                }
            }
            // Reverse: EPUB has no `.split` but the PDF does.
            let splitPDF = root
                .appendingPathComponent(basename + ".split")
                .appendingPathExtension("pdf")
            if FileManager.default.fileExists(atPath: splitPDF.path) {
                return .print
            }
        }
        return .digital
    }

    /// Rewrite `entry.epubURL` to point at the current machine's
    /// `<outputRoot>/<relativePath>` when both are available.
    /// Falls through unchanged when the entry has no relative
    /// path or no root is configured. Exposed `internal` for the
    /// portability-invariant tests.
    static func resolveAgainstOutputRoot(
        _ entry: LibraryEntry
    ) -> LibraryEntry {
        guard let rel = entry.relativePath, !rel.isEmpty,
              let root = ConversionOutputResolver.currentRoot()
        else { return entry }
        var copy = entry
        copy.epubURL = root.appendingPathComponent(rel)
            .canonicalForFile
        return copy
    }

    private func save() {
        // Recompute `relativePath` against the current root on
        // every save so a moved file or a freshly-configured root
        // gets picked up. Stored as forward slashes regardless of
        // platform — paths inside the JSON are filesystem-portable.
        let withRelative = entries.map(Self.populateRelativePath)
        let payload = StoredPayload(entries: withRelative, collections: collections)
        // Default date strategy (number-of-seconds-since-reference-
        // date) matches the default JSONDecoder, so the persistence
        // round-trip is symmetric without further configuration.
        guard let data = try? JSONEncoder().encode(payload) else { return }
        // Snapshot the previous on-disk state before overwriting.
        // Defends against three known failure modes: a buggy save
        // that wipes fields, an iCloud sync conflict that lands a
        // stale copy on top, and a load()-prune cycle that drops
        // entries the user hasn't yet finished editing. The
        // snapshot store is fire-and-forget — a failed snapshot
        // must NEVER block the real save.
        LibrarySnapshotStore(catalogURL: storeURL).snapshotIfPresent()
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Re-read `library.json` from disk. Used by the restore-from-
    /// snapshot flow: the snapshot store overwrites `library.json`
    /// in place, then calls `reload()` to refresh in-memory state
    /// so the UI flips to the restored catalog immediately without
    /// an app relaunch. Equivalent to running the init's load step
    /// over the live instance.
    func reload() {
        load()
    }

    /// Compute `entry.relativePath` against the current output
    /// root if the EPUB sits under it. Falls through with the
    /// existing `relativePath` (preserved) when the EPUB lives
    /// outside the root — important so a user who toggles sync
    /// off and back on doesn't lose path data they already have.
    private static func populateRelativePath(
        _ entry: LibraryEntry
    ) -> LibraryEntry {
        guard let root = ConversionOutputResolver.currentRoot() else {
            return entry
        }
        let rootPath = root.canonicalForFile.path
        let entryPath = entry.epubURL.canonicalForFile.path
        guard entryPath.hasPrefix(rootPath + "/") else {
            return entry
        }
        let relative = String(entryPath.dropFirst(rootPath.count + 1))
        var copy = entry
        copy.relativePath = relative
        return copy
    }

    // MARK: - bulk-update mode

    /// Staged-entries buffer used during bulk operations. When
    /// non-nil, `mutateEntries(_:)` routes writes here instead of
    /// the published `entries` array — so a 1000-book import that
    /// would otherwise fire 1000 publishes (each one re-rendering
    /// every observer of LibraryStore, including the Library
    /// window's 2k-row Table) fires exactly one publish at
    /// `endBulkUpdate()`. Saves are also deferred to a single
    /// write at end-of-bulk. Nil means "not in bulk mode."
    private var pendingEntries: [LibraryEntry]?
    /// Staged-collections buffer. Same rationale as
    /// `pendingEntries` — keeps `remove(_:)` and similar multi-
    /// collection mutations from firing N+1 publishes through
    /// every observer. Nil means "not in bulk mode."
    private var pendingCollections: [BookCollection]?

    /// Begin a bulk-update window. Callers MUST pair this with
    /// `endBulkUpdate()` on every exit path (success, cancellation,
    /// thrown error) so the staged entries get committed. The
    /// recommended idiom is `defer { library.endBulkUpdate() }`
    /// at the top of the bulk loop. Nested begin/end pairs share
    /// the same buffer — the first begin snapshots, subsequent
    /// begins are no-ops; only the outermost end commits.
    func beginBulkUpdate() {
        if pendingEntries == nil {
            pendingEntries = entries
        }
        if pendingCollections == nil {
            pendingCollections = collections
        }
    }

    /// Commit pending mutations from the bulk window. Fires a
    /// single @Published republish on `entries` and on
    /// `collections` (if either was staged) and a single save() to
    /// disk. Safe to call when not in bulk mode — it's a no-op
    /// then. Idempotent on re-call within the same bulk.
    func endBulkUpdate() {
        var didStage = false
        if let pendingE = pendingEntries {
            pendingEntries = nil
            entries = pendingE
            didStage = true
        }
        if let pendingC = pendingCollections {
            pendingCollections = nil
            collections = pendingC
            didStage = true
        }
        if didStage { save() }
    }

    /// Route a closure-shaped mutation against either the staged
    /// buffer (bulk mode) or `entries` directly (normal mode). The
    /// closure does reads + writes against an `inout [LibraryEntry]`;
    /// the helper picks the right target and handles the save side
    /// effect outside bulk mode. Discardable result so callers can
    /// signal "did I change anything" back through the same path.
    @discardableResult
    private func mutateEntries<T>(
        _ op: (inout [LibraryEntry]) -> T
    ) -> T {
        if pendingEntries != nil {
            // Force-unwrap is safe: we just checked non-nil and
            // we're @MainActor-isolated, so no other actor can
            // null it between check and use.
            return op(&pendingEntries!)
        }
        let result = op(&entries)
        save()
        return result
    }

    /// Companion helper for `collections`. Same routing rule:
    /// bulk-mode writes land in the staged buffer, normal-mode
    /// writes fire one @Published publish and one save() per
    /// call. Used by mutations like `remove(_:)` that touch
    /// multiple collections in a single user action — without
    /// this, a remove with N collections would fire N publishes
    /// through every observer.
    @discardableResult
    private func mutateCollections<T>(
        _ op: (inout [BookCollection]) -> T
    ) -> T {
        if pendingCollections != nil {
            return op(&pendingCollections!)
        }
        let result = op(&collections)
        save()
        return result
    }

    // MARK: - mutations: entries

    /// Record a successful conversion. If the same `epubURL` is
    /// already in the library (re-conversion), update its title +
    /// languages + (when supplied) conversionType + author in
    /// place rather than duplicating; the original `addedAt` is
    /// preserved so the row's history is honest.
    ///
    /// `conversionType` and `author` are optional so existing
    /// callers (e.g. auto-catalog on editor open) that don't have
    /// the provenance handy can omit them; the auto-collection
    /// generator's backfill heuristic fills in the rest.
    func recordConversion(
        epubURL: URL,
        title: String,
        languages: [String],
        conversionType: BookConversionType? = nil,
        author: String? = nil,
        genre: BookGenre? = nil
    ) {
        let canonical = epubURL.canonicalForFile
        mutateEntries { entries in
            if let idx = entries.firstIndex(where: {
                $0.epubURL.canonicalForFile == canonical
            }) {
                entries[idx].title = title
                entries[idx].languages = languages
                // Only overwrite when the caller provided a value —
                // existing stamps survive re-conversions where the
                // caller didn't bother to re-derive provenance.
                if let conversionType {
                    entries[idx].conversionType = conversionType
                }
                if let author {
                    entries[idx].author = author
                }
                if let genre {
                    entries[idx].genre = genre
                }
            } else {
                entries.append(LibraryEntry(
                    epubURL: canonical,
                    title: title,
                    languages: languages,
                    addedAt: Date(),
                    lastOpened: nil,
                    conversionType: conversionType,
                    author: author,
                    genre: genre
                ))
            }
        }
    }

    /// R-Auto-Collections Phase 2. Stamp the genre on an existing
    /// catalog row. Used by the backfill command which classifies
    /// missing genres post-hoc — separate from
    /// `recordConversion` because the genre arrives after the
    /// initial catalog write.
    func setGenre(_ genre: BookGenre, for entryID: UUID) {
        mutateEntries { entries in
            guard let idx = entries.firstIndex(where: { $0.id == entryID })
            else { return }
            entries[idx].genre = genre
        }
    }

    /// R-Auto-Collections backfill mutator. Updates whichever
    /// metadata fields are non-nil on `update`; leaves the rest
    /// untouched. Used by the Refresh backfill flow to populate
    /// missing author / title / conversionType from OPF re-reads
    /// without overwriting fields that were already stamped.
    /// Returns true when the entry actually changed.
    @discardableResult
    func backfillMetadata(
        for entryID: UUID,
        title: String? = nil,
        author: String? = nil,
        conversionType: BookConversionType? = nil
    ) -> Bool {
        // `mutateEntries` always saves on the non-bulk path; we
        // want save-only-when-changed semantics preserved. Detect
        // change inside the closure and short-circuit the trip
        // through the helper when nothing actually moved.
        var changed = false
        mutateEntries { entries in
            guard let idx = entries.firstIndex(where: { $0.id == entryID })
            else { return }
            if let title, !title.isEmpty, entries[idx].title != title {
                entries[idx].title = title
                changed = true
            }
            if let author, !author.isEmpty, entries[idx].author == nil {
                entries[idx].author = author
                changed = true
            }
            if let conversionType, entries[idx].conversionType != conversionType {
                entries[idx].conversionType = conversionType
                changed = true
            }
        }
        return changed
    }

    /// Direct-write metadata edit driven by the user via the
    /// metadata editor sheet. Unlike `backfillMetadata` (which
    /// preserves existing stamps), this overwrites every supplied
    /// field — passing `nil` for an optional clears it, passing an
    /// empty string for `title` is rejected (title is required).
    /// Triggers a single `save()` after the edit so a typo + immediate
    /// re-edit doesn't fan out into two writes.
    @discardableResult
    func updateEntryMetadata(
        for entryID: UUID,
        title: String,
        author: String?,
        languages: [String],
        conversionType: BookConversionType?,
        genre: BookGenre?
    ) -> Bool {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty else { return false }
        let cleanedAuthor: String? = {
            let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }()
        let cleanedLanguages = languages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var didFind = false
        mutateEntries { entries in
            guard let idx = entries.firstIndex(where: { $0.id == entryID })
            else { return }
            entries[idx].title = cleanedTitle
            entries[idx].author = cleanedAuthor
            entries[idx].languages = cleanedLanguages
            entries[idx].conversionType = conversionType
            entries[idx].genre = genre
            didFind = true
        }
        return didFind
    }

    /// Bump `lastOpened` for `epubURL`. No-op if the entry doesn't
    /// exist — opening an EPUB the library doesn't know about (e.g.
    /// a third-party file the user dragged in for editing) doesn't
    /// retroactively add it; the library is for "books I converted
    /// in this app," not "every EPUB I ever opened."
    func recordOpen(_ epubURL: URL) {
        let canonical = epubURL.canonicalForFile
        mutateEntries { entries in
            guard let idx = entries.firstIndex(where: {
                $0.epubURL.canonicalForFile == canonical
            }) else { return }
            entries[idx].lastOpened = Date()
        }
    }

    /// Remove an entry from the library. The .epub file itself is
    /// untouched — we only forget about it. Also drops the entry's
    /// id from every collection so we don't carry dangling refs.
    ///
    /// Wraps the entries + collections mutations in a bulk window
    /// so the user sees one publish, not N+1 (one per entries
    /// removal + one per collection touched). At library scale
    /// with many auto-collections, the cascade through every
    /// `@EnvironmentObject library` observer added up to seconds
    /// of UI thrash per removal — particularly painful when the
    /// removal happened while a long-running chat send was
    /// already in flight on the main actor.
    func remove(_ id: UUID) {
        beginBulkUpdate()
        defer { endBulkUpdate() }
        mutateEntries { entries in
            entries.removeAll { $0.id == id }
        }
        mutateCollections { collections in
            for idx in collections.indices {
                collections[idx].bookIDs.removeAll { $0 == id }
            }
        }
    }

    // MARK: - mutations: collections

    /// Create a new collection. Returns the freshly-minted instance
    /// so callers can immediately reference it (e.g. select it in
    /// the sidebar). Optional `bookIDs` lets callers seed membership
    /// in one step — handy for "New Collection from Selection."
    @discardableResult
    func createCollection(
        name: String, bookIDs: [UUID] = []
    ) -> BookCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? "Untitled Collection" : trimmed
        let live = Set(entries.map(\.id))
        let collection = BookCollection(
            name: final,
            bookIDs: bookIDs.filter { live.contains($0) },
            createdAt: Date()
        )
        collections.append(collection)
        save()
        return collection
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        collections[idx].name = trimmed
        save()
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        save()
    }

    /// Append `bookIDs` to `collectionID`'s membership. Duplicates
    /// are filtered out so add-twice is a no-op. Ids referencing
    /// missing entries are dropped. Order is preserved: existing
    /// members stay first, new ones appended in input order.
    func addToCollection(_ collectionID: UUID, bookIDs: [UUID]) {
        guard let idx = collections.firstIndex(where: { $0.id == collectionID })
        else { return }
        let live = Set(entries.map(\.id))
        let existing = Set(collections[idx].bookIDs)
        let additions = bookIDs.filter { live.contains($0) && !existing.contains($0) }
        guard !additions.isEmpty else { return }
        collections[idx].bookIDs.append(contentsOf: additions)
        save()
    }

    /// Wholesale replace the collections list. Used exclusively
    /// by `LibraryAutoCollections.refresh` to re-materialize
    /// auto-collections while preserving user-created ones (the
    /// caller composes the desired final list and hands it back
    /// here in one shot). No partial-state intermediate save.
    func replaceCollections(_ newCollections: [BookCollection]) {
        collections = newCollections
        save()
    }

    func removeFromCollection(_ collectionID: UUID, bookIDs: [UUID]) {
        guard let idx = collections.firstIndex(where: { $0.id == collectionID })
        else { return }
        let drop = Set(bookIDs)
        let before = collections[idx].bookIDs.count
        collections[idx].bookIDs.removeAll { drop.contains($0) }
        if collections[idx].bookIDs.count != before {
            save()
        }
    }

    // MARK: - storage shape

    /// File payload: entries + collections in one wrapper. Reading
    /// also tolerates the legacy bare-array shape (see `load`).
    private struct StoredPayload: Codable {
        var entries: [LibraryEntry]
        var collections: [BookCollection]
    }
}

/// One library row.
struct LibraryEntry: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var epubURL: URL
    /// Display title — typically the source PDF's basename minus
    /// `.pdf`. Falls back to the .epub filename when the original
    /// title isn't known. The user can rename in a future
    /// iteration; for now the stored value sticks.
    var title: String
    /// BCP-47 language ids (`en`, `grc`, `la`, etc.) snapshotted
    /// from the conversion's options. Used for the Library
    /// window's filter.
    var languages: [String]
    var addedAt: Date
    /// Last time the user opened this EPUB through the editor (via
    /// `OpenRouter` / Library row click). Nil until the first open
    /// after conversion.
    var lastOpened: Date?
    /// R-Library-Sync. Path RELATIVE to the configured conversion
    /// output root, when the EPUB sits under it (e.g.
    /// `Books/Foucault.epub`). Stored alongside the absolute URL
    /// so callers that don't care about sync keep working. When
    /// `LibraryStore` loads in sharing-across-machines mode, the
    /// in-memory `epubURL` is recomputed from
    /// `<currentRoot>/<relativePath>` so a catalog created on
    /// machine A resolves correctly on machine B even when the
    /// absolute root path differs (different home dir / iCloud
    /// container).
    var relativePath: String?
    /// R-Auto-Collections Phase 1. What produced this book —
    /// stamped at conversion / import time by the writer. Nil
    /// for pre-feature entries (filled in by the load-time
    /// backfill heuristic where possible).
    var conversionType: BookConversionType?
    /// R-Auto-Collections Phase 1. Author derived from
    /// `<dc:creator>` at catalog time. Stored alongside `title`
    /// so the auto-collection generator can group without
    /// re-opening every EPUB. Nil when no creator was present
    /// in the OPF.
    var author: String?
    /// R-Auto-Collections Phase 2. AFM-classified genre. nil
    /// when the entry hasn't been classified yet, or when the
    /// classifier returned `.uncategorized` (no auto-collection
    /// row for those — they appear in All Books only). The
    /// classifier runs on-import via `EPUBImporter` and via the
    /// backfill command `LibraryAutoCollections
    /// .classifyMissingGenres`.
    var genre: BookGenre?

    init(
        id: UUID = UUID(),
        epubURL: URL,
        title: String,
        languages: [String] = [],
        addedAt: Date,
        lastOpened: Date? = nil,
        relativePath: String? = nil,
        conversionType: BookConversionType? = nil,
        author: String? = nil,
        genre: BookGenre? = nil
    ) {
        self.id = id
        self.epubURL = epubURL
        self.title = title
        self.languages = languages
        self.addedAt = addedAt
        self.lastOpened = lastOpened
        self.relativePath = relativePath
        self.conversionType = conversionType
        self.author = author
        self.genre = genre
    }

    // MARK: - Codable (decodeIfPresent for relativePath)

    /// Custom decoder so libraries written before R-Library-Sync
    /// (which had no `relativePath` field) decode cleanly. The
    /// default synthesized init would fail on the missing key —
    /// `decodeIfPresent` lets the new field default to nil for
    /// pre-existing entries; subsequent saves repopulate it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.epubURL = try c.decode(URL.self, forKey: .epubURL)
        self.title = try c.decode(String.self, forKey: .title)
        self.languages = try c.decode([String].self, forKey: .languages)
        self.addedAt = try c.decode(Date.self, forKey: .addedAt)
        self.lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened)
        self.relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath)
        if let raw = try c.decodeIfPresent(String.self, forKey: .conversionType),
           let parsed = BookConversionType(rawValue: raw) {
            self.conversionType = parsed
        } else {
            self.conversionType = nil
        }
        self.author = try c.decodeIfPresent(String.self, forKey: .author)
        if let raw = try c.decodeIfPresent(String.self, forKey: .genre),
           let parsed = BookGenre(rawValue: raw) {
            self.genre = parsed
        } else {
            self.genre = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, epubURL, title, languages, addedAt, lastOpened, relativePath
        case conversionType, author, genre
    }
}

/// Named grouping of `LibraryEntry`s. The user creates collections
/// for recurring research scopes ("Foucault corpus", "for the
/// chapter on biopolitics"); clicking one filters the Library
/// window's table and unlocks a "Chat with this collection" action.
///
/// Membership is stored as an *ordered* list of `LibraryEntry.id` so
/// the sidebar / chat scope can preserve add order. Duplicate
/// references are filtered at the mutation site
/// (`LibraryStore.addToCollection`).
struct BookCollection: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var bookIDs: [UUID]
    var createdAt: Date
    /// R-Auto-Collections. nil for user-created collections (the
    /// historical case). When set, this collection was produced
    /// by the auto-collection generator and gets regenerated on
    /// every "Refresh auto-collections" run — user edits don't
    /// survive. UI groups auto-collections under their own
    /// sidebar sections.
    var autoSource: AutoCollectionSource?

    init(
        id: UUID = UUID(),
        name: String,
        bookIDs: [UUID] = [],
        createdAt: Date = Date(),
        autoSource: AutoCollectionSource? = nil
    ) {
        self.id = id
        self.name = name
        self.bookIDs = bookIDs
        self.createdAt = createdAt
        self.autoSource = autoSource
    }

    // MARK: - Codable (decodeIfPresent for autoSource)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.bookIDs = try c.decode([UUID].self, forKey: .bookIDs)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.autoSource = try c.decodeIfPresent(
            AutoCollectionSource.self, forKey: .autoSource
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, bookIDs, createdAt, autoSource
    }

    /// SF Symbol name for sidebar rendering. Auto-collections get
    /// a category-specific icon so the user can distinguish a
    /// machine-generated grouping from a hand-curated one at a
    /// glance.
    var rowIcon: String {
        switch autoSource {
        case nil: return "rectangle.stack"
        case .byType: return "tag"
        case .byAuthor: return "person"
        case .byGenre: return "book"
        }
    }
}

/// R-Auto-Collections. Tags a `BookCollection` as auto-generated
/// + records what produced it. Cases mirror the auto-collection
/// taxonomy (Type / Author / Genre — Genre arrives in Phase 2).
///
/// Codable as a tagged union via a single string discriminator;
/// keeps the JSON round-trip stable as new cases land.
enum AutoCollectionSource: Codable, Equatable, Hashable, Sendable {
    case byType(BookConversionType)
    case byAuthor(String)
    case byGenre(BookGenre)

    private enum DiscriminatorKey: String, CodingKey {
        case kind, value
    }

    private enum Kind: String, Codable {
        case byType, byAuthor, byGenre
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DiscriminatorKey.self)
        switch self {
        case .byType(let t):
            try c.encode(Kind.byType, forKey: .kind)
            try c.encode(t.rawValue, forKey: .value)
        case .byAuthor(let name):
            try c.encode(Kind.byAuthor, forKey: .kind)
            try c.encode(name, forKey: .value)
        case .byGenre(let g):
            try c.encode(Kind.byGenre, forKey: .kind)
            try c.encode(g.rawValue, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DiscriminatorKey.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .byType:
            let raw = try c.decode(String.self, forKey: .value)
            guard let t = BookConversionType(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: c,
                    debugDescription: "Unknown BookConversionType: \(raw)"
                )
            }
            self = .byType(t)
        case .byAuthor:
            self = .byAuthor(try c.decode(String.self, forKey: .value))
        case .byGenre:
            let raw = try c.decode(String.self, forKey: .value)
            guard let g = BookGenre(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: c,
                    debugDescription: "Unknown BookGenre: \(raw)"
                )
            }
            self = .byGenre(g)
        }
    }
}
