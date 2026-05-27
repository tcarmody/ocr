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
            // Adaptive retry on context-window overflow: if AFM
            // rejects this batch as too big, halve the sample
            // content and try again. Books with token-dense content
            // (math notation, code, CJK, image captions) sometimes
            // overflow even at our conservative defaults because
            // chars/token ratio varies widely; halving recovers
            // the chunk without abandoning the book. Three attempts
            // max — beyond that the content is too dense for any
            // useful sample.
            let outcome = await extractBatchWithAdaptiveRetry(
                title: title, author: author, batch: batch
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

    /// Try one batch; if AFM throws "Exceeded model context window
    /// size", halve the per-sample content and retry. Up to two
    /// retries (three total attempts) before giving up — each
    /// halving cuts content roughly 50%, so attempt 3 sees ~25%
    /// of the original chunk's content, enough signal to surface
    /// the main concepts even on the densest material.
    ///
    /// Non-context-window errors (safety filters, network, etc.)
    /// pass through immediately — halving wouldn't help those.
    private func extractBatchWithAdaptiveRetry(
        title: String?,
        author: String?,
        batch: [String]
    ) async -> ExtractionOutcome {
        var current = batch
        var attempt = 0
        while true {
            let outcome = await extractWithDiagnostic(
                title: title, author: author, chapterSamples: current
            )
            // Pass through on success.
            if outcome.errorDescription == nil { return outcome }
            // Only retry the context-window case; safety filters /
            // other AFM errors won't benefit from a smaller input.
            let isContextOverflow = (outcome.errorDescription ?? "")
                .lowercased().contains("context window")
            guard isContextOverflow, attempt < 2,
                  !current.isEmpty
            else { return outcome }
            // Halve each sample's content. Preserves chapter
            // coverage while shrinking the prompt's token weight.
            current = current.map { sample in
                String(sample.prefix(max(50, sample.count / 2)))
            }
            attempt += 1
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
    /// Default sizing rationale:
    ///   * `perChapterChars: 600` — rich per-chapter signal.
    ///     This is the "how much information per chapter"
    ///     knob; bigger means the model sees more context for
    ///     each chapter and surfaces concepts that don't appear
    ///     in opening sentences. The previous 300-char default
    ///     traded too much coverage for batch-count economy.
    ///   * `maxCharsPerBatch: 3_500` — the AFM context-window
    ///     ceiling. Load-bearing: don't raise without
    ///     adaptive-retry headroom (token-dense content
    ///     compresses worse than 4 chars/token). Each batch
    ///     stays inside this ceiling regardless of per-chapter
    ///     size by closing the batch when the next chapter
    ///     would push over.
    ///   * `maxBatches: 8` — double the previous 4 so longer
    ///     books actually get covered. 8 batches × ~5s/batch
    ///     AFM wall-time = ~40s/book worst case. At 444 books
    ///     × 40s = ~5 hours for a full --force re-extract;
    ///     fine for an unattended caffeinate'd run.
    ///
    /// Coverage:
    ///   * 30-chapter book at 600 chars/chapter = 18K chars →
    ///     ~5-6 batches → full coverage.
    ///   * 60-chapter book = 36K chars → ~10-11 batches → hits
    ///     the 8 ceiling, drops chapters 49-60. Most books that
    ///     long have endnotes + index in the tail.
    ///   * 6-chapter essay collection = 3.6K chars → 1-2 batches.
    public static func sampleChapterBatches(
        from book: EPUBBook,
        perChapterChars: Int = 600,
        maxCharsPerBatch: Int = 3_500,
        maxBatches: Int = 8
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
