import Foundation
import FoundationModels
import EPUB
import AI

/// R-Topics Phase 2. On-device AFM extractor for the
/// intellectual concepts a book engages with — multi-word
/// concepts ("will to power", "speech act theory"), single-word
/// concepts ("deconstruction", "liberalism"), and domain terms
/// ("biopolitics", "heterotopia") that statistical noun-phrase
/// mining and the user's curated alias dictionary together
/// can't fully cover.
///
/// Same architectural shape as `BookGenreClassifier`:
/// schema-guided `@Generable` constraint, AFM on-device, free
/// (no API cost). One call per book; result is persisted to
/// `BookConceptStore` so the ~5-10 second AFM cost never repeats
/// unless the user explicitly re-extracts.
///
/// **Input shape:** title + author + a sampled digest of the
/// book's chapter content (first ~200 chars of each chapter,
/// capped at a total of ~5 KB so the prompt fits comfortably
/// inside AFM's ~8K-token context window with room for the
/// instructions + response). The digest gives the model enough
/// signal to identify the book's central concepts without
/// flooding it.
///
/// **Output shape:** 5-15 lowercase canonical concept strings.
/// `BookEntityIndex.build` folds them into the alias-scan path
/// at sidecar build time, attaching paragraph anchors so the
/// federated `LibraryConceptGraph` rollup picks them up.
public struct BookConceptExtractor: Sendable {
    public let client: AppleFoundationModelClient

    public init(client: AppleFoundationModelClient = AppleFoundationModelClient()) {
        self.client = client
    }

    /// Identifier for the model that generated a given payload.
    /// Persisted in `BookConceptStore.Payload.modelIdentifier` so
    /// a future bulk-re-extract can target older identifiers
    /// (e.g. when a major AFM upgrade ships).
    public static let modelIdentifier = "afm-on-device-1"

    /// Extract concepts for one book. Returns nil when AFM is
    /// unavailable, when the model declines, or when the framework
    /// errors. Caller treats nil as "nothing to write" — the next
    /// re-extract attempt re-runs the call.
    public func extract(
        title: String?,
        author: String?,
        chapterSamples: [String]
    ) async -> [String]? {
        try? Task.checkCancellation()
        guard case .available = AppleFoundationModelClient.availability
        else { return nil }
        let prompt = Self.makePrompt(
            title: title, author: author, chapterSamples: chapterSamples
        )
        do {
            let response: BookConceptList = try await client.respond(
                instructions: Self.instructions,
                prompt: prompt
            )
            return Self.canonicalize(response.concepts)
        } catch {
            return nil
        }
    }

    /// Build the chapter-sample digest from an open `EPUBBook`.
    /// Walks the spine in order, strips XHTML tags from each
    /// resource's text, slices the first `perChapterChars`
    /// characters, and stops once the cumulative size hits
    /// `totalCharsCap`. Same posture as
    /// `BookBriefingService.extractFrontMatter` — sample enough
    /// content to identify central concepts without blowing the
    /// AFM context window.
    public static func sampleChapters(
        from book: EPUBBook,
        perChapterChars: Int = 200,
        totalCharsCap: Int = 5_000
    ) -> [String] {
        var out: [String] = []
        var total = 0
        for id in book.spine {
            guard let resource = book.resourcesByID[id],
                  let xhtml = resource.text else { continue }
            let body = stripTags(xhtml)
            guard !body.isEmpty else { continue }
            let slice = String(body.prefix(perChapterChars))
            out.append(slice)
            total += slice.count
            if total >= totalCharsCap { break }
        }
        return out
    }

    // MARK: - @Generable schema

    @Generable
    struct BookConceptList {
        @Guide(description: "5-15 intellectual concepts that this book engages with at length. Prefer specific intellectual terms over generic phrases. Examples of what to surface: 'will to power', 'deconstruction', 'liberalism', 'speech act theory', 'biopolitics', 'critical theory', 'phenomenological reduction', 'artificial intelligence', 'social contract', 'evolutionary fitness'. Skip generic phrases ('the self', 'history', 'thought', 'people', 'time'). Skip the names of specific people, places, or organizations — those are caught elsewhere. Output lowercase canonical forms. Empty when the book genuinely doesn't engage with identifiable intellectual concepts.")
        var concepts: [String]
    }

    // MARK: - Prompt construction

    private static func makePrompt(
        title: String?,
        author: String?,
        chapterSamples: [String]
    ) -> String {
        let titleLine = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : "Title: \($0)"
        } ?? "Title: (none)"
        let authorLine = (author?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : "Author: \($0)"
        } ?? "Author: (none)"
        let samplesBody = chapterSamples.isEmpty
            ? "(no chapter samples)"
            : chapterSamples.enumerated().map { idx, sample in
                "Chapter \(idx + 1) opening: \(sample)"
            }.joined(separator: "\n\n")
        return """
            \(titleLine)
            \(authorLine)

            Chapter samples:
            \(samplesBody)
            """
    }

    /// Stable instructions string. The guidance leans hard on
    /// "intellectual concepts" specifically — without it AFM tends
    /// to drift into generic noun phrases ("the book," "the
    /// argument") or section labels ("introduction," "conclusion")
    /// that don't help the Topics view.
    static let instructions = """
        You extract a list of intellectual concepts from a book. Output a JSON-shaped list of 5-15 lowercase canonical concept strings.

        What counts as a concept:
          * Named intellectual concepts: will to power, deconstruction, liberalism, biopolitics, hermeneutics, social contract, speech act, phenomenological reduction, critical theory, artificial intelligence, qualia, performativity, intersectionality.
          * Theoretical frameworks: structuralism, post-structuralism, pragmatism, naturalism, existentialism, neoliberalism.
          * Domain-specific terms that show up centrally in the book's argument.

        What does NOT count:
          * Names of specific people, places, or organizations (those are extracted elsewhere).
          * Generic phrases: "the self," "human nature," "thought," "history," "matter," "the book."
          * Section labels: "introduction," "conclusion," "preface."
          * Single common nouns that aren't intellectual concepts: "table," "house," "person."

        Output lowercase canonical forms ("will to power" not "Will to Power"). Prefer 1-3 token phrases. Return an empty list when the book doesn't engage with identifiable intellectual concepts.
        """

    // MARK: - Helpers

    /// Normalize whatever AFM returned: trim whitespace, lowercase,
    /// drop empties, dedupe in input order. AFM is well-behaved
    /// here but defending against minor format drift (extra
    /// whitespace, mixed case from model variance) keeps the
    /// downstream alias-scan path simple.
    private static func canonicalize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for concept in raw {
            let trimmed = concept
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            out.append(trimmed)
        }
        return out
    }

    /// XHTML strip mirroring `BookBriefingService.stripTags`. Keep
    /// the two implementations behaviorally aligned — both feed
    /// AFM and benefit from the same noise removal.
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
