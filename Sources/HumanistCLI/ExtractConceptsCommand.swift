import Foundation
import ArgumentParser
import AI
import EPUB
import Pipeline
import LibraryIndexing

/// `humanist-cli extract-concepts` — headless equivalent of the
/// Library window's `rectangle.and.text.magnifyingglass` bulk-
/// extract button. Walks the catalog, runs
/// `BookConceptExtractor` against each book, persists the result
/// to `BookConceptStore`, and rebuilds the entity index so the
/// concepts surface in the Topics rollup on next open.
///
/// Two modes:
///   * Default: skip books that already have a payload (parity
///     with the in-app `extractMissingConcepts` action). Use this
///     to fill in concepts for newly-imported books.
///   * `--force`: re-extract every book, overwriting existing
///     payloads. Use this after prompt-revision updates
///     (`BookConceptExtractor.modelIdentifier` bump) when you want
///     existing books to reflect the new vocabulary.
///
/// Each book extraction takes ~5-10s of AFM time plus ~1-3s of
/// NLTagger entity-rebuild. At 444 books × ~10s = ~75 minutes
/// total for a full re-extract. Wrap in `caffeinate -i` for
/// unattended runs.
struct ExtractConceptsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract-concepts",
        abstract: "Run AFM concept extraction over the catalog. Persists per-book payloads + rebuilds entity indexes so concepts surface in Topics."
    )

    @Flag(
        name: .long,
        help: "Re-extract every book, overwriting existing payloads. Default behavior skips books that already have a payload."
    )
    var force: Bool = false

    @Option(
        name: .long,
        help: "Path to library.json. Defaults to the active library (auto-detected from the app's UserDefaults — cloud > customLocal > Application Support)."
    )
    var catalog: String?

    @Option(
        name: .long,
        help: "Override the per-book concepts directory. Defaults to <library state dir>/Concepts/."
    )
    var conceptsRoot: String?

    @Option(
        name: .long,
        help: "Override the embeddings storage root. Defaults to ~/Library/Application Support/Humanist/Embeddings/."
    )
    var storeRoot: String?

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

    @Option(
        name: .long,
        help: "Maximum seconds a single book is allowed before the watchdog cancels and moves on. Default 240s — accommodates the 2-4 AFM calls per book the chunked extractor fires, plus the entity-index rebuild. Set lower on short-book libraries; raise on books with many chapters."
    )
    var perBookTimeoutSeconds: Int = 240

    func run() async throws {
        let catalogURL = try resolveCatalogURL()
        let storeURL = resolveStoreURL()
        let conceptsURL = try resolveConceptsURL(catalogURL: catalogURL)
        let aliasTerms = readAliasTerms(catalogURL: catalogURL)

        var entries = try decodeEntries(at: catalogURL)
        if limit > 0 && entries.count > limit {
            entries = Array(entries.prefix(limit))
        }

        let conceptStore = BookConceptStore(baseDirectory: conceptsURL)
        let sidecarStore = EmbeddingsSidecarStore(baseDirectory: storeURL)

        let needsExtraction: [CatalogEntry] = force
            ? entries
            : entries.filter { !conceptStore.hasPayload(libraryID: $0.id) }

        print("Catalog:           \(catalogURL.path)")
        print("Concepts dir:      \(conceptsURL.path)")
        print("Embeddings root:   \(storeURL.path)")
        print("Alias-term count:  \(aliasTerms.count)")
        print("Books in catalog:  \(entries.count)\(limit > 0 ? " (capped via --limit)" : "")")
        print("Mode:              \(force ? "Force re-extract" : "Missing only")")
        print("Books to extract:  \(needsExtraction.count)")
        print("Model identifier:  \(BookConceptExtractor.modelIdentifier)")
        print("")

        guard !needsExtraction.isEmpty else {
            print("Nothing to do.")
            return
        }

        guard case .available = AppleFoundationModelClient.availability else {
            print("Apple Foundation Models unavailable on this machine. Aborting.")
            throw ExitCode.failure
        }
        let extractor = BookConceptExtractor()

        var extracted = 0
        var declined = 0
        var errored = 0
        var failed: [(entry: CatalogEntry, error: String)] = []
        let started = Date()

        for (idx, entry) in needsExtraction.enumerated() {
            if Task.isCancelled { break }
            let prefix = "[\(idx + 1)/\(needsExtraction.count)] \(entry.title)"
            do {
                let outcome = try await Self.runWithTimeout(
                    seconds: TimeInterval(perBookTimeoutSeconds)
                ) {
                    try await Self.processOne(
                        entry: entry,
                        extractor: extractor,
                        conceptStore: conceptStore,
                        sidecarStore: sidecarStore,
                        aliasTerms: aliasTerms
                    )
                }
                switch outcome {
                case .extracted(let count):
                    extracted += 1
                    print("\(prefix) — extracted \(count) concepts")
                case .declined:
                    declined += 1
                    print("\(prefix) — AFM declined (empty list, no error)")
                case .errored(let message):
                    errored += 1
                    failed.append((entry, "AFM threw: \(message)"))
                    print("\(prefix) — AFM ERROR: \(message)")
                }
            } catch is CancellationError {
                print("\(prefix) — cancelled, stopping run")
                break
            } catch {
                failed.append((entry, error.localizedDescription))
                print("\(prefix) — FAILED: \(error.localizedDescription)")
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print("")
        print("=== Extraction complete in \(Int(elapsed))s ===")
        print("Extracted:    \(extracted)")
        print("Declined:     \(declined)")
        print("AFM errors:   \(errored)")
        print("Other failed: \(failed.count - errored)")
        if !failed.isEmpty {
            print("")
            print("First failures:")
            for f in failed.prefix(10) {
                print("  • \(f.entry.title): \(f.error)")
            }
            if failed.count > 10 {
                print("  …and \(failed.count - 10) more.")
            }
        }
    }

    /// Outcome of a single book's processing. Lets the loop
    /// distinguish "AFM threw an error" (context window blown,
    /// framework hiccup) from "AFM legitimately declined" (no
    /// concepts) for honest per-book logging.
    fileprivate enum BookOutcome {
        case extracted(count: Int)
        case declined
        case errored(String)
    }

    /// Per-book pipeline: AFM extract → persist payload → rebuild
    /// entity index with the new concepts unioned into the
    /// alias-scan path → patch sidecar.
    private static func processOne(
        entry: CatalogEntry,
        extractor: BookConceptExtractor,
        conceptStore: BookConceptStore,
        sidecarStore: EmbeddingsSidecarStore,
        aliasTerms: Set<String>
    ) async throws -> BookOutcome {
        let book = try EPUBBook.open(epubURL: entry.epubURL)
        // Chunked extraction: cover more of the book by running
        // AFM N times per book, each on a distinct chapter range.
        // For a 30-chapter book: ~2-3 chunks. Each chunk fits
        // comfortably inside AFM's input window, and the merge
        // step dedupes overlapping concepts so a recurring
        // through-line surfaces once with its earliest position.
        let batches = BookConceptExtractor.sampleChapterBatches(from: book)
        guard !batches.isEmpty else { return .declined }
        let outcome = await extractor.extractMerged(
            title: entry.title,
            author: entry.author,
            chapterBatches: batches
        )
        if let errorDescription = outcome.errorDescription {
            return .errored(errorDescription)
        }
        guard let concepts = outcome.concepts, !concepts.isEmpty else {
            return .declined
        }
        let payload = BookConceptStore.Payload(
            concepts: concepts,
            generatedAt: Date(),
            modelIdentifier: BookConceptExtractor.modelIdentifier
        )
        try conceptStore.write(payload, libraryID: entry.id)
        // Rebuild the entity index so concepts fold into the
        // alias-scan path on the existing sidecar. Skip silently
        // when the book has no embedding sidecar yet — `reindex`
        // will build one later and pick up the saved concepts.
        if var sidecar = sidecarStore.read(
            for: entry.epubURL, libraryID: entry.id
        ) {
            let combined = aliasTerms.union(Set(concepts))
            sidecar.entities = BookEntityIndex.build(
                from: book, aliasTerms: combined
            )
            sidecarStore.write(
                sidecar, for: entry.epubURL, libraryID: entry.id
            )
        }
        return .extracted(count: concepts.count)
    }

    private static func runWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let work = Task<T, Error> { try await operation() }
        let watchdog = Task<Void, Never> {
            try? await Task.sleep(
                nanoseconds: UInt64(seconds * 1_000_000_000)
            )
            work.cancel()
        }
        defer { watchdog.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
                watchdog.cancel()
            }
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            throw ExtractConceptsTimedOut(seconds: seconds)
        }
    }

    // MARK: - Path resolution (same shape as RefreshEntityIndex)

    private func resolveCatalogURL() throws -> URL {
        if let catalog {
            let url = URL(fileURLWithPath: catalog).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("Catalog not found at \(url.path)")
            }
            return url
        }
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
        return catalogURL.deletingLastPathComponent()
            .appendingPathComponent("Concepts", isDirectory: true)
    }

    private func readAliasTerms(catalogURL: URL) -> Set<String> {
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
            guard let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let terms = json["terms"] as? [String]
            else { return [] }
            return Set(terms)
        }
        return []
    }

    // MARK: - Catalog decode (mirrors ReindexCommand / RefreshEntityIndex)

    fileprivate struct CatalogEntry: Sendable {
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

struct ExtractConceptsTimedOut: LocalizedError {
    let seconds: TimeInterval
    var errorDescription: String? {
        "timed out after \(Int(seconds))s — AFM extraction or entity rebuild exceeded the per-book deadline"
    }
}
