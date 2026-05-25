import Foundation
import EPUB
import AI

/// One-off pre-reading briefing for an open book. Backs the
/// "Briefing" affordance in the per-book chat pane chrome
/// (feature #13 from the "think big" brainstorm).
///
/// Goal: when the user opens a book they haven't read, surface a
/// briefing that says what the book is doing, what tradition it
/// sits in, what cross-references in their library would help,
/// and what to watch for. Especially useful for translated /
/// dense texts where the book's own introduction is itself a wall.
///
/// Architecture v1 — single-shot streaming send, no tool use:
///   • extract the book's front matter (first ~3 spine chapters,
///     capped at 30 KB) and pass it inline;
///   • render the catalog (titles + authors of every other book
///     in the library) as a short reference list so the model can
///     name specific cross-references the user actually owns;
///   • stream the model's reply into `briefing` for the sheet to
///     render incrementally.
///
/// Tool use is deferred to a follow-up. The catalog alone gives
/// the model strong cross-reference signal — most library books
/// are in its training data — and skipping the agentic loop keeps
/// the v1 implementation focused. If real use shows the briefing
/// needs to actually quote from cross-reference books, that's
/// where tool use earns its complexity.
@MainActor
final class BookBriefingService: ObservableObject {

    /// Currently-accumulating briefing text. Grows as SSE deltas
    /// arrive; the sheet observes this and renders incrementally.
    @Published private(set) var briefing: String = ""
    /// True while a send is in flight. The sheet shows a progress
    /// indicator and disables retry while this is set.
    @Published private(set) var isStreaming: Bool = false
    /// User-facing error string when the send fails. Cleared on
    /// next `start`.
    @Published var error: String?

    private let client: AnthropicAPIClient
    private let ollama: OllamaClient
    private var task: Task<Void, Never>?

    init() {
        let keyStore = AnthropicAPIKeyStore()
        self.client = AnthropicAPIClient(
            apiKeyProvider: { keyStore.read() }
        )
        self.ollama = OllamaClient()
    }

    /// Resolve the current chat backend the same way `BookChatViewModel`
    /// does — single UserDefaults key shared across all chat surfaces.
    /// Briefing follows the user's choice so an Ollama-only user gets
    /// a local briefing rather than a missingAPIKey error.
    private var resolvedBackend: ChatBackend {
        if let raw = UserDefaults.standard.string(forKey: "humanist.chat.backend"),
           let b = ChatBackend(rawValue: raw) {
            return b
        }
        return UserDefaults.standard.bool(forKey: "humanist.chat.useSonnet")
            ? .cloudSonnet : .cloudHaiku
    }

    private var resolvedOllamaModel: String {
        let raw = UserDefaults.standard.string(forKey: "humanist.chat.ollamaModel")
            ?? ""
        return raw.isEmpty ? "qwen3.5:9b" : raw
    }

    deinit { task?.cancel() }

    // MARK: - Public entry point

