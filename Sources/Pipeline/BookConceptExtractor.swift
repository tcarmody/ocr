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

    /// Identifier for the model + prompt revision that generated
    /// a given payload. Persisted in
    /// `BookConceptStore.Payload.modelIdentifier` so a future
    /// bulk-re-extract can target older identifiers.
    ///
    /// History:
    ///   * `afm-on-device-1` — initial prompt: 5-15 concepts,
    ///     ~200 chars/chapter sample, restrictive "doesn't count"
    ///     list.
    ///   * `afm-on-device-2` (current) — broader prompt: 10-25
    ///     concepts, 600 chars/chapter sample, includes
    ///     medium-generic "big ideas" when central to the book.
    public static let modelIdentifier = "afm-on-device-2"

    /// Extract concepts for one book. Returns nil when AFM is
    /// unavailable, when the model declines, or when the framework
    /// errors. Caller treats nil as "nothing to write" — the next
    /// re-extract attempt re-runs the call.
    public func extract(
        title: String?,
        author: String?,
        chapterSamples: [String]
    ) async -> [String]? {
        let outcome = await extractWithDiagnostic(
            title: title, author: author, chapterSamples: chapterSamples
        )
        return outcome.concepts
    }

    /// Result tuple returned by `extractWithDiagnostic`. Lets the
    /// caller distinguish "AFM declined" (empty list, no error)
    /// from "AFM threw" (context overflow, framework error,
    /// cancellation). The CLI surfaces the diagnostic so users can
    /// tell apart silent declines vs. context-window blowouts.
    public struct ExtractionOutcome: Sendable {
        public let concepts: [String]?
        public let errorDescription: String?

        public init(concepts: [String]?, errorDescription: String? = nil) {
            self.concepts = concepts
            self.errorDescription = errorDescription
        }
    }

    public func extractWithDiagnostic(
        title: String?,
        author: String?,
        chapterSamples: [String]
    ) async -> ExtractionOutcome {
        try? Task.checkCancellation()
        guard case .available = AppleFoundationModelClient.availability
        else {
            return ExtractionOutcome(
                concepts: nil, errorDescription: "AFM unavailable"
            )
        }
        let prompt = Self.makePrompt(
            title: title, author: author, chapterSamples: chapterSamples
        )
        do {
            let response: BookConceptList = try await client.respond(
                instructions: Self.instructions,
                prompt: prompt
            )
            return ExtractionOutcome(
                concepts: Self.canonicalize(response.concepts)
            )
        } catch {
            return ExtractionOutcome(
                concepts: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    /// Multi-pass extraction: run AFM once per batch, union the
    /// results, dedupe in first-seen order, and cap at
    /// `maxMergedConcepts`. Lets us cover MORE of the book than a
    /// single context-window-bounded pass — each batch sees a
    /// distinct range of chapters, so concepts that develop late
    /// in a long book finally surface.
    ///
    /// Errors are aggregated, not fatal: a single chunk that
    /// throws (context overflow on a pathological chapter, AFM
    /// hiccup) still lets the other chunks contribute. The
    /// returned `errorDescription` is non-nil only when EVERY
    /// chunk failed.
    ///
    /// Concept ordering: first-seen across chunks. A concept that
    /// appears in chunks 1, 2, AND 3 is positioned by chunk 1's
    /// emission — gives early-book "thesis" concepts visual
    /// priority over late-book asides, which matches reader
    /// expectation.
    public func extractMerged(
        title: String?,
        author: String?,
        chapterBatches: [[String]],
        maxMergedConcepts: Int = 30
    ) async -> ExtractionOutcome {
        guard !chapterBatches.isEmpty else {
            return ExtractionOutcome(concepts: [])
        }
        var merged: [String] = []
        var seen = Set<String>()
        var errors: [String] = []
        for (idx, batch) in chapterBatches.enumerated() {
            try? Task.checkCancellation()
            let outcome = await extractWithDiagnostic(
                title: title, author: author, chapterSamples: batch
            )
            if let message = outcome.errorDescription {
                errors.append("chunk \(idx + 1): \(message)")
                continue
            }
            guard let concepts = outcome.concepts else { continue }
            for concept in concepts {
                guard !seen.contains(concept) else { continue }
                seen.insert(concept)
                merged.append(concept)
                if merged.count >= maxMergedConcepts { break }
            }
            if merged.count >= maxMergedConcepts { break }
        }
        // Aggregate error only when no chunk produced anything.
        let aggregateError = (merged.isEmpty && !errors.isEmpty)
            ? "all chunks failed: \(errors.joined(separator: "; "))"
            : nil
        return ExtractionOutcome(
            concepts: merged.isEmpty ? nil : merged,
            errorDescription: aggregateError
        )
    }

    /// Build the chapter-sample digest from an open `EPUBBook`.
    /// Walks the spine in order, strips XHTML tags from each
    /// resource's text, slices the first `perChapterChars`
    /// characters, and stops once the cumulative size hits
    /// `totalCharsCap`. Same posture as
    /// `BookBriefingService.extractFrontMatter` — sample enough
    /// content to identify central concepts without blowing the
    /// AFM context window.
    /// Sample sizes calibrated to fit AFM's effective context
    /// window once instructions + @Generable schema + response
    /// budget are accounted for. 15_000 chars was too aggressive
    /// — AFM started declining on longer books (the 4K-token
    /// input cap that some Foundation Model configurations
    /// enforce). 350 × 30 chapters ≈ 10_500 chars worst case,
    /// well clear of the wall while still giving the model 3×
    /// more text per chapter than the v1 prompt's 200 chars.
    ///
    /// **For richer coverage of long books**, prefer
    /// `sampleChapterBatches(...)` + `extractMerged(...)` which
    /// runs AFM N times per book (each on a distinct chapter
    /// range) and merges the results. This single-pass helper
    /// stays available for short books / fast-path callers
    /// where a 1× pass is enough.
    public static func sampleChapters(
        from book: EPUBBook,
        perChapterChars: Int = 350,
        totalCharsCap: Int = 9_000
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

    /// Multi-batch sampler. Walks every chapter in the spine,
    /// slices the first `perChapterChars` of each, then greedy-
    /// packs the slices into batches of ≤ `maxCharsPerBatch`.
    /// Stops accepting new batches at `maxBatches` (drops content
    /// from the tail end of the book — typically endnotes /
    /// indices that we don't lose much by skipping).
    ///
    /// Default sizing:
    ///   * 500 chars/chapter — 1.4× the single-pass extractor's
    ///     350 char window, since each batch has dedicated AFM
    ///     headroom.
    ///   * 5_500 chars/batch — well clear of AFM's effective
    ///     input cap (~4K tokens).
    ///   * 4 batches max — caps per-book AFM cost at ~4× a
    ///     single-pass extraction (~20s vs. ~5s on AFM
    ///     wall-time). At 444 books × ~20s = ~2.5 hours for a
    ///     full --force re-extract; ok for an unattended run.
    ///
    /// A 30-chapter book hits 2-3 batches; a 6-chapter essay
    /// collection fits in 1; an 80-chapter annotated edition
    /// hits the 4-batch ceiling + skips the final ~30 chapters.
    public static func sampleChapterBatches(
        from book: EPUBBook,
        perChapterChars: Int = 500,
        maxCharsPerBatch: Int = 5_500,
        maxBatches: Int = 4
    ) -> [[String]] {
        var allSamples: [String] = []
        for id in book.spine {
            guard let resource = book.resourcesByID[id],
                  let xhtml = resource.text else { continue }
            let body = stripTags(xhtml)
            guard !body.isEmpty else { continue }
            allSamples.append(String(body.prefix(perChapterChars)))
        }
        guard !allSamples.isEmpty else { return [] }

        var batches: [[String]] = []
        var current: [String] = []
        var currentChars = 0
        for sample in allSamples {
            if !current.isEmpty,
               currentChars + sample.count > maxCharsPerBatch {
                batches.append(current)
                if batches.count >= maxBatches { return batches }
                current = []
                currentChars = 0
            }
            current.append(sample)
            currentChars += sample.count
        }
        if !current.isEmpty, batches.count < maxBatches {
            batches.append(current)
        }
        return batches
    }

    // MARK: - @Generable schema

    @Generable
    struct BookConceptList {
        @Guide(description: "10-25 intellectual concepts and 'big ideas' that this book engages with at length. Include both specific intellectual terms ('will to power', 'deconstruction', 'speech act theory', 'biopolitics', 'phenomenological reduction', 'artificial intelligence', 'evolutionary fitness') AND medium-generic concepts when they're central to the argument ('consciousness', 'autonomy', 'justice', 'memory', 'identity', 'freedom', 'power', 'authenticity', 'representation', 'meaning'). Skip only the most generic phrases ('the book', 'history', 'thought', 'people', 'time', 'the world', 'life', 'nature'). Skip the names of specific people, places, or organizations — those are caught by the entity index. Output lowercase canonical forms. Empty list when the book genuinely doesn't engage with identifiable intellectual concepts.")
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
        You extract a list of intellectual concepts and "big ideas" from a book. Output a JSON-shaped list of 10-25 lowercase canonical concept strings.

        What counts as a concept:
          * Named intellectual concepts: will to power, deconstruction, liberalism, biopolitics, hermeneutics, social contract, speech act, phenomenological reduction, critical theory, artificial intelligence, qualia, performativity, intersectionality.
          * Theoretical frameworks: structuralism, post-structuralism, pragmatism, naturalism, existentialism, neoliberalism, feminism, marxism.
          * Medium-generic "big ideas" when they're central to the book's argument: consciousness, autonomy, justice, memory, identity, freedom, power, authenticity, representation, meaning, language, ethics, knowledge, perception, ideology, agency, embodiment, narrative.
          * Domain-specific terms that show up centrally in the book's argument.

        What does NOT count:
          * Names of specific people, places, or organizations (those are extracted by the entity index).
          * The most generic phrases that any book might mention: "the book," "history," "thought," "people," "time," "the world," "life," "nature."
          * Section labels: "introduction," "conclusion," "preface."
          * Single common nouns that aren't intellectual concepts: "table," "house," "person."

        Prefer book-defining concepts over passing mentions. A medium-generic term like "consciousness" should appear only if the book's argument actually engages with it (e.g., a philosophy of mind text), not just because the word appears.

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
