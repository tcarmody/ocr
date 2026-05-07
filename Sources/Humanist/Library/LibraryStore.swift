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
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []

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
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([LibraryEntry].self, from: data)
        else { return }
        // Drop entries whose .epub no longer exists on disk so the
        // window doesn't show dead rows. Same posture as
        // RecentsStore.urls.
        entries = decoded.filter {
            FileManager.default.fileExists(atPath: $0.epubURL.path)
        }
        if entries.count != decoded.count {
            // Persisted count diverged from filtered (some files were
            // moved / deleted) — write the pruned list back so the
            // next launch starts clean.
            save()
        }
    }

    private func save() {
        // Default date strategy (number-of-seconds-since-reference-
        // date) matches the default JSONDecoder, so the persistence
        // round-trip is symmetric without further configuration.
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - mutations

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
    /// untouched — we only forget about it.
    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
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
