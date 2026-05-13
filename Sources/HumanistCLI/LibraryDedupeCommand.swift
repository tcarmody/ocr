import Foundation
import ArgumentParser
import CryptoKit

/// `humanist-cli library-dedupe` — one-time cleanup that surfaces
/// content-identical EPUBs in the Humanist library catalog and,
/// with `--apply`, removes the redundant files + catalog rows +
/// collection memberships.
///
/// Operates directly on `library.json` (default: the
/// Application Support copy) without booting the SwiftUI app, so
/// it can be run safely with Humanist closed. The catalog is read
/// as raw JSON (`JSONSerialization`) so fields the CLI doesn't
/// model — `relativePath`, `genre`, `sourceContentHashes`,
/// `priorPaths`, future additions — round-trip untouched. Only
/// the dedupe-relevant fields (`id`, `epubURL`, `title`,
/// `addedAt`) are interpreted.
///
/// Posture is deliberately conservative:
///  * Dry-run by default. The report is the deliverable; `--apply`
///    is opt-in and only fires when the user is satisfied.
///  * Within a content-identical group, the **newest** entry by
///    `addedAt` is the proposed canonical. Newer typically means
///    "the user did this on purpose later" (e.g., a re-import
///    with corrected metadata).
///  * EPUB file removal moves files to the user's Trash via
///    `FileManager.trashItem` rather than deleting outright, so
///    "oh wait, that was the wrong canonical" is recoverable.
///  * One snapshot of `library.json` is written next to the
///    catalog before any change lands, so the catalog itself is
///    recoverable too.
struct LibraryDedupeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "library-dedupe",
        abstract: "Find and (optionally) remove content-identical EPUBs in the Humanist library."
    )

    @Option(name: .customLong("catalog"),
            help: "Path to library.json. Defaults to the Application Support catalog.")
    var catalogPath: String?

    @Flag(name: .long,
          help: "Apply the dedupe (move duplicate EPUBs to Trash, rewrite library.json). Without this flag, prints the report only.")
    var apply: Bool = false

    @Flag(name: .long,
          inversion: .prefixedNo,
          help: "Print every duplicate group. Pass --no-verbose for the summary line only.")
    var verbose: Bool = true

    func run() async throws {
        let catalogURL = try resolveCatalogURL()
        let raw = try Data(contentsOf: catalogURL)
        guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else {
            throw ValidationError("library.json is not a JSON object at \(catalogURL.path)")
        }

        let entries = decodeEntries(from: root)
        if entries.isEmpty {
            print("No entries in catalog at \(catalogURL.path).")
            return
        }
        print("Catalog: \(catalogURL.path)")
        print("Entries: \(entries.count). Hashing every EPUB…")

        let groups = await hashEntries(entries)
        let dupes = groups.filter { $0.entries.count >= 2 }

        if dupes.isEmpty {
            print("No duplicate EPUBs found.")
            return
        }

        print("")
        print("Found \(dupes.count) duplicate group(s):")
        let totalRedundant = dupes.reduce(0) { $0 + ($1.entries.count - 1) }
        print("Redundant files: \(totalRedundant)")
        if verbose {
            for (i, group) in dupes.enumerated() {
                print("")
                print("Group \(i + 1) — hash \(group.hash.prefix(16))…")
                let sorted = group.entries.sorted { $0.addedAt > $1.addedAt }
                for (j, entry) in sorted.enumerated() {
                    let tag = j == 0 ? "keep " : "drop "
                    print("  \(tag) \(entry.epubURL.lastPathComponent) — \(entry.title) — \(format(date: entry.addedAt))")
                }
            }
        }

        guard apply else {
            print("")
            print("Re-run with --apply to move duplicates to Trash and rewrite the catalog.")
            return
        }

        // Snapshot the catalog before mutation so a bug or
        // misjudgement doesn't take the library with it.
        let snapshotURL = catalogURL.deletingPathExtension()
            .appendingPathExtension("dedupe-backup.json")
        try raw.write(to: snapshotURL)
        print("")
        print("Backed up catalog to \(snapshotURL.path)")

        var mutableRoot = root
        var removedIDs = Set<String>()
        for group in dupes {
            let sorted = group.entries.sorted { $0.addedAt > $1.addedAt }
            // First entry is the keeper; rest get the boot.
            for entry in sorted.dropFirst() {
                let trashResult = trash(entry.epubURL)
                switch trashResult {
                case .success:
                    removedIDs.insert(entry.id.uuidString.lowercased())
                    print("Trashed \(entry.epubURL.lastPathComponent)")
                case .failure(let err):
                    FileHandle.standardError.write(Data(
                        "Failed to trash \(entry.epubURL.path): \(err.localizedDescription)\n".utf8
                    ))
                }
            }
        }
        if !removedIDs.isEmpty {
            mutableRoot = pruneCatalog(mutableRoot, removingIDs: removedIDs)
            let written = try JSONSerialization.data(
                withJSONObject: mutableRoot,
                options: [.prettyPrinted, .sortedKeys]
            )
            try written.write(to: catalogURL, options: .atomic)
            print("Rewrote \(catalogURL.lastPathComponent) — removed \(removedIDs.count) entr\(removedIDs.count == 1 ? "y" : "ies").")
        }
    }

    // MARK: - catalog locating

    private func resolveCatalogURL() throws -> URL {
        if let catalogPath {
            let url = URL(fileURLWithPath: catalogPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("Catalog not found at \(url.path)")
            }
            return url
        }
        // Default Application Support location — same convention
        // the Humanist app uses when "Share across machines" is
        // off. Callers who use cloud-sync mode should pass
        // `--catalog <root>/.humanist/library.json` explicitly.
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let url = support
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError(
                "No catalog at \(url.path). Pass --catalog to point at your library.json."
            )
        }
        return url
    }

    // MARK: - decode / hash

    /// Minimal entry view: only the fields dedupe cares about.
    /// Catalog round-trip preserves every other field because we
    /// keep the original JSON dictionary and only delete entries
    /// from it — we never re-encode the whole entry.
    private struct CatalogEntry {
        let id: UUID
        let epubURL: URL
        let title: String
        let addedAt: Date
    }

    private func decodeEntries(from root: [String: Any]) -> [CatalogEntry] {
        let raw = (root["entries"] as? [[String: Any]]) ?? []
        var out: [CatalogEntry] = []
        for dict in raw {
            guard
                let idString = dict["id"] as? String,
                let id = UUID(uuidString: idString),
                let epubString = dict["epubURL"] as? String,
                let title = dict["title"] as? String
            else { continue }
            let url: URL
            if let parsed = URL(string: epubString), parsed.scheme != nil {
                url = parsed
            } else {
                url = URL(fileURLWithPath: epubString)
            }
            // `addedAt` is encoded as the JSON-default seconds-since
            // reference date (NSDate base). Falls back to .distantPast
            // when missing so the entry sorts oldest.
            let addedAt: Date
            if let secs = dict["addedAt"] as? Double {
                addedAt = Date(timeIntervalSinceReferenceDate: secs)
            } else {
                addedAt = .distantPast
            }
            out.append(CatalogEntry(
                id: id, epubURL: url, title: title, addedAt: addedAt
            ))
        }
        return out
    }

    private struct DuplicateGroup {
        let hash: String
        let entries: [CatalogEntry]
    }

    private func hashEntries(_ entries: [CatalogEntry]) async -> [DuplicateGroup] {
        // Hash off the main thread; one Task per file would be
        // wasteful (file I/O is the bottleneck), so do them in
        // sequence inside a single detached task. For a 1000-book
        // library at ~1 MB avg this is ~10 s.
        let toHash = entries.filter {
            FileManager.default.fileExists(atPath: $0.epubURL.path)
        }
        return await Task.detached(priority: .userInitiated) {
            var bucket: [String: [CatalogEntry]] = [:]
            for entry in toHash {
                guard let hash = try? Self.sha256(of: entry.epubURL)
                else { continue }
                bucket[hash, default: []].append(entry)
            }
            return bucket.map { DuplicateGroup(hash: $0.key, entries: $0.value) }
                // Stable order: larger groups first, then by
                // hash so the report reads the same on every run.
                .sorted { a, b in
                    if a.entries.count != b.entries.count {
                        return a.entries.count > b.entries.count
                    }
                    return a.hash < b.hash
                }
        }.value
    }

    /// Streaming SHA-256 of a file. Mirrors
    /// `Humanist.ContentHash.sha256(of:)` but stays self-contained
    /// inside the CLI target (which doesn't depend on Humanist).
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - mutate / write

    /// Move `url` to the user's Trash. Returns `.success` on the
    /// trash op succeeding (or on the file already being absent —
    /// treat the goal-state as the success condition).
    private func trash(_ url: URL) -> Result<Void, Error> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success(())
        }
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Build a new root dictionary that drops every entry whose id
    /// is in `removingIDs` and removes those ids from every
    /// collection's `bookIDs` array. Preserves every other field on
    /// every other entry (and on the collections themselves) by
    /// operating on the raw JSON values.
    private func pruneCatalog(
        _ root: [String: Any], removingIDs: Set<String>
    ) -> [String: Any] {
        var out = root
        if let entries = root["entries"] as? [[String: Any]] {
            out["entries"] = entries.filter { dict in
                guard let id = dict["id"] as? String else { return true }
                return !removingIDs.contains(id.lowercased())
            }
        }
        if let collections = root["collections"] as? [[String: Any]] {
            out["collections"] = collections.map { (dict: [String: Any]) -> [String: Any] in
                var c = dict
                if let bookIDs = c["bookIDs"] as? [String] {
                    c["bookIDs"] = bookIDs.filter {
                        !removingIDs.contains($0.lowercased())
                    }
                }
                return c
            }
        }
        return out
    }

    private func format(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
