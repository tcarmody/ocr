import Foundation
import AppKit
import AI
import Document
import EPUB
import Pipeline

// `AISettings` lives in the AI module above; we read the user's
// `localFeatures` snapshot to decide whether to invoke the AFM
// metadata extractor + chapter classifier at import time. The
// classifier consumes a `Chapter` IR (`Document` module) built
// from each spine resource's XHTML — a minimal sampler suffices
// since the classifier reads only title + ~200 chars of opening
// text.

/// R-EPUB-Import. Take existing EPUBs (already-edited books, books
/// converted from documents the user no longer has, books from other
/// sources) and bring them into the Humanist library: inject
/// paragraph anchors, optionally run an AFM metadata-extraction
/// pass to populate the OPF, copy to the configured Books folder,
/// catalog in `LibraryStore`, and build the federated-chat
/// embedding sidecar.
///
/// Idempotent on re-import — already-anchored books pass through the
/// injector unchanged and the catalog entry updates in place rather
/// than duplicating.
///
/// Source URLs may be individual `.epub` files or directories;
/// `expandSources(_:)` walks directories recursively for `.epub`
/// children so a user can drag a folder of EPUBs onto the Library
/// window (or pick one through the menu) and have every book inside
/// imported in one batch.
///
/// AFM passes: `BookMetadataExtractor` runs on the first ~4KB of
/// stripped front-matter text and writes title + author back into
/// `book.metadata` when the on-device model is available + the
/// `localMetadataExtraction` setting is on. Chapter classification
/// and the coherence pass require constructing a Chapter IR from
/// the imported XHTML, which is a follow-up; today they only run
/// during the PDF conversion path that already has the IR in hand.
@MainActor
final class EPUBImporter: ObservableObject {

    enum Status: Equatable {
        case idle
        case running
        case completed
        case cancelled
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// 1-based "importing N of M". Drives the progress sheet's
    /// counter.
    @Published private(set) var current: Int = 0
    @Published private(set) var total: Int = 0
    @Published private(set) var currentTitle: String = ""
    /// Books that errored during import. UI shows these so the user
    /// can decide whether to investigate (often one bad EPUB; rest
    /// of the batch succeeds).
    @Published private(set) var failures: [Failure] = []
    /// Successfully-imported destination URLs in import order.
    @Published private(set) var imported: [URL] = []
    /// Books skipped because their destination already had an EPUB
    /// + a catalog row + (when indexing is requested) a matching
    /// sidecar. Surfaced separately from `imported` so the user
    /// can tell "I re-ran a batch after interruption" apart from
    /// "all my books are fresh imports." Critical at 1000-book
    /// scale where partial re-runs are common.
    @Published private(set) var skippedExisting: Int = 0

    struct Failure: Identifiable {
        let id = UUID()
        let sourceURL: URL
        let error: String
    }

