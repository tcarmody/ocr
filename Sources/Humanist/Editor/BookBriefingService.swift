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
    private var task: Task<Void, Never>?

    init() {
        let keyStore = AnthropicAPIKeyStore()
        self.client = AnthropicAPIClient(
            apiKeyProvider: { keyStore.read() }
        )
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
        let catalog = Self.renderCatalog(
            library: library, currentBook: entry?.epubURL
        )
        let author = entry?.author
        let userPrompt = Self.buildUserPrompt(
            bookTitle: bookTitle,
            author: author,
            frontMatter: frontMatter,
            catalog: catalog
        )

        task = Task { [weak self] in
            await self?.runSend(userPrompt: userPrompt)
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
        let request = AnthropicMessageRequest(
            model: .sonnet4_6,
            maxTokens: 2000,
            system: .cached(Self.systemPrompt, ttl: .oneHour),
            messages: [Message(role: .user, content: .plain(userPrompt))],
            thinking: .disabled
        )
        do {
            let stream = client.sendStream(request)
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let chunk):
                    briefing += chunk
                case .toolUse:
                    // Briefing doesn't use tools; ignore any
                    // unexpected tool_use blocks rather than
                    // erroring out.
                    break
                case .messageStop:
                    break
                }
            }
        } catch is CancellationError {
            return
        } catch let err as AnthropicAPIError {
            error = err.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Prompts

    /// Cached across runs so multiple briefings (e.g. user
    /// re-runs after the first response) share the system-prompt
    /// cache prefix and only pay for the user-message delta.
    private static let systemPrompt: String = """
    You're writing a pre-reading briefing for the user before they \
    open a book they haven't read. Given the book's front matter \
    (preface / introduction / opening chapters) and a list of other \
    books in their personal library, produce a briefing that helps \
    them get the most out of the read.

    Cover, in this order:

    1. **What the book is doing**: the central argument or aim, \
       in your own words, two or three sentences. Lean on the \
       front matter — that's why it's supplied.
    2. **Tradition and stakes**: what intellectual lineage the \
       book sits in, what debate or problem it engages with, why \
       it mattered (or matters).
    3. **Cross-references the user owns**: when the supplied \
       catalog contains books that would meaningfully sharpen \
       this read — a predecessor, an interlocutor, a respondent \
       — call them out by exact title and author. Don't invent \
       books that aren't in the catalog. Don't list every \
       loosely-related book; pick at most two or three and say \
       *why* each helps.
    4. **What to watch for**: one or two concrete things to keep \
       an eye on while reading. A central concept the author \
       introduces, a structural feature of the argument, a \
       common pitfall in reading this kind of book.

    Tone: a colleague briefing a colleague before they sit down \
    with the book — substantive, specific, not promotional. \
    Avoid generic phrasing like "explores themes of"; quote or \
    paraphrase the front matter when concrete. Keep the whole \
    briefing to 4-5 well-developed paragraphs; if the book is \
    short or front matter sparse, a tighter briefing is fine.

    Render in Markdown with the four sections above as bold inline \
    headers (not separate h2s) so the briefing reads as one \
    continuous note.
    """

    private static func buildUserPrompt(
        bookTitle: String,
        author: String?,
        frontMatter: String,
        catalog: String
    ) -> String {
        var out = "I'm about to read **\(bookTitle)**"
        if let author, !author.isEmpty {
            out += " by \(author)"
        }
        out += ". Brief me on it.\n\n"
        out += "--- Front matter from the book ---\n\n"
        out += frontMatter
        out += "\n\n--- Other books in my library (for cross-reference candidates) ---\n\n"
        out += catalog.isEmpty
            ? "(No other books are catalogued yet.)\n"
            : catalog
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
