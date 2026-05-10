import Foundation
import Combine
import EPUB  // canonicalForFile

/// R-Library. JSON-backed list of every EPUB the user has
/// converted in this app, surfaced through the dedicated Library
/// browser window. Distinct from `RecentsStore` (last-10 menu cap)
/// and from `JobStore` (per-conversion queue, transient — Clear
/// Done removes finished rows).
///
/// Entries are written when a conversion finishes successfully,
/// updated on every editor-open of the resulting EPUB, and pruned
/// only by explicit user action (Remove from Library) — the file
/// itself isn't touched. Stored at
/// `~/Library/Application Support/Humanist/library.json`, mirroring
/// `JobStore`'s persistence convention.
///
/// R-Library-Chat-Plus Collections: the store also persists named
/// groupings of books (`BookCollection`). Chat scope and the library
/// browser both read from `collections` to filter / scope retrieval.
/// The file format grew a wrapper (`StoredPayload`) but reads still
/// accept the legacy bare-array shape so pre-Collections libraries
/// load unchanged.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var collections: [BookCollection] = []

    let storeURL: URL

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let dir = support.appendingPathComponent("Humanist", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            self.storeURL = dir.appendingPathComponent("library.json")
        }
        load()
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
        // Drop entries whose .epub no longer exists on disk so the
        // window doesn't show dead rows. Same posture as
        // RecentsStore.urls.
        let filtered = loadedEntries.filter {
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

    private func save() {
        let payload = StoredPayload(entries: entries, collections: collections)
        // Default date strategy (number-of-seconds-since-reference-
        // date) matches the default JSONDecoder, so the persistence
        // round-trip is symmetric without further configuration.
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - mutations: entries

    /// Record a successful conversion. If the same `epubURL` is
    /// already in the library (re-conversion), update its title +
    /// languages in place rather than duplicating; the original
    /// `addedAt` is preserved so the row's history is honest.
    func recordConversion(
        epubURL: URL, title: String, languages: [String]
    ) {
        let canonical = epubURL.canonicalForFile
        if let idx = entries.firstIndex(where: {
            $0.epubURL.canonicalForFile == canonical
        }) {
            entries[idx].title = title
            entries[idx].languages = languages
        } else {
            entries.append(LibraryEntry(
                epubURL: canonical,
                title: title,
                languages: languages,
                addedAt: Date(),
                lastOpened: nil
            ))
        }
        save()
    }

    /// Bump `lastOpened` for `epubURL`. No-op if the entry doesn't
    /// exist — opening an EPUB the library doesn't know about (e.g.
    /// a third-party file the user dragged in for editing) doesn't
    /// retroactively add it; the library is for "books I converted
    /// in this app," not "every EPUB I ever opened."
    func recordOpen(_ epubURL: URL) {
        let canonical = epubURL.canonicalForFile
        guard let idx = entries.firstIndex(where: {
            $0.epubURL.canonicalForFile == canonical
        }) else { return }
        entries[idx].lastOpened = Date()
        save()
    }

    /// Remove an entry from the library. The .epub file itself is
    /// untouched — we only forget about it. Also drops the entry's
    /// id from every collection so we don't carry dangling refs.
    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        for idx in collections.indices {
            collections[idx].bookIDs.removeAll { $0 == id }
        }
        save()
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

    init(
        id: UUID = UUID(),
        epubURL: URL,
        title: String,
        languages: [String] = [],
        addedAt: Date,
        lastOpened: Date? = nil
    ) {
        self.id = id
        self.epubURL = epubURL
        self.title = title
        self.languages = languages
        self.addedAt = addedAt
        self.lastOpened = lastOpened
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

    init(
        id: UUID = UUID(),
        name: String,
        bookIDs: [UUID] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bookIDs = bookIDs
        self.createdAt = createdAt
    }
}
