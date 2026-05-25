import Foundation
import AI                 // AppleFoundationModelClient
import EPUB
import LibraryIndexing    // BookConceptStore
import Pipeline           // BookGenreClassifier, BookConceptExtractor

/// R-Auto-Collections Phase 1. Generate `BookCollection` rows from
/// `LibraryEntry` metadata — no model needed.
///
/// Two collection families today:
///   * **By Type** (Print / Manuscript / Early Print / Digital):
///     bucketed by `LibraryEntry.conversionType`. The stamp is
///     written at conversion / import time; legacy entries get a
///     sibling-PDF heuristic backfill at load time
///     (see `LibraryStore.inferConversionType`).
///   * **By Author**: grouped by `LibraryEntry.author`, filtered
///     to authors with at least `autoAuthorThreshold` books
///     (Settings-configurable; default 3).
///
/// Auto-collections carry an `autoSource` discriminator so the UI
/// can render them in a separate sidebar section + so the next
/// refresh can recycle the same `id` (collections regenerate on
/// each call; existing auto-collections matching the same source
/// are reused so user-visible IDs stay stable).
///
/// User-created collections (autoSource == nil) are never touched.
@MainActor
enum LibraryAutoCollections {

    /// Re-materialize all auto-collections from the current
    /// catalog. Drops any existing auto-collections that no longer
    /// match (e.g. an author who fell below the threshold) +
    /// updates membership on the ones that survive. Returns a
    /// summary the caller can surface in the UI.
    @discardableResult
    static func refresh(library: LibraryStore) -> RefreshResult {
        let entries = library.entries
        let threshold = currentAuthorThreshold()

        // Build the desired auto-collection set from scratch
        // against the live catalog.
        var desired: [BookCollection] = []
        desired.append(contentsOf: typeCollections(from: entries))
        desired.append(contentsOf: authorCollections(
            from: entries, threshold: threshold
        ))
        desired.append(contentsOf: genreCollections(from: entries))

        // Merge with existing auto-collections by autoSource —
        // reuse ids where possible so the user's UI selection
        // doesn't bounce on every refresh.
        let existingAuto = library.collections.filter { $0.autoSource != nil }
        let existingByKey = Dictionary(
            uniqueKeysWithValues: existingAuto.compactMap { c -> (AutoCollectionSource, BookCollection)? in
                guard let s = c.autoSource else { return nil }
                return (s, c)
            }
        )
        var merged: [BookCollection] = desired.map { d in
            guard let source = d.autoSource,
                  let existing = existingByKey[source]
            else { return d }
            var copy = d
            // Preserve the existing id + createdAt so SwiftUI
            // selection state survives the refresh.
            copy = BookCollection(
                id: existing.id,
                name: d.name,
                bookIDs: d.bookIDs,
                createdAt: existing.createdAt,
                autoSource: d.autoSource
            )
            return copy
        }

        // Keep user-created collections + the merged auto ones.
        let userCollections = library.collections.filter { $0.autoSource == nil }
        merged = userCollections + merged

        library.replaceCollections(merged)

        return RefreshResult(
            typeCount: desired.filter {
                if case .byType = $0.autoSource { return true } else { return false }
            }.count,
            authorCount: desired.filter {
                if case .byAuthor = $0.autoSource { return true } else { return false }
            }.count,
            genreCount: desired.filter {
                if case .byGenre = $0.autoSource { return true } else { return false }
            }.count,
            authorThreshold: threshold
        )
    }

    // MARK: - Generation

    private static func typeCollections(
        from entries: [LibraryEntry]
    ) -> [BookCollection] {
        var byType: [BookConversionType: [UUID]] = [:]
        for entry in entries {
            guard let t = entry.conversionType else { continue }
            byType[t, default: []].append(entry.id)
        }
        // Stable ordering (enum case order) so the sidebar lists
        // types consistently across refreshes.
        return BookConversionType.allCases.compactMap { type in
            guard let ids = byType[type], !ids.isEmpty else { return nil }
            return BookCollection(
                name: type.displayName,
                bookIDs: ids,
                autoSource: .byType(type)
            )
        }
    }

