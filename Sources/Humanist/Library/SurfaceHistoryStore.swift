import Foundation

/// Persisted ring of paragraphs surfaced by the "Surface me
/// something" button. Used by `SurfaceParagraphSelector` to bias
/// selection away from items the user just saw — without this the
/// random pick would land on the same handful of dense paragraphs
/// often enough to break the discovery illusion.
///
/// Storage: one JSON file under Application Support, capped at
/// `maxEntries` (~200) with FIFO eviction. Entries older than the
/// recency-decay window expire naturally on read; that lets the
/// same paragraph reappear after enough time has passed without
/// us having to write a per-read cleanup.
///
/// Not shared across machines — discovery is inherently per-user-
/// session, and the per-book embedding sidecars (which the
/// selector reads from) already aren't synced.
struct SurfaceHistoryStore {

    /// One previously-surfaced paragraph. Keyed by `(bookURL,
    /// chapter, paragraph)` for the contains-check; the timestamp
    /// drives the recency-decay filter.
    struct Entry: Codable, Equatable {
        let bookURL: URL
        let chapterIdx: Int
        let paragraphIdx: Int
        let shownAt: Date
    }

    /// Cap on persisted entries — once we exceed this, oldest
    /// entries drop on next write. 200 is enough to cover a few
    /// dozen surfacings without ever blocking re-discovery
    /// indefinitely on small libraries.
    private static let maxEntries = 200

    /// Window during which a previously-shown paragraph is
    /// considered "recent" and skipped by the selector. After this
    /// passes the paragraph becomes eligible again — useful for
    /// re-discovery on a long timeline.
    static let recentWindow: TimeInterval = 60 * 24 * 60 * 60  // 60 days

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = support
            .appendingPathComponent("Humanist", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir.appendingPathComponent("surfaced-history.json")
    }

    // MARK: - Read

    /// Load every persisted entry; corrupt files decode to an
    /// empty list (the selector just treats the cache as cold).
    func read() -> [Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let entries = try? Self.decoder.decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    /// True iff `(bookURL, chapter, paragraph)` was surfaced
    /// within `recentWindow`. The selector calls this per
    /// candidate to skip recently-shown paragraphs.
    func isRecent(bookURL: URL, chapterIdx: Int, paragraphIdx: Int) -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.recentWindow)
        return read().contains { entry in
            entry.shownAt >= cutoff
                && entry.chapterIdx == chapterIdx
                && entry.paragraphIdx == paragraphIdx
                && entry.bookURL == bookURL
        }
    }

    // MARK: - Write

    /// Record a paragraph as surfaced. Appends to the tail and
    /// evicts oldest entries when over `maxEntries`. Failed writes
    /// are silent — the worst case is the same paragraph reappears
    /// sooner than intended.
    func record(bookURL: URL, chapterIdx: Int, paragraphIdx: Int) {
        var entries = read()
        entries.append(Entry(
            bookURL: bookURL,
            chapterIdx: chapterIdx,
            paragraphIdx: paragraphIdx,
            shownAt: Date()
        ))
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }
        guard let data = try? Self.encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Codec

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