    enum ImportError: Error, LocalizedError {
        case sourceMissing(URL)
        case destinationConflict(String)
        case openFailed(underlying: Error)
        case saveFailed(underlying: Error)
        case repackFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let url):
                return "Source EPUB doesn't exist: \(url.lastPathComponent)"
            case .destinationConflict(let detail):
                return "Couldn't pick a destination filename: \(detail)"
            case .openFailed(let e):
                return "Couldn't open EPUB: \(e.localizedDescription)"
            case .saveFailed(let e):
                return "Couldn't save EPUB: \(e.localizedDescription)"
            case .repackFailed(let e):
                return "Couldn't repack EPUB: \(e.localizedDescription)"
            }
        }
    }

    private var task: Task<Void, Never>?

    init() {}

    deinit { task?.cancel() }

    /// Kick off a batch import. UI builds the `sources` list (from a
    /// NSOpenPanel multi-select); the importer owns the per-book
    /// orchestration + progress publishing.
    ///
    /// `indexBackend` is the resolved embedding backend the federated
    /// chat will use; passed through so the per-book sidecar gets
    /// built against the right vector space. Nil skips the indexing
    /// step (book still appears in the catalog; chat won't retrieve
    /// from it until a separate index pass runs).
    ///
    /// `skipIndexing` is the explicit "don't build sidecars now"
    /// flag — useful for large batches where the user prefers to
    /// run the bulk-index command overnight separately. Defaults
    /// to off so single-import / small-batch behavior is
    /// unchanged.
    func start(
        sources: [URL],
        library: LibraryStore,
        indexBackend: (any EmbeddingBackend)?,
        skipIndexing: Bool = false
    ) {
        guard status != .running else { return }
        status = .running
        current = 0
        total = sources.count
        currentTitle = ""
        failures = []
        imported = []
        skippedExisting = 0
        let store = EmbeddingsSidecarStore()
        // Snapshot effective backend up front. When the user
        // requested skipIndexing, drop the backend entirely so
        // downstream code stays a single path (one knob instead of
        // two interacting flags).
        let effectiveBackend: (any EmbeddingBackend)? = skipIndexing
            ? nil : indexBackend
        // Register with the coordinator if we're going to write to
        // sidecars. A skipIndexing run only touches catalog + EPUB
        // files (sidecars deferred to a later bulk-index pass), so
        // chat reads can safely proceed during it — no token in
        // that branch.
        let token: VectorIndexCoordinator.Token? = effectiveBackend != nil
            ? VectorIndexCoordinator.shared.begin(
                sources.count == 1
                    ? "Importing 1 book"
                    : "Importing \(sources.count) books"
              )
            : nil
        // Batch publishes: a 1000-book bulk import otherwise fires
        // 1000 individual `library.entries` republishes, each one
        // re-rendering every observer (Library window's 2k-row
        // Table + sidebar + chat pane). begin/end pairs hold the
        // publishes until the loop completes; the importer's own
        // per-book progress updates surface on the progress sheet
        // independently. Skip the bulk window for single-source
        // imports — one publish is cheaper than the buffer swap.
        let useBulk = sources.count > 1
        if useBulk { library.beginBulkUpdate() }
        task = Task { [weak self] in
            for (idx, source) in sources.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self?.current = idx + 1
                    self?.currentTitle = source
                        .deletingPathExtension().lastPathComponent
                }
                do {
                    let result = try await Self.importOne(
                        source: source,
                        library: library,
                        backend: effectiveBackend,
                        sidecarStore: store
                    )
                    await MainActor.run {
                        if result.alreadyImported {
                            self?.skippedExisting += 1
                        } else {
                            self?.imported.append(result.destinationURL)
                        }
                    }
                } catch is CancellationError {
                    // Mid-book cancel — bubble out of the loop.
                    // The task-cancel branch in the completion
                    // block handles status transitions.
                    break
                } catch {
                    await MainActor.run {
                        self?.failures.append(Failure(
                            sourceURL: source,
                            error: error.localizedDescription
                        ))
                    }
                }
            }
            await MainActor.run {
                if useBulk { library.endBulkUpdate() }
                guard let self else { token?.release(); return }
                self.status = Task.isCancelled ? .cancelled : .completed
                self.currentTitle = ""
                token?.release()
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Source expansion

    /// Resolve a mixed list of URLs (individual `.epub` files and
    /// directories) into a flat list of `.epub` files. Directories
    /// walk recursively. Used by the drag-drop handler and the
    /// `NSOpenPanel` callback so both paths feed `start(sources:)`
    /// the same shape.
    static func expandSources(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        var seen: Set<String> = []
        for url in urls {
            if isDirectory(url) {
                out.append(contentsOf: epubsRecursively(in: url))
            } else if url.pathExtension.lowercased() == "epub" {
                out.append(url)
            }
        }
        // Drop duplicates a user might create by dragging both a
        // folder and a file inside it; preserve first-seen order.
        return out.filter { url in
            let key = url.standardizedFileURL.path
            return seen.insert(key).inserted
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDir
        )
        return exists && isDir.boolValue
    }

    private static func epubsRecursively(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "epub" {
                found.append(url)
            }
        }
        // Stable sort so a folder import has a deterministic order
        // independent of FileManager's enumeration quirks.
        return found.sorted { $0.path < $1.path }
    }

    // MARK: - Per-book orchestration

    /// Per-book result. Surfaces the destination URL for the catalog
    /// row + a flag distinguishing fresh imports from skipped re-runs.
    private struct ImportResult {
        let destinationURL: URL
        let alreadyImported: Bool
    }

    /// Open + anchor + save + repack + catalog + index in one shot.
    /// Pure async; no UI work. The caller (`start`) does the
    /// main-actor progress publishing around each call.
    ///
    /// Throws `CancellationError` when the task is cancelled
    /// between major steps, so a user pressing Cancel mid-batch
    /// can stop within seconds rather than waiting for the
    /// current book's full pipeline to finish.
    private static func importOne(
        source: URL,
        library: LibraryStore,
        backend: (any EmbeddingBackend)?,
        sidecarStore: EmbeddingsSidecarStore
    ) async throws -> ImportResult {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ImportError.sourceMissing(source)
        }

        // 0. Quick-skip path: resolve where the import would land,
        // then short-circuit when (a) a real EPUB already exists
        // at that path AND (b) the catalog already lists it AND
        // (c) either we're not indexing or the sidecar already
        // matches the configured backend. At 1000-book scale this
        // turns "re-run after interruption" from hours-of-rework
        // into seconds-of-FS-checks.
        let destination = try await MainActor.run {
            try Self.destinationURL(for: source, library: library)
        }
        if await shouldSkipExistingImport(
            destination: destination,
            library: library,
            backend: backend,
            sidecarStore: sidecarStore
        ) {
            return ImportResult(destinationURL: destination, alreadyImported: true)
        }
        try Task.checkCancellation()

        // 1. Open via the EPUBBook in-memory model. Unzips into a
        // temp directory; the book owns its lifecycle.
        let book: EPUBBook
        do {
            book = try EPUBBook.open(epubURL: source)
        } catch {
            throw ImportError.openFailed(underlying: error)
        }
        try Task.checkCancellation()

        // 2. Inject paragraph anchors. Idempotent — already-anchored
        // books pass through unchanged. Marks touched resources
        // dirty so the saver flushes them.
        _ = ParagraphAnchorInjector.injectAnchors(in: book)
        try Task.checkCancellation()

        // 2.5. Optional AFM metadata pass. Reads the user's
        // `localMetadataExtraction` toggle off the same AISettings
        // snapshot the conversion pipeline reads; gated on AFM
        // availability + a non-stub front-matter. Writes title +
        // author + year + publisher + ISBN into `book.metadata`;
        // the saver upserts each `<dc:*>` field on flush. ISBN
        // adds as a separate `<dc:identifier>` so the package's
        // unique-identifier stays untouched.
        await runMetadataExtraction(on: book)
        try Task.checkCancellation()

        // 2.6. Optional AFM chapter classification. For each spine
        // resource: build a minimal Chapter (title + opening
        // text), run the classifier, write the returned
        // `epub:type` label into the resource's `<body>` opening
        // tag via `BodyTypeInjector`. Existing publisher-set
        // `epub:type` attributes are preserved — see
        // `BodyTypeInjector` doc for the conservative posture
        // rationale.
        await runChapterClassification(on: book)
        try Task.checkCancellation()

        // 2.7. Optional AFM coherence pass. Builds a digest of
        // every spine resource (title + ~2KB of body text per
        // chapter), asks AFM for up to 10 recurring-OCR-error
        // suggestions, filters through the same length-ratio /
        // occurrence-floor / no-collision guardrails as the
        // conversion path, then applies surviving rewrites
        // directly on the XHTML via `XHTMLTextReplacer` — text
        // nodes only, never tags / attributes / CSS / scripts.
        // No `Chapter` round-trip, so publisher-specific
        // formatting that `Chapter` doesn't model survives
        // intact. Cloud equivalent intentionally not invoked
        // here — same posture as `runMetadataExtraction`:
        // imports stay free.
        await runCoherencePass(on: book)
        try Task.checkCancellation()

        // 3. Save dirty resources back into the working directory.
        // No-ops cleanly when nothing changed (e.g. re-import).
        do {
            try EPUBBookSaver().save(book)
        } catch {
            throw ImportError.saveFailed(underlying: error)
        }

        // 5. Repack working directory → destination EPUB. (Step
        // numbering preserves the v1 commentary; destination
        // resolution moved earlier as part of the skip-existing
        // short-circuit so the path is decided before any work.)
        do {
            try EPUBRepacker().repack(
                workingDirectory: book.workingDirectory,
                to: destination
            )
        } catch {
            throw ImportError.repackFailed(underlying: error)
        }
        try Task.checkCancellation()

        // 6. Catalog. Title + language come from the OPF (resolved
        // via the in-memory book's metadata). `recordConversion`
        // dedupes by canonical destination URL, so a re-import that
        // lands at the same path updates the existing row.
        let title = book.displayTitle
        let languages = book.metadata.language
            .flatMap { $0.isEmpty ? nil : [$0] } ?? []
        let author = book.metadata.author
            .flatMap { $0.isEmpty ? nil : $0 }
        // R-Auto-Collections Phase 2: run the genre classifier
        // alongside the metadata + chapter passes — same AFM
        // gating, same cost model (free, on-device). Sampling
        // reuses the front-matter helpers already used for
        // metadata extraction.
        let genre = await runGenreClassification(
            on: book, title: title, author: author
        )
        try Task.checkCancellation()

        let libraryID: UUID? = await MainActor.run {
            // R-Auto-Collections Phase 1: imports have no OCR
            // pipeline behind them — they're digital sources by
            // definition. Stamp as .digital + carry through
            // whatever author the AFM metadata pass populated.
            // Phase 2 layers on the genre stamp from the
            // classifier; nil when AFM declined or wasn't
            // available — the backfill command picks those up
            // later.
            library.recordConversion(
                epubURL: destination,
                title: title,
                languages: languages,
                conversionType: .digital,
                author: author,
                genre: genre
            )
            // Read back the entry's UUID so the sidecar build can
            // key by it under R-Library-Sync Phase B.
            return library.entries.first(where: {
                $0.epubURL.canonicalForFile == destination.canonicalForFile
            })?.id
        }

        // 7. Build the embedding sidecar so library chat sees the
        // book immediately. Skipped when no backend is available —
        // the catalog row stays, just without retrieval-time recall.
        if let backend {
            _ = try await BookSidecarBuilder.buildIfNeeded(
                epubURL: destination,
                libraryID: libraryID,
                backend: backend,
                store: sidecarStore,
                forceRebuild: false
            )
        }

        return ImportResult(destinationURL: destination, alreadyImported: false)
    }

    /// Decide whether a source can short-circuit the full import
    /// pipeline. Returns true only when ALL three conditions hold:
    ///   * a real file exists at `destination`,
    ///   * the catalog already lists a row pointing at it,
    ///   * either no backend was requested (caller is in
    ///     skip-indexing mode) OR the persisted sidecar matches
    ///     the requested backend's identifier + dimension and is
    ///     non-empty.
    /// Exposed `internal` for tests; not part of the importer's
    /// public surface.
    static func shouldSkipExistingImport(
        destination: URL,
        library: LibraryStore,
        backend: (any EmbeddingBackend)?,
        sidecarStore: EmbeddingsSidecarStore
    ) async -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path)
        else { return false }
        let canonicalDest = destination.canonicalForFile
        let libraryID: UUID? = await MainActor.run {
            library.entries.first(where: {
                $0.epubURL.canonicalForFile == canonicalDest
            })?.id
        }
        guard libraryID != nil else { return false }
        guard let backend else {
            // skip-indexing path — file + catalog row is enough.
            return true
        }
        guard let sidecar = sidecarStore.read(
                for: destination, libraryID: libraryID
              ),
              sidecar.backendIdentifier == backend.identifier,
              sidecar.dimension == backend.dimension,
              !sidecar.paragraphs.isEmpty
        else { return false }
        return true
    }

    // MARK: - AFM metadata pass

    /// Run on-device metadata extraction over the book's front
    /// matter and write title + author into `book.metadata` when
    /// the model returns usable values. Silently skipped when the
    /// user has the toggle off, when AFM isn't available on this
    /// device, or when there isn't enough front-matter text to
    /// extract anything reliably (`BookMetadataExtractor` itself
    /// gates on ~80 chars minimum).
    ///
    /// Only the AFM path runs on import — the conversion pipeline
    /// has the Claude extractor for cloud mode, but invoking it
    /// here would mean a Cloud call per import which the user
    /// didn't opt into. AFM is free + offline, so on-by-default is
    /// the right shape; the existing `localMetadataExtraction`
    /// Settings toggle is the off switch.
    private static func runMetadataExtraction(on book: EPUBBook) async {
        let settings = AISettingsStore().load()
        guard settings.localFeatures.localMetadataExtraction else { return }
        guard case .available = AppleFoundationModelClient.availability
        else { return }
        let frontMatter = sampleFrontMatterText(from: book)
        guard frontMatter.count >= 80 else { return }
        let extractor = AppleFoundationModelMetadataExtractor()
        guard let result = await extractor.extract(
            frontMatterText: frontMatter
        ) else { return }
        applyMetadata(result, to: book)
    }

    private static func applyMetadata(
        _ result: ClaudeMetadataExtractor.Result,
        to book: EPUBBook
    ) {
        // Prefer extracted values when present; preserve whatever
        // the OPF originally carried otherwise. The user can
        // always rename / re-author the book in the editor if AFM
        // gets it wrong.
        //
        // Year / publisher / ISBN flow through too now that
        // `OPFReader.Metadata` carries them and the saver knows
        // how to upsert each (ISBN as a separate
        // `<dc:identifier>urn:isbn:…</dc:identifier>` so the
        // package's unique-identifier stays untouched).
        let existing = book.metadata
        let updated = OPFReader.Metadata(
            title: result.title ?? existing.title,
            author: result.author ?? existing.author,
            language: existing.language,
            year: result.year ?? existing.year,
            publisher: result.publisher ?? existing.publisher,
            isbn: result.isbn ?? existing.isbn
        )
        // No-op when nothing actually changed — avoid marking the
        // book dirty (and triggering a save) when the OPF already
        // had the right values.
        if updated == existing { return }
        book.metadata = updated
    }

    /// Strip XHTML to plain text and concatenate the first ~4KB of
    /// the first two spine resources. Imitates
    /// `ClaudeMetadataExtractor.sampleFrontMatter(from: [Chapter])`
    /// but on an in-memory `EPUBBook` so we don't need a Chapter IR.
    private static func sampleFrontMatterText(
        from book: EPUBBook, maxChars: Int = 4000
    ) -> String {
        var collected = ""
        let head = book.spine.prefix(2)
        for resourceID in head {
            guard let resource = book.resourcesByID[resourceID],
                  let xhtml = resource.text else { continue }
            let plain = stripXHTML(xhtml)
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

    /// Lightweight tag stripper. Mirrors the regex-based approach
    /// in `BookChatViewModel.stripTags` — sufficient for "give me
    /// the visible prose of this XHTML" tasks like front-matter
    /// sampling. Decodes the small handful of named entities most
    /// scanned books emit; numeric entities pass through.
    private static func stripXHTML(_ s: String) -> String {
        var out = s.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression
        )
        out = out.replacingOccurrences(of: "&nbsp;", with: " ")
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        out = out.replacingOccurrences(of: "&lt;", with: "<")
        out = out.replacingOccurrences(of: "&gt;", with: ">")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&#39;", with: "'")
        out = out.replacingOccurrences(of: "&apos;", with: "'")
        // Collapse runs of whitespace introduced by tag elision.
        out = out.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        return out
    }

    // MARK: - AFM genre classification

    /// R-Auto-Collections Phase 2. Classify the book's genre via
    /// the AFM closed-enum classifier. Same gating as the
    /// metadata + chapter passes (AISettings toggle + AFM
    /// availability + non-stub front-matter). Returns nil when
    /// any guard fails — the catalog row's `genre` stays nil and
    /// the backfill command (`LibraryAutoCollections
    /// .classifyMissingGenres`) picks it up later.
    private static func runGenreClassification(
        on book: EPUBBook,
        title: String,
        author: String?
    ) async -> BookGenre? {
        let settings = AISettingsStore().load()
        // Re-use the chapter-classification toggle — same on-
        // device cost shape and the user opted into AFM for
        // similar work. A separate "auto-classify genres" toggle
        // is a v1.1 if anyone wants finer control.
        guard settings.localFeatures.localChapterClassification else { return nil }
        guard case .available = AppleFoundationModelClient.availability
        else { return nil }
        let opening = sampleFrontMatterText(from: book)
        guard opening.count >= 80 else { return nil }
        return await BookGenreClassifier().classify(
            title: title,
            author: author,
            openingText: opening
        )
    }

    // MARK: - AFM chapter classification

    /// Walk every spine resource, build a minimal Chapter IR, ask
    /// the AFM classifier for an `epub:type` label, and inject it
    /// into the resource's `<body>` opening tag via
    /// `BodyTypeInjector` when the classifier returns one.
    ///
    /// Silently skipped when:
    ///  * the user's `localChapterClassification` toggle is off;
    ///  * Apple Intelligence isn't available on the device;
    ///  * a resource lacks enough text to classify (no `<h1>`
    ///    title AND empty opening text).
    ///
    /// Conservative on per-resource failures: a single chapter
    /// the classifier declines just leaves that body unlabeled.
    /// One bad chapter doesn't abort the import.
    private static func runChapterClassification(on book: EPUBBook) async {
        let settings = AISettingsStore().load()
        guard settings.localFeatures.localChapterClassification else { return }
        guard case .available = AppleFoundationModelClient.availability
        else { return }
        let classifier = AppleFoundationModelClassifier()
        for resourceID in book.spine {
            guard let resource = book.resourcesByID[resourceID],
                  resource.isText,
                  let xhtml = resource.text
            else { continue }
            guard let chapter = buildMinimalChapter(from: xhtml)
            else { continue }
            guard let label = await classifier.classify(chapter: chapter)
            else { continue }
            let result = BodyTypeInjector.inject(label: label, into: xhtml)
            if result.changed {
                resource.text = result.xhtml  // marks the resource dirty
            }
        }
    }

    // MARK: - AFM coherence pass

    /// Run the AFM coherence pass over the imported book. Builds a
    /// digest of every spine resource via `CoherenceDigestSampler`,
    /// asks `AppleFoundationModelCoherenceAnalyzer` for up to 10
    /// recurring-OCR-error rewrites, filters them through
    /// `ClaudeCoherenceAnalyzer.filterByGuardrails` (length-ratio,
    /// occurrence floor, no-collision), and applies surviving
    /// rewrites to each resource's XHTML via `XHTMLTextReplacer`.
    ///
    /// Silently skipped when:
    ///  * the user's `localCoherencePass` toggle is off;
    ///  * Apple Intelligence isn't available on the device;
    ///  * the digest is too small (analyzer's input floor); or
    ///  * the analyzer returns no suggestions / none survive the
    ///    guardrails.
    ///
    /// Replacements are XHTML-aware: only character data between
    /// tags is touched. Tags, attributes, `<script>` / `<style>`
    /// bodies, comments, CDATA, and PIs pass through byte-
    /// identical so publisher-specific formatting Humanist's
    /// `Chapter` IR doesn't model is preserved on the round-trip.
    private static func runCoherencePass(on book: EPUBBook) async {
        let settings = AISettingsStore().load()
        guard settings.localFeatures.localCoherencePass else { return }
        guard case .available = AppleFoundationModelClient.availability
        else { return }

        let chapters = CoherenceDigestSampler.sampleChapters(from: book)
        guard !chapters.isEmpty else { return }

        let analyzer = AppleFoundationModelCoherenceAnalyzer()
        let raw = await analyzer.analyze(chapters: chapters)
        guard !raw.isEmpty else { return }

        let docText = ClaudeCoherenceAnalyzer.docText(for: chapters)
        let accepted = ClaudeCoherenceAnalyzer.filterByGuardrails(
            suggestions: raw, docText: docText
        )
        guard !accepted.isEmpty else { return }

        for resourceID in book.spine {
            guard let resource = book.resourcesByID[resourceID],
                  resource.isText,
                  let xhtml = resource.text
            else { continue }
            let rewritten = XHTMLTextReplacer.apply(
                suggestions: accepted, xhtml: xhtml
            )
            if rewritten != xhtml {
                resource.text = rewritten  // marks the resource dirty
            }
        }
    }

    /// Build the smallest `Chapter` the classifier will accept:
    /// title (first `<h1>` or `<title>` content stripped) + a
    /// single paragraph block containing the first ~200 chars of
    /// opening prose. The classifier's
    /// `AppleFoundationModelClassifier.makeContext` reads only
    /// `.title` and the leading paragraph/heading text, so figures,
    /// tables, footnotes, and asides can be dropped without loss.
    ///
    /// Returns nil when neither a title nor any opening text is
    /// extractable — there's nothing for the classifier to read.
    static func buildMinimalChapter(from xhtml: String) -> Chapter? {
        let title = extractFirstTitle(from: xhtml)
        let opening = extractOpeningText(from: xhtml, maxChars: 800)
        if title == nil, opening.isEmpty { return nil }
        let blocks: [Block]
        if opening.isEmpty {
            blocks = []
        } else {
            blocks = [.paragraph(runs: [InlineRun(opening)])]
        }
        return Chapter(title: title, blocks: blocks)
    }

    /// First `<h1>...</h1>` content (stripped of inline tags), or
    /// the `<title>...</title>` tag's content as a fallback. Nil
    /// when neither is present or both are empty. Public for tests.
    static func extractFirstTitle(from xhtml: String) -> String? {
        for pattern in ["<h1\\b[^>]*>([\\s\\S]*?)</h1>",
                        "<title\\b[^>]*>([\\s\\S]*?)</title>"] {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else { continue }
            let ns = xhtml as NSString
            guard let match = regex.firstMatch(
                in: xhtml,
                range: NSRange(location: 0, length: ns.length)
            ), match.numberOfRanges == 2 else { continue }
            let inner = ns.substring(with: match.range(at: 1))
            let plain = stripXHTML(inner)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty { return plain }
        }
        return nil
    }

    /// Concatenate the visible prose of the first few paragraph-
    /// bearing elements (`<p>` / `<h2>`–`<h6>` / `<blockquote>` /
    /// `<li>`) until we hit `maxChars`. Mirrors
    /// `AppleFoundationModelClassifier.openingText`'s posture but
    /// works directly on XHTML rather than a `[Block]` stream.
    static func extractOpeningText(
        from xhtml: String, maxChars: Int
    ) -> String {
        let pattern = "<(p|h[2-6]|blockquote|li)\\b[^>]*>([\\s\\S]*?)</\\1>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return "" }
        let ns = xhtml as NSString
        let matches = regex.matches(
            in: xhtml,
            range: NSRange(location: 0, length: ns.length)
        )
        var collected = ""
        for match in matches {
            guard match.numberOfRanges == 3 else { continue }
            let inner = ns.substring(with: match.range(at: 2))
            let plain = stripXHTML(inner)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.isEmpty { continue }
            if !collected.isEmpty { collected += " " }
            collected += plain
            if collected.count >= maxChars {
                return String(collected.prefix(maxChars))
            }
        }
        return collected
    }

    // MARK: - Destination resolution

    /// Resolve the destination URL inside the library's Books
    /// directory. Honors the user's configured output root when
    /// set; otherwise falls back to
    /// `~/Documents/Humanist Library/Books/` (auto-created) so the
    /// user always knows where to look for their imports.
    ///
    /// Filename comes from the source EPUB's basename. Collisions
    /// resolve by appending `(2)`, `(3)`, etc. — same posture as
    /// `EPUBBook.nextAvailableHref`. Re-importing the exact same
    /// source overwrites cleanly (the original destination's
    /// catalog row gets updated rather than duplicated), so the
    /// collision check only fires for *different* sources sharing
    /// a basename.
    private static func destinationURL(
        for source: URL,
        library: LibraryStore
    ) throws -> URL {
        let booksDirectory = booksLibraryDirectory()
        try? FileManager.default.createDirectory(
            at: booksDirectory, withIntermediateDirectories: true
        )

        let stem = source.deletingPathExtension().lastPathComponent
        let base = booksDirectory
            .appendingPathComponent(stem)
            .appendingPathExtension("epub")

        // If `base` already corresponds to an existing library
        // entry pointing at the *same* source, re-use it — that's
        // the idempotent re-import case. Compare canonical paths
        // since the library stores canonical URLs.
        let baseCanonical = base.canonicalForFile
        if library.entries.contains(where: {
            $0.epubURL.canonicalForFile == baseCanonical
        }) {
            return base
        }

        // Otherwise resolve a collision-free path.
        if !FileManager.default.fileExists(atPath: base.path) {
            return base
        }
        for i in 2..<1000 {
            let candidate = booksDirectory
                .appendingPathComponent("\(stem) (\(i))")
                .appendingPathExtension("epub")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw ImportError.destinationConflict(
            "exhausted suffix range for \(stem)"
        )
    }

    /// Root directory for imported (and converted) EPUBs. Honors
    /// the user's configured conversion output root when set;
    /// otherwise lands in `~/Documents/Humanist Library/Books/`.
    /// The fallback is deliberately visible to the user — hiding
    /// imports under Application Support would make them hard to
    /// find when the user later wants to manage the files directly.
    private static func booksLibraryDirectory() -> URL {
        if let root = ConversionOutputResolver.currentRoot() {
            return root.appendingPathComponent(
                ConversionOutputSubfolder.books, isDirectory: true
            )
        }
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return documents
            .appendingPathComponent("Humanist Library", isDirectory: true)
            .appendingPathComponent("Books", isDirectory: true)
    }
}