    private static func authorCollections(
        from entries: [LibraryEntry],
        threshold: Int
    ) -> [BookCollection] {
        // Group by author string with case-sensitive matching.
        // Library catalogs from AFM extraction normalize whitespace
        // already; finer dedup (e.g. "Foucault, Michel" vs
        // "Michel Foucault") is a follow-up.
        var byAuthor: [String: [UUID]] = [:]
        for entry in entries {
            let normalized = (entry.author ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            byAuthor[normalized, default: []].append(entry.id)
        }
        // Surname-sortable order so the sidebar reads naturally.
        // Quick-and-dirty: sort by the last whitespace-separated
        // token (works for "Michel Foucault" → "Foucault"; for
        // "Foucault, Michel" → ", Michel" which sorts weirdly but
        // is rare in practice).
        return byAuthor
            .filter { $0.value.count >= threshold }
            .sorted { surnameKey($0.key) < surnameKey($1.key) }
            .map { author, ids in
                BookCollection(
                    name: author,
                    bookIDs: ids,
                    autoSource: .byAuthor(author)
                )
            }
    }

    private static func surnameKey(_ author: String) -> String {
        author.split(separator: " ").last.map(String.init) ?? author
    }

    private static func genreCollections(
        from entries: [LibraryEntry]
    ) -> [BookCollection] {
        var byGenre: [BookGenre: [UUID]] = [:]
        for entry in entries {
            guard let g = entry.genre, g != .uncategorized else { continue }
            byGenre[g, default: []].append(entry.id)
        }
        // Sort by top-level (so all Fiction together, all Science
        // together, etc.) then by leaf name. The sidebar then
        // reads grouped without needing nested sections.
        return byGenre
            .map { ($0.key, $0.value) }
            .sorted { lhs, rhs in
                if lhs.0.topLevel != rhs.0.topLevel {
                    return lhs.0.topLevel < rhs.0.topLevel
                }
                return lhs.0.leafName < rhs.0.leafName
            }
            .map { genre, ids in
                BookCollection(
                    name: genre.collectionName,
                    bookIDs: ids,
                    autoSource: .byGenre(genre)
                )
            }
    }

    // MARK: - Metadata backfill (author + title + conversionType re-stamp)

    /// Walk every entry that's missing an author stamp (the
    /// dominant gap for a library that pre-dates AFM metadata
    /// extraction), open each EPUB, read OPF metadata, and save
    /// title + author back to the catalog. Also re-runs the
    /// conversionType heuristic for entries currently stamped
    /// `.digital` — the v1 heuristic only checked sibling PDFs,
    /// which missed the common "PDFs at root, EPUBs in Books/"
    /// layout. Idempotent: re-runs on already-populated entries
    /// are no-ops.
    ///
    /// Cancellable mid-walk via `Task.checkCancellation()`. The
    /// progress callback fires after each book — drives a
    /// progress sheet in the caller.
    @discardableResult
    static func backfillMissingMetadata(
        library: LibraryStore,
        progress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> Int {
        let candidates = library.entries.filter {
            $0.author == nil || $0.conversionType == .digital
        }
        let total = candidates.count
        guard total > 0 else { return 0 }
        // Batch publishes: a 1000-book backfill would otherwise
        // republish `library.entries` 1000 times, cascading into a
        // full Library-window re-render per book. begin/end bracket
        // holds them; one publish fires at the end of the loop.
        // The loop's only early exit is `break` on Task.isCancelled,
        // which falls through to the post-loop endBulkUpdate below
        // — no thrown errors here, so a defer-Task isn't needed.
        await MainActor.run { library.beginBulkUpdate() }
        var updated = 0
        for (idx, entry) in candidates.enumerated() {
            if Task.isCancelled { break }
            await progress?(idx, total)
            // Re-evaluate conversionType from the smarter
            // heuristic before opening the EPUB — cheap, no I/O
            // beyond fileExists checks.
            let inferredType = await MainActor.run {
                LibraryStore.inferConversionType(for: entry.epubURL)
            }
            let didChangeType = inferredType != .digital
                && entry.conversionType == .digital

            // Open + read OPF only if author is missing. Heavy
            // (full unzip) but reliable; iCloud's lazy download
            // pays the per-file cost on first access either way.
            var titleFromOPF: String? = nil
            var authorFromOPF: String? = nil
            if entry.author == nil {
                if let book = try? EPUBBook.open(epubURL: entry.epubURL) {
                    titleFromOPF = book.metadata.title?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    authorFromOPF = book.metadata.author?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            let changed = await MainActor.run {
                library.backfillMetadata(
                    for: entry.id,
                    title: titleFromOPF,
                    author: authorFromOPF,
                    conversionType: didChangeType ? inferredType : nil
                )
            }
            if changed { updated += 1 }
        }
        await MainActor.run { library.endBulkUpdate() }
        await progress?(total, total)
        return updated
    }

    // MARK: - Genre backfill

    /// R-Auto-Collections Phase 2. Walk every catalog entry
    /// without a `genre` stamp, sample its front matter, and run
    /// the AFM classifier. Slow at library scale (1000 books × ~2
    /// s/book = ~30 min); cancellable.
    ///
    /// `progress` is called on the main actor with `(current,
    /// total)` after each book — drives a progress sheet in the
    /// caller. Returns the count of newly-classified books.
    /// Result tuple for the genre backfill — surfaces both the
    /// "newly classified" count and the "tried but declined" count
    /// so the progress sheet can communicate the outcome honestly
    /// (a 2000-book run that classifies 30 and stamps 1970 as
    /// uncategorized is very different from one that classifies
    /// nothing because AFM is broken).
    struct GenreClassificationResult: Sendable {
        let classified: Int
        let stampedUncategorized: Int
    }

    @discardableResult
    static func classifyMissingGenres(
        library: LibraryStore,
        progress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> GenreClassificationResult {
        guard case .available = AppleFoundationModelClient.availability
        else { return GenreClassificationResult(classified: 0, stampedUncategorized: 0) }
        let classifier = BookGenreClassifier()
        // Target entries with no genre AND entries carrying a legacy
        // genre (philosophy / history / fictionLiterary — the
        // pre-refinement catch-all leaves). Re-classifying legacy
        // entries is how the 2026-05-25 taxonomy refinement
        // propagates without a manual sweep. `.uncategorized` still
        // stays put — it's the stamp the loop writes when the model
        // declines, and re-running on those is futile.
        let needsClassification = library.entries.filter { entry in
            guard let genre = entry.genre else { return true }
            return BookGenre.legacyCases.contains(genre)
        }
        let total = needsClassification.count
        guard total > 0 else {
            return GenreClassificationResult(classified: 0, stampedUncategorized: 0)
        }
        // Batch publishes — same rationale as backfillMissingMetadata.
        // The classify loop stamps `setGenre` (or `.uncategorized`)
        // on every visited entry; without bulk mode that's `total`
        // publishes, each cascading through every observer of the
        // catalog. One publish at end of loop instead.
        await MainActor.run { library.beginBulkUpdate() }
        var classified = 0
        var declined = 0
        for (idx, entry) in needsClassification.enumerated() {
            if Task.isCancelled { break }
            await progress?(idx, total)
            if let genre = await classifyOne(entry: entry, using: classifier) {
                await MainActor.run {
                    library.setGenre(genre, for: entry.id)
                }
                classified += 1
            } else {
                // Stamp `.uncategorized` so subsequent backfill runs
                // skip this entry. Without the stamp, every wand-
                // click re-tries the same un-classifiable books
                // forever (sparse front matter, OCR garbage,
                // unreadable EPUBs all return nil from classifyOne;
                // re-attempting them is futile and confuses users
                // into thinking the wand "doesn't do anything").
                // Users who want a re-attempt can clear the genre
                // from the metadata editor.
                await MainActor.run {
                    library.setGenre(.uncategorized, for: entry.id)
                }
                declined += 1
            }
        }
        await MainActor.run { library.endBulkUpdate() }
        await progress?(total, total)
        return GenreClassificationResult(
            classified: classified,
            stampedUncategorized: declined
        )
    }

    /// Open the book, sample front-matter prose, classify. Mirrors
    /// `EPUBImporter`'s metadata-extraction sampler shape. Returns
    /// nil when the EPUB can't be opened or the classifier
    /// declines.
    private static func classifyOne(
        entry: LibraryEntry,
        using classifier: BookGenreClassifier
    ) async -> BookGenre? {
        guard let book = try? EPUBBook.open(epubURL: entry.epubURL)
        else { return nil }
        let opening = sampleFrontMatterText(from: book)
        return await classifier.classify(
            title: entry.title,
            author: entry.author,
            openingText: opening
        )
    }

    /// First ~600 chars of stripped front-matter prose from the
    /// first two spine resources. Same posture as
    /// `EPUBImporter.sampleFrontMatterText`. Kept inline to avoid
    /// cross-target dependencies.
    private static func sampleFrontMatterText(
        from book: EPUBBook, maxChars: Int = 600
    ) -> String {
        var collected = ""
        for resourceID in book.spine.prefix(2) {
            guard let resource = book.resourcesByID[resourceID],
                  resource.isText,
                  let xhtml = resource.text else { continue }
            let plain = stripTags(xhtml)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.isEmpty { continue }
            if !collected.isEmpty { collected += "\n" }
            collected += plain
            if collected.count >= maxChars {
                return String(collected.prefix(maxChars))
            }
        }
        return collected
    }

    private static func stripTags(_ s: String) -> String {
        var out = s.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression
        )
        out = out.replacingOccurrences(of: "&nbsp;", with: " ")
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        out = out.replacingOccurrences(of: "&lt;", with: "<")
        out = out.replacingOccurrences(of: "&gt;", with: ">")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        return out
    }

    // MARK: - R-Topics Phase 2 concept-extraction backfill

    struct ConceptExtractionResult: Sendable {
        /// Books that didn't have a BookConceptStore payload at
        /// loop start AND produced a non-empty AFM result on this
        /// run. The sidecar build picks them up at the next index
        /// rebuild — see `extractMissingConcepts` doc note.
        let extracted: Int
        /// Books visited where AFM either declined or returned an
        /// empty list. No payload is written for these — the next
        /// bulk run retries them. (Different posture than the
        /// genre backfill's `.uncategorized` stamp; concept
        /// extraction is genuinely informational, so an empty
        /// result is less "stable answer" and more "try again
        /// later.")
        let declined: Int
    }

    /// R-Topics Phase 2. Walk the catalog, run
    /// `BookConceptExtractor` on every entry that lacks a
    /// `BookConceptStore` payload, persist the results. Each AFM
    /// call is ~5-10s; a 444-book library takes ~40-75 minutes.
    /// Cancellable mid-loop; partial progress survives because
    /// each book's payload is written atomically as soon as the
    /// AFM call returns.
    ///
    /// **Sidecar refresh note:** writing a payload doesn't itself
    /// surface the concepts in the Topics rollup — the federated
    /// view reads from the entity sidecar, which gets the
    /// concepts folded in at sidecar-build time. So the practical
    /// flow after a bulk extract is: run this command → run
    /// "Build Missing Indexes" with `forceRebuild: true` (or
    /// equivalent) so the sidecars pick up the new concepts.
    /// We don't tightly couple the two so the user can split the
    /// long-running passes across sessions.
    @discardableResult
    static func extractMissingConcepts(
        library: LibraryStore,
        progress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> ConceptExtractionResult {
        guard case .available = AppleFoundationModelClient.availability
        else { return ConceptExtractionResult(extracted: 0, declined: 0) }
        let storeDir = await MainActor.run {
            LibraryStore.resolveLibraryStateDirectory()
                .appendingPathComponent("Concepts", isDirectory: true)
        }
        let conceptStore = BookConceptStore(baseDirectory: storeDir)
        let extractor = BookConceptExtractor()
        // Target entries that don't yet have a payload. Bulk
        // re-extraction (force every book regardless) is a v1.1
        // if needed — for now, "missing concepts" is the only
        // command surfaced.
        let needsExtraction = library.entries.filter {
            !conceptStore.hasPayload(libraryID: $0.id)
        }
        let total = needsExtraction.count
        guard total > 0 else {
            return ConceptExtractionResult(extracted: 0, declined: 0)
        }
        // Snapshot the user's curated aliases once — re-reading
        // per book would just hit the same on-disk file repeatedly.
        // Union with each book's freshly-extracted concepts at the
        // entity-index rebuild site below.
        let userAliases = AliasDictionaryStore().read().terms
        let sidecarStore = EmbeddingsSidecarStore()
        var extracted = 0
        var declined = 0
        for (idx, entry) in needsExtraction.enumerated() {
            if Task.isCancelled { break }
            await progress?(idx, total)
            guard let book = try? EPUBBook.open(epubURL: entry.epubURL)
            else { declined += 1; continue }
            let samples = BookConceptExtractor.sampleChapters(from: book)
            let result = await extractor.extract(
                title: entry.title,
                author: entry.author,
                chapterSamples: samples
            )
            guard let concepts = result, !concepts.isEmpty else {
                declined += 1
                continue
            }
            let payload = BookConceptStore.Payload(
                concepts: concepts,
                generatedAt: Date(),
                modelIdentifier: BookConceptExtractor.modelIdentifier
            )
            do {
                try conceptStore.write(payload, libraryID: entry.id)
                extracted += 1
            } catch {
                declined += 1
                continue
            }
            // End-to-end pass: re-run BookEntityIndex.build with
            // the freshly-extracted concepts unioned into the
            // alias-scan path, then patch the existing sidecar's
            // entities field in place. WITHOUT this step, the
            // sidecar's entity index stays unchanged, so the
            // federated Topics rollup never sees the new
            // concepts until the next full re-index (which would
            // also re-embed every paragraph — slow, wasteful).
            // Re-running just the entity index is cheap (~5s per
            // book) and gets concepts onto the screen on the
            // very next Topics-sheet open.
            if var sidecar = sidecarStore.read(
                for: entry.epubURL, libraryID: entry.id
            ) {
                let combined = userAliases.union(Set(concepts))
                sidecar.entities = BookEntityIndex.build(
                    from: book, aliasTerms: combined
                )
                sidecarStore.write(
                    sidecar, for: entry.epubURL, libraryID: entry.id
                )
            }
        }
        await progress?(total, total)
        // Drop the federated concept-graph cache so the next
        // Topics-sheet open rebuilds from the freshly-updated
        // sidecars. The fingerprint would catch this anyway via
        // mtime changes, but the explicit invalidate avoids any
        // edge case where the OS coalesces mtime updates.
        await LibraryConceptGraphCache.shared.invalidate()
        return ConceptExtractionResult(extracted: extracted, declined: declined)
    }

    // MARK: - Settings

    /// Read the configured threshold. Falls back to 3 when unset
    /// or zero (which UserDefaults returns for missing Int keys).
    static func currentAuthorThreshold() -> Int {
        let raw = UserDefaults.standard.integer(
            forKey: ConversionSettingsKeys.autoAuthorThreshold
        )
        return raw > 0 ? raw : 3
    }

    static let defaultAuthorThreshold = 3
}

extension LibraryAutoCollections {
    struct RefreshResult: Sendable, Equatable {
        let typeCount: Int
        let authorCount: Int
        let genreCount: Int
        let authorThreshold: Int
    }
}

extension LibraryAutoCollections {
    /// Hook for the AI module — the classifier sits behind
    /// `AppleFoundationModelClient.availability` which we
    /// re-export for the backfill flow.
    @MainActor
    static func isClassifierAvailable() -> Bool {
        if case .available = AppleFoundationModelClient.availability {
            return true
        }
        return false
    }
}
