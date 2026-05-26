import Foundation
import ArgumentParser
import AI
import EPUB
import LibraryIndexing

/// `humanist-cli refresh-entity-index` — rebuild each book's
/// per-paragraph entity index (the NER + concept + alias-scan
/// pass that drives the Topics rollup) WITHOUT touching the
/// embedding sidecars. Use when the user-curated alias
/// dictionary or AFM-extracted concept payloads have changed
/// and the Topics view should reflect the new vocabulary,
/// but the per-paragraph embeddings are already current.
///
/// Cost shape vs. `reindex`:
///   * `reindex` re-runs the embedding backend on every
///     paragraph (~2-5 s per book on cloud, dominated by API
///     round-trip).
///   * `refresh-entity-index` re-runs NLTagger on every
///     paragraph (~1-3 s per book, all CPU, no network).
///
/// At 444 books that's roughly the difference between a
/// 30-minute Gemini reindex and a 10-minute local refresh.
///
/// Per-book contract: opens the EPUB, reads the book's
/// `BookConceptStore` payload (if any) + the library-wide
/// alias dictionary, runs `BookEntityIndex.build(from:
/// aliasTerms:)` with the union, patches the existing
/// embedding sidecar's `entities` field in place, writes back.
/// Books without an existing sidecar are skipped (there's
/// nothing to patch — they need a real `reindex` first to
/// build paragraph vectors).
struct RefreshEntityIndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh-entity-index",
        abstract: "Rebuild per-book entity indexes from current aliases + saved concepts, without re-embedding paragraphs."
    )

    @Option(
        name: .long,
        help: "Path to library.json. Defaults to the Application Support catalog."
    )
    var catalog: String?

    @Option(
        name: .long,
        help: "Override the embeddings storage root. Defaults to ~/Library/Application Support/Humanist/Embeddings/."
    )
    var storeRoot: String?

    @Option(
        name: .long,
        help: "Override the per-book concepts directory. Defaults to <library state dir>/Concepts/."
    )
    var conceptsRoot: String?

    @Option(
        name: .long,
        help: "Override the alias dictionary path. Defaults to the user's configured alias-store location."
    )
    var aliasesPath: String?

    @Option(
        name: .long,
        help: "Stop after N books (0 = no limit). Smoke-testing helper."
    )
    var limit: Int = 0

    func run() async throws {
        let catalogURL = try resolveCatalogURL()
        let storeURL = resolveStoreURL()
        let conceptsURL = try resolveConceptsURL(catalogURL: catalogURL)
        let aliasTerms = readAliasTerms(catalogURL: catalogURL)

        var entries = try decodeEntries(at: catalogURL)
        if limit > 0 && entries.count > limit {
            entries = Array(entries.prefix(limit))
        }

        print("Catalog:           \(catalogURL.path)")
        print("Embeddings root:   \(storeURL.path)")
        print("Concepts dir:      \(conceptsURL.path)")
        print("Alias-term count:  \(aliasTerms.count)")
        print("Books in catalog:  \(entries.count)\(limit > 0 ? " (capped via --limit)" : "")")
        print("")

        let sidecarStore = EmbeddingsSidecarStore(baseDirectory: storeURL)
        let conceptStore = BookConceptStore(baseDirectory: conceptsURL)

        var refreshed = 0
        var skippedNoSidecar = 0
        var failed: [(title: String, error: String)] = []
        let started = Date()

        for (index, entry) in entries.enumerated() {
            let prefix = "[\(index + 1)/\(entries.count)] \(entry.title)"
            // No existing sidecar = nothing to patch. The book
            // needs a real `reindex` first before refresh can do
            // anything for it.
            guard var sidecar = sidecarStore.read(
                for: entry.epubURL, libraryID: entry.id
            ) else {
                skippedNoSidecar += 1
                print("\(prefix) — skipped (no existing sidecar)")
                continue
            }
            // Open the EPUB on disk; the entity rebuild needs the
            // book's paragraph text. NLTagger runs on the
            // in-memory text — same paragraphs the embedder
            // already walked once.
            guard let book = try? EPUBBook.open(epubURL: entry.epubURL) else {
                failed.append((entry.title, "EPUBBook.open failed"))
                print("\(prefix) — FAILED: couldn't open EPUB")
                continue
            }
            let bookConcepts = conceptStore.conceptTerms(libraryID: entry.id)
            let combined = aliasTerms.union(bookConcepts)
            sidecar.entities = BookEntityIndex.build(
                from: book, aliasTerms: combined
            )
            sidecarStore.write(
                sidecar, for: entry.epubURL, libraryID: entry.id
            )
            refreshed += 1
            print("\(prefix) — refreshed (concepts: \(bookConcepts.count))")
        }

        let elapsed = Date().timeIntervalSince(started)
        print("")
        print("=== Refresh complete in \(Int(elapsed))s ===")
        print("Refreshed:           \(refreshed)")
        print("Skipped (no sidecar): \(skippedNoSidecar)")
        print("Failed:              \(failed.count)")
        if !failed.isEmpty {
            print("")
            print("First failures:")
            for f in failed.prefix(10) {
                print("  • \(f.title): \(f.error)")
            }
            if failed.count > 10 {
                print("  …and \(failed.count - 10) more.")
            }
        }
    }

    // MARK: - Path resolution

    private func resolveCatalogURL() throws -> URL {
        if let catalog {
            let url = URL(fileURLWithPath: catalog).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("Catalog not found at \(url.path)")
            }
            return url
        }
        // Auto-detect via the app's UserDefaults — cloud-sync /
        // customLocal / Application Support, same precedence as
        // the running app.
        guard let url = CLILibraryLocation.defaultCatalogURL() else {
            throw ValidationError(
                "No catalog found via auto-detection. Pass --catalog to point at your library.json."
            )
        }
        return url
    }

    private func resolveStoreURL() -> URL {
        if let storeRoot {
            return URL(fileURLWithPath: storeRoot).standardizedFileURL
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("Embeddings", isDirectory: true)
    }

    private func resolveConceptsURL(catalogURL: URL) throws -> URL {
        if let conceptsRoot {
            return URL(fileURLWithPath: conceptsRoot).standardizedFileURL
        }
        // Default: sibling to the catalog. Mirrors the app's
        // LibraryStore.resolveLibraryStateDirectory + /Concepts.
        return catalogURL.deletingLastPathComponent()
            .appendingPathComponent("Concepts", isDirectory: true)
    }

    private func readAliasTerms(catalogURL: URL) -> Set<String> {
        // The alias dictionary file location varies between
        // cloud (.humanist/aliases.json) and local
        // (Application Support/Humanist/Aliases/aliases.json)
        // modes. Detection: look next to the catalog first
        // (.humanist root layout); if that misses, walk back to
        // the Application Support layout.
        let candidates: [URL] = {
            if let aliasesPath {
                return [URL(fileURLWithPath: aliasesPath).standardizedFileURL]
            }
            let parent = catalogURL.deletingLastPathComponent()
            return [
                parent.appendingPathComponent("aliases.json"),
                parent.appendingPathComponent("Aliases").appendingPathComponent("aliases.json"),
            ]
        }()
        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url)
            else { continue }
            // Decode the shape the app's AliasDictionaryStore
            // uses: { "schemaVersion": 1, "terms": ["a", "b", …],
            // "displayTerms": {...} }
            guard let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let terms = json["terms"] as? [String]
            else { return [] }
            return Set(terms)
        }
        return []
    }

    // MARK: - Catalog decode (same shape as ReindexCommand)

    private struct CatalogEntry: Sendable {
        let id: UUID
        let epubURL: URL
        let title: String
        let author: String?
    }

    private func decodeEntries(at catalogURL: URL) throws -> [CatalogEntry] {
        let raw = try Data(contentsOf: catalogURL)
        guard let root = try JSONSerialization.jsonObject(with: raw)
                as? [String: Any],
              let rawEntries = root["entries"] as? [[String: Any]]
        else {
            throw ValidationError(
                "library.json is not the expected shape at \(catalogURL.path)"
            )
        }
        var out: [CatalogEntry] = []
        out.reserveCapacity(rawEntries.count)
        for (i, dict) in rawEntries.enumerated() {
            guard let idStr = dict["id"] as? String,
                  let id = UUID(uuidString: idStr),
                  let urlStr = dict["epubURL"] as? String,
                  let url = URL(string: urlStr),
                  let title = dict["title"] as? String
            else {
                print("Skipping malformed entry \(i)")
                continue
            }
            out.append(CatalogEntry(
                id: id, epubURL: url, title: title,
                author: dict["author"] as? String
            ))
        }
        return out
    }
}