    /// Kick off a briefing for `book` against the user's `library`
    /// catalog. Idempotent — calling again while a briefing is in
    /// flight cancels the prior task and starts fresh, matching
    /// the sheet's "Retry" affordance.
    ///
    /// `entry` carries the catalog metadata (author, title);
    /// `book` is the loaded EPUBBook used to extract front matter.
    /// `library` is read for the catalog summary so the model can
    /// name specific cross-references the user owns.
    func start(
        book: EPUBBook,
        entry: LibraryEntry?,
        bookTitle: String,
        library: LibraryStore?
    ) {
        task?.cancel()
        briefing = ""
        error = nil
        isStreaming = true

        let frontMatter = Self.extractFrontMatter(from: book)
        let author = entry?.author
        let currentBookURL = entry?.epubURL

        // Resolve a catalog subset on a background task before
        // starting the streaming send. The retrieval step is async
        // (resolveForChat() + backend.embed() are both async) and
        // can take a few hundred ms; doing it before the model call
        // means the model only sees relevant cross-references rather
        // than every book in the user's library. Falls back to the
        // full catalog if the federated index isn't built yet —
        // the framing in the prompt keeps that workable on cloud
        // backends and the user can always run library chat once
        // to seed the on-disk index.
        task = Task { [weak self] in
            guard let self else { return }
            let catalog = await self.selectCatalogCandidates(
                library: library,
                frontMatter: frontMatter,
                currentBook: currentBookURL
            )
            let userPrompt = Self.buildUserPrompt(
                bookTitle: bookTitle,
                author: author,
                frontMatter: frontMatter,
                catalog: catalog
            )
            await self.runSend(userPrompt: userPrompt)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isStreaming = false
    }

    // MARK: - Send

    private func runSend(userPrompt: String) async {
        defer {
            isStreaming = false
            task = nil
        }
        let backend = resolvedBackend
        do {
            switch backend {
            case .cloudHaiku, .cloudSonnet:
                try await runCloud(
                    userPrompt: userPrompt,
                    model: backend == .cloudSonnet ? .sonnet4_6 : .haiku4_5
                )
            case .localOllama:
                try await runOllama(userPrompt: userPrompt)
            }
        } catch is CancellationError {
            return
        } catch let err as AnthropicAPIError {
            error = err.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runCloud(userPrompt: String, model: CloudModel) async throws {
        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: 2000,
            system: .cached(Self.systemPrompt, ttl: .oneHour),
            messages: [Message(role: .user, content: .plain(userPrompt))],
            thinking: .disabled
        )
        let stream = client.sendStream(request)
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let chunk):
                briefing += chunk
            case .messageStop:
                break
            }
        }
    }

    private func runOllama(userPrompt: String) async throws {
        let stream = ollama.chatStream(
            model: resolvedOllamaModel,
            system: Self.systemPrompt,
            history: [],
            userMessage: userPrompt
        )
        for try await chunk in stream {
            try Task.checkCancellation()
            briefing += chunk
        }
    }

    // MARK: - Prompts

    /// Cached across runs so multiple briefings (e.g. user
    /// re-runs after the first response) share the system-prompt
    /// cache prefix and only pay for the user-message delta.
    ///
    /// **Important framing:** the SUBJECT of every briefing is the
    /// single book the user is about to read. The library catalog
    /// (when supplied) is purely a cross-reference list — do not
    /// brief on the catalog itself. Local models in particular
    /// have a habit of pivoting to "summarize this bibliography"
    /// when the catalog text is large; the instructions below are
    /// worded to head that off.
    private static let systemPrompt: String = """
    You're writing a pre-reading briefing about ONE specific book \
    the user is about to open. The book is identified at the top \
    of the user's message and its front matter (preface / \
    introduction / opening chapters) is supplied below that. Brief \
    the user on THIS BOOK and nothing else.

    Some messages also include a list of other books in the user's \
    personal library, under a separate "Other books in my library" \
    section. That list is provided ONLY as a pool of candidate \
    cross-references. Do NOT brief on, summarize, categorize, or \
    analyze the library list itself. Do NOT discuss "clusters" or \
    "themes" of the user's reading list. The briefing is about the \
    one book named at the top.

    Cover, in this order:

    1. **What the book is doing**: the central argument or aim of \
       the named book, in your own words, two or three sentences. \
       Lean on the front matter — that's why it's supplied.
    2. **Tradition and stakes**: what intellectual lineage the \
       named book sits in, what debate or problem it engages with, \
       why it mattered (or matters).
    3. **Cross-references the user owns**: if a library catalog \
       was supplied, pick at most two or three books from it that \
       would meaningfully sharpen this specific read — a \
       predecessor, an interlocutor, a respondent. Call them out \
       by exact title and author. Don't invent books that aren't \
       in the catalog. Don't list every loosely-related book. If \
       no catalog was supplied, omit this section entirely.
    4. **What to watch for**: one or two concrete things to keep \
       an eye on while reading the named book. A central concept \
       the author introduces, a structural feature of the \
       argument, a common pitfall in reading this kind of book.

    Tone: a colleague briefing a colleague before they sit down \
    with the book — substantive, specific, not promotional. \
    Avoid generic phrasing like "explores themes of"; quote or \
    paraphrase the front matter when concrete. Keep the whole \
    briefing to 4-5 well-developed paragraphs; if the book is \
    short or front matter sparse, a tighter briefing is fine.

    Render in Markdown with the section labels above as bold \
    inline headers (not separate h2s) so the briefing reads as \
    one continuous note.
    """

    private static func buildUserPrompt(
        bookTitle: String,
        author: String?,
        frontMatter: String,
        catalog: String
    ) -> String {
        // Lead with the book name + the task so the model's first
        // attention pass lands on the subject before it sees the
        // (potentially much larger) front matter or catalog dump.
        // Local models in particular pivot to whatever's biggest
        // unless the subject is restated unambiguously up front.
        var out = "Please write a pre-reading briefing about ONE book: "
        out += "**\(bookTitle)**"
        if let author, !author.isEmpty {
            out += " by \(author)"
        }
        out += ".\n\n"
        out += "The briefing is about this book only — not about my library, "
        out += "not about a reading list. Below is the book's own front matter "
        out += "(opening chapters) for you to draw on.\n\n"
        out += "=== FRONT MATTER OF \"\(bookTitle)\" ===\n\n"
        out += frontMatter
        out += "\n\n=== END FRONT MATTER ===\n"
        if !catalog.isEmpty {
            out += "\nFor cross-reference candidates only (these are NOT "
            out += "the subject of the briefing — they are other books I "
            out += "already own, which you may name in section 3 if any "
            out += "would meaningfully sharpen the read of \"\(bookTitle)\"):\n\n"
            out += catalog
        }
        return out
    }

    // MARK: - Front matter extraction

    /// Pull the first N=3 spine items' text from the EPUB.
    /// Sufficient to surface preface / introduction / opening
    /// chapter content for most non-fiction; fiction-heavy books
    /// won't have much "briefing" material anyway. Capped at
    /// `frontMatterCharCap` so a very long preface doesn't blow
    /// the prompt size on Sonnet's 200 K window (we leave room
    /// for the model's response + the catalog).
    private static let frontMatterChapterCount = 3
    private static let frontMatterCharCap = 30_000

    private static func extractFrontMatter(from book: EPUBBook) -> String {
        var out = ""
        let count = min(frontMatterChapterCount, book.spine.count)
        for i in 0..<count {
            let id = book.spine[i]
            guard let resource = book.resourcesByID[id],
                  let xhtml = resource.text else { continue }
            let title = chapterTitle(from: xhtml) ?? "Chapter \(i + 1)"
            let body = stripTags(xhtml)
            guard !body.isEmpty else { continue }
            if !out.isEmpty { out += "\n\n" }
            out += "## \(title)\n\n\(body)"
            if out.count >= frontMatterCharCap { break }
        }
        if out.count > frontMatterCharCap {
            out = String(out.prefix(frontMatterCharCap))
            out += "\n\n[front matter truncated — \(book.spine.count - count) more chapters in spine]"
        }
        return out
    }

    /// Render the library catalog as a compact list — title +
    /// author per line, current book excluded. The model uses
    /// this to identify cross-references the user actually owns
    /// rather than recommending books they don't have.
    /// Excludes the open book itself (passed as `currentBook`)
    /// since the briefing target shouldn't appear in its own
    /// cross-references.
    private static func renderCatalog(
        library: LibraryStore?,
        currentBook: URL?
    ) -> String {
        guard let library else { return "" }
        var lines: [String] = []
        let currentCanonical = currentBook?.canonicalForFile
        for entry in library.entries {
            if let currentCanonical,
               entry.epubURL.canonicalForFile == currentCanonical {
                continue
            }
            if let author = entry.author, !author.isEmpty {
                lines.append("• \"\(entry.title)\" — \(author)")
            } else {
                lines.append("• \"\(entry.title)\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Catalog selection (embedding-retrieved subset)

    /// Number of distinct cross-reference candidates to surface.
    /// Calibrated to a chunk small enough that the model treats the
    /// list as candidates rather than as the subject of the briefing,
    /// large enough that the actually-relevant 2-3 books the system
    /// prompt asks for are likely to be in the pool.
    private static let crossReferenceTopK = 40

    /// Front-matter slice fed to the embedding backend as the
    /// retrieval query. Capped well below the model's input limit
    /// for any backend Humanist supports; the briefing's prompt
    /// shape (preface / introduction / opening chapter) means the
    /// first few thousand characters already carry the book's
    /// argumentative thrust.
    private static let queryDigestCharCap = 4000

    /// Pick the cross-reference catalog the model sees. When the
    /// user already has a federated library index on disk (built by
    /// any library-scope chat session), embed the front-matter
    /// digest with the current chat embedding backend and pull the
    /// top-K nearest distinct books out of the index — the same
    /// machinery library chat uses for retrieval, narrowed to one
    /// book per hit.
    ///
    /// Falls back to the full alphabetical catalog when:
    ///   * the library is nil or empty;
    ///   * the embedding backend can't be resolved;
    ///   * no fresh on-disk index exists for the resolved backend;
    ///   * the embed call throws.
    ///
    /// We *never* trigger an index build from this path — first
    /// briefings on a fresh library would otherwise block 30+
    /// seconds while every book's sidecar gets loaded. The
    /// fallback is the same shape the original briefing used, and
    /// the framing in `buildUserPrompt` + `systemPrompt` keeps it
    /// workable. Users on Ollama who want a small catalog should
    /// run library chat once to seed the cache.
    func selectCatalogCandidates(
        library: LibraryStore?,
        frontMatter: String,
        currentBook: URL?
    ) async -> String {
        guard let library, !library.entries.isEmpty else { return "" }

        // Fallback policy diverges by chat backend:
        //   * Cloud Sonnet/Haiku handle a 30 KB catalog with the
        //     hardened framing; if no index is on disk yet, give
        //     them the full catalog — better than no cross-refs.
        //   * Local models (Qwen 9B) drift onto the catalog as the
        //     subject even with the framing locked down. Suppress
        //     the catalog entirely when no index is available so
        //     the briefing stays book-focused; cross-refs come
        //     back once the federated index is built (one library
        //     chat session seeds it).
        let backendIsLocal = resolvedBackend == .localOllama
        let fallback: () -> String = {
            backendIsLocal
                ? ""
                : Self.renderCatalog(
                    library: library, currentBook: currentBook
                )
        }

        let resolution = await BackendResolver.resolveForChat()
        guard let backend = resolution.backend else { return fallback() }

        let entries = library.entries
        let fingerprint = FederatedIndexCache.fingerprint(
            backendIdentifier: backend.identifier,
            dimension: backend.dimension,
            entries: entries
        )
        guard let payload = FederatedIndexCache.load(
            expectedFingerprint: fingerprint,
            backendIdentifier: backend.identifier,
            dimension: backend.dimension
        ) else {
            return fallback()
        }
        let index = LibraryEmbeddingIndex(
            sources: payload.sources,
            backend: backend,
            stats: payload.stats
        )

        let digest = String(frontMatter.prefix(Self.queryDigestCharCap))
        guard !digest.isEmpty else { return fallback() }
        let queryVector: [Float]
        do {
            let vectors = try await backend.embed([digest])
            guard let first = vectors.first, !first.isEmpty else {
                return fallback()
            }
            queryVector = first
        } catch {
            return fallback()
        }

        // Search a wide paragraph window and collapse to distinct
        // books in the rank order they emerge. 200 hits gives plenty
        // of headroom — most books have many paragraphs in the
        // index, so the same book recurring is the common case.
        let excludeSet: Set<URL> = currentBook.map { [$0] } ?? []
        let hits = index.search(
            queryVector: queryVector,
            topK: 200,
            excluding: excludeSet
        )
        guard !hits.isEmpty else { return fallback() }

        var seenPaths = Set<String>()
        var lines: [String] = []
        for hit in hits {
            let key = hit.epubURL.canonicalForFile
                .standardizedFileURL.path
            if seenPaths.contains(key) { continue }
            seenPaths.insert(key)
            if let author = hit.bookAuthor, !author.isEmpty {
                lines.append("• \"\(hit.bookTitle)\" — \(author)")
            } else {
                lines.append("• \"\(hit.bookTitle)\"")
            }
            if lines.count >= Self.crossReferenceTopK { break }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - XHTML helpers

    /// Pull a chapter title from the first <h1>/<h2>/<title> in
    /// the XHTML. Mirrors `BookChatViewModel.chapterTitle(from:)`
    /// — extracted to a static helper here so the briefing
    /// service doesn't have to hold a reference to the chat VM
    /// just for two tiny regex passes.
    private static func chapterTitle(from xhtml: String) -> String? {
        for tag in ["h1", "h2", "title"] {
            if let range = xhtml.range(
                of: "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>",
                options: .regularExpression
            ) {
                let chunk = String(xhtml[range])
                let inner = chunk.replacingOccurrences(
                    of: "<[^>]+>", with: "",
                    options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { return inner }
            }
        }
        return nil
    }

    /// Strip XHTML tags + decode the common named entities.
    /// Same posture as `BookChatViewModel.stripTags`.
    private static func stripTags(_ xhtml: String) -> String {
        var s = xhtml.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression
        )
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&nbsp;": " "
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
