import Foundation
import ArgumentParser
import AI
import EPUB
import LibraryIndexing

/// Thrown by `ReindexCommand.runWithTimeout` when a single book's
/// processing exceeds the per-book deadline. localizedDescription
/// contains the word "timed out" so the run-level transient-failure
/// classifier (`Self.looksTransient`) picks it up for the
/// end-of-run cool-off retry pass.
struct ReindexBookTimedOut: LocalizedError {
    let seconds: TimeInterval
    var errorDescription: String? {
        "timed out after \(Int(seconds))s — book exceeded the per-book deadline"
    }
}

/// `humanist-cli reindex --backend <choice>` — headless equivalent
/// of the Library window's "Build Missing Indexes" / "Rebuild All
/// Indexes" toolbar. Walks the catalog, constructs the chosen
/// `EmbeddingBackend`, and loops `BookSidecarBuilder.buildIfNeeded`
/// per book. Each call writes the sidecar to disk on success;
/// failures are tallied and printed at the end.
///
/// Use case: long-running re-index after a backend switch (or after
/// `clear-outdated`), runnable from SSH / cron / a background shell
/// without keeping the Humanist app open. Same per-book pipeline
/// the app uses — the `BookSidecarBuilder` extraction in the
/// LibraryIndexing refactor was the precondition for this command.
///
/// Defaults to `--missing-only` posture (skip any book whose sidecar
/// already matches the backend); pass `--force` to rebuild
/// everything from scratch.
struct ReindexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reindex",
        abstract: "Rebuild embedding sidecars for every book in the catalog."
    )

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp(
            "Embedding backend to build sidecars against.",
            valueName: "apple|ollama|voyage|gemini"
        )
    )
    var backend: BackendChoice

    @Flag(
        name: .long,
        help: "Rebuild every sidecar, even ones already on the chosen backend."
    )
    var force: Bool = false

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
        help: "Gemini Matryoshka output dimensionality (768 / 1536 / 3072 / 0 for default). Only used when --backend gemini."
    )
    var geminiDim: Int = 0

    @Option(
        name: .long,
        help: "Ollama embedding model name. Only used when --backend ollama."
    )
    var ollamaModel: String = "nomic-embed-text"

    @Option(
        name: .long,
        help: "Voyage embedding model. Only used when --backend voyage."
    )
    var voyageModel: String = "voyage-3"

    @Option(
        name: .long,
        help: "Stop after N books (0 = no limit). Useful for smoke-testing a re-index without committing to thousands of API calls."
    )
    var limit: Int = 0

    @Option(
        name: .long,
        help: "App bundle ID used to look up API keys in the keychain. Defaults to com.tcarmody.Humanist so the CLI finds the same keys the app stored."
    )
    var appBundleID: String = "com.tcarmody.Humanist"

    @Option(
        name: .long,
        help: "Seconds to wait between the main pass and a retry pass against transient failures (429 / 503 / network). Default 60s. Set 0 to skip the retry pass."
    )
    var retryCooloffSeconds: Int = 60

    @Option(
        name: .long,
        help: "Maximum seconds a single book is allowed before the watchdog cancels it and the loop moves on. Default 180s — covers a healthy ~2000-paragraph book with cloud-embedding round-trips and even a few 429/503 retries. Stuck books get cancelled cleanly so one bad entry can't block a 2000-book run."
    )
    var perBookTimeoutSeconds: Int = 180

    func run() async throws {
        let catalogURL = try resolveCatalogURL()
        let storeURL = resolveStoreURL()
        var entries = try decodeEntries(at: catalogURL)
        if limit > 0 && entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        print("Catalog:           \(catalogURL.path)")
        print("Embeddings root:   \(storeURL.path)")
        print("Books in catalog:  \(entries.count)\(limit > 0 ? " (capped via --limit)" : "")")
        print("Backend:           \(backend.rawValue)")
        print("Mode:              \(force ? "Rebuild all (--force)" : "Build missing")")
        print("")
        print("Resolving backend…")

        let backendInstance: any EmbeddingBackend
        do {
            backendInstance = try await resolveBackend()
        } catch {
            print("Backend resolution failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
        print("Backend ready: \(backendInstance.identifier) (dim \(backendInstance.dimension))")
        print("")

        let store = EmbeddingsSidecarStore(baseDirectory: storeURL)

        var built = 0
        var skipped = 0
        var fellBack = 0
        var failed: [(entry: CatalogEntry, error: String)] = []
        let totalCount = entries.count
        let started = Date()

        for (index, entry) in entries.enumerated() {
            let prefix = "[\(index + 1)/\(totalCount)] \(entry.title)"
            do {
                let outcome = try await Self.runWithTimeout(
                    seconds: TimeInterval(perBookTimeoutSeconds)
                ) {
                    try await BookSidecarBuilder.buildIfNeeded(
                        epubURL: entry.epubURL,
                        libraryID: entry.id,
                        backend: backendInstance,
                        fallbackBackend: nil,
                        store: store,
                        forceRebuild: force
                    )
                }
                switch outcome {
                case .skipped:
                    skipped += 1
                    print("\(prefix) — skipped (already on \(backend.rawValue))")
                case .built(let usedFallback, _):
                    built += 1
                    if usedFallback {
                        fellBack += 1
                        print("\(prefix) — built (fallback)")
                    } else {
                        print("\(prefix) — built")
                    }
                }
            } catch is CancellationError {
                print("\(prefix) — cancelled, stopping run")
                break
            } catch {
                failed.append((entry, error.localizedDescription))
                print("\(prefix) — FAILED: \(error.localizedDescription)")
            }
        }

        // End-of-run retry pass: re-try books whose failure looks
        // transient (429 exhaustion, 503/502/504, network) after
        // a cool-off. The per-backend retry already handled brief
        // hiccups; this catches the case where the rate-limit
        // window happens to span the whole main-pass duration so
        // every retry-budget exhausts. Cool-off gives the server
        // a chance to recover before we hammer it again.
        if !failed.isEmpty, retryCooloffSeconds > 0 {
            let retryCandidates = failed.filter { Self.looksTransient($0.error) }
            if !retryCandidates.isEmpty {
                print("")
                print("=== End-of-run retry pass ===")
                print("\(retryCandidates.count) book\(retryCandidates.count == 1 ? "" : "s") failed with transient-looking errors.")
                print("Cooling off for \(retryCooloffSeconds)s before retrying…")
                try? await Task.sleep(for: .seconds(retryCooloffSeconds))
                var retrySucceeded = 0
                var stillFailed: [(entry: CatalogEntry, error: String)] = []
                for (i, candidate) in retryCandidates.enumerated() {
                    let prefix = "[retry \(i + 1)/\(retryCandidates.count)] \(candidate.entry.title)"
                    do {
                        let outcome = try await Self.runWithTimeout(
                            seconds: TimeInterval(perBookTimeoutSeconds)
                        ) {
                            try await BookSidecarBuilder.buildIfNeeded(
                                epubURL: candidate.entry.epubURL,
                                libraryID: candidate.entry.id,
                                backend: backendInstance,
                                fallbackBackend: nil,
                                store: store,
                                forceRebuild: force
                            )
                        }
                        switch outcome {
                        case .skipped:
                            // Shouldn't happen on retry of a failed
                            // book but defensive — surface as "ok now"
                            // so the user knows it's no longer broken.
                            retrySucceeded += 1
                            print("\(prefix) — already on backend (no-op)")
                        case .built:
                            retrySucceeded += 1
                            print("\(prefix) — succeeded on retry")
                        }
                    } catch is CancellationError {
                        print("\(prefix) — cancelled, stopping retry pass")
                        break
                    } catch {
                        stillFailed.append((candidate.entry, error.localizedDescription))
                        print("\(prefix) — STILL FAILED: \(error.localizedDescription)")
                    }
                }
                // Replace the failed list with what's still broken
                // after the retry pass, plus any non-transient
                // failures we didn't re-try.
                let nonTransient = failed.filter { !Self.looksTransient($0.error) }
                failed = stillFailed + nonTransient
                built += retrySucceeded
                print("Retry pass recovered \(retrySucceeded) of \(retryCandidates.count).")
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print("")
        print("=== Reindex complete in \(Int(elapsed))s ===")
        print("Built:    \(built)")
        print("Skipped:  \(skipped)")
        print("Fallback: \(fellBack)")
        print("Failed:   \(failed.count)")
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

    // MARK: - Backend factory

    private func resolveBackend() async throws -> any EmbeddingBackend {
        switch backend {
        case .apple:
            guard let apple = NLSentenceEmbeddingBackend() else {
                throw ValidationError(
                    "Apple NL sentence-embedding model unavailable on this system."
                )
            }
            return apple
        case .ollama:
            return try await OllamaEmbeddingBackend.make(model: ollamaModel)
        case .voyage:
            // Construct an explicit keystore so the CLI binary
            // looks up the same keychain item the app wrote —
            // both keystore types build their default service
            // name from `Bundle.main.bundleIdentifier`, which
            // differs between the signed Humanist.app and the
            // `humanist-cli` executable target. Override fixes
            // the mismatch.
            let keystore = VoyageAPIKeyStore(
                service: "\(appBundleID).voyage-api-key"
            )
            return try await VoyageEmbeddingBackend.make(
                model: voyageModel, keyStore: keystore
            )
        case .gemini:
            let keystore = GeminiAPIKeyStore(
                service: "\(appBundleID).gemini-api-key"
            )
            let dim: Int? = geminiDim > 0 ? geminiDim : nil
            return try await GeminiEmbeddingBackend.make(
                outputDimensionality: dim, keyStore: keystore
            )
        }
    }

    // MARK: - Catalog locate + decode

    private func resolveCatalogURL() throws -> URL {
        if let catalog {
            let url = URL(fileURLWithPath: catalog).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("Catalog not found at \(url.path)")
            }
            return url
        }
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

    /// Minimal catalog entry — `library-dedupe`-style hand-decode
    /// so the CLI doesn't depend on the Humanist app's full
    /// `LibraryEntry` shape (which is iCloud-sync aware, has
    /// genre / conversion-type / etc.). Only id + epubURL + title
    /// are needed for re-indexing.
    /// Per-book watchdog. Mirrors `LibraryIndexBuilder.runWithTimeout`
    /// in shape — pathological books that hang inside an embedding
    /// call or a retry loop get cancelled at the deadline so the
    /// outer loop moves on. Without this the CLI's `reindex` could
    /// stall indefinitely on a single bad entry (the user reported
    /// the run getting stuck after entry 1942 of 2250 because a
    /// 503 retry compounded across sub-batches into a multi-minute
    /// wait per chunk).
    ///
    /// On timeout, the work task is cancelled and the helper throws
    /// `ReindexBookTimedOut` — surfaces in the failures list as
    /// "timed out after Xs" and feeds the end-of-run retry pass
    /// (Self.looksTransient catches the "timeout" substring).
    static func runWithTimeout<T: Sendable>(
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
            throw ReindexBookTimedOut(seconds: seconds)
        }
    }

    /// Substring-based classifier for "this looks like a
    /// transient failure worth retrying after a cool-off."
    /// Cheap and string-matchy because `EmbeddingError`'s
    /// localizedDescription doesn't expose status codes
    /// programmatically — but the canned messages it produces
    /// for serverError / network errors contain stable markers
    /// we can pattern-match against. False positives are
    /// strictly safer than false negatives here: the retry
    /// pass is bounded (single re-attempt per book), so
    /// retrying a non-transient failure just produces the same
    /// error and we surface it cleanly in the final report.
    static func looksTransient(_ error: String) -> Bool {
        let lowered = error.lowercased()
        let transientMarkers = [
            "429",          // explicit status code in EmbeddingError.serverError
            "503",          // service unavailable
            "502",          // bad gateway
            "504",          // gateway timeout
            "rate limit",   // generic rate-limit phrasing
            "rate_limit",   // Anthropic / Google error.code form
            "unavailable",  // 503 message body
            "overloaded",   // Anthropic 529; Gemini occasionally too
            "timeout",      // generic timeout
            "timed out",    // URLSession-style
            "the network",  // URLSession NSURLErrorDomain hints
            "connection",   // generic connection error
        ]
        return transientMarkers.contains { lowered.contains($0) }
    }

    private struct CatalogEntry: Sendable {
        let id: UUID
        let epubURL: URL
        let title: String
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
            out.append(CatalogEntry(id: id, epubURL: url, title: title))
        }
        return out
    }
}
