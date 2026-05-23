import Foundation
import AI
import Document

/// Cloud Phase 9 / P-Sonnet-Structure (chapter pass). One Sonnet
/// call per book that walks the splitter's chapter list and tells
/// us, for each candidate chapter break, whether it's a real
/// chapter break or a section header inside a chapter that got
/// promoted incorrectly. Also normalizes titles (OCR cruft removal)
/// and refines `epub:type` (chapter / preface / appendix / etc).
///
/// Why Sonnet here when the rest of the structural decisions use
/// Haiku: chapter shape is a semantic question that benefits from
/// the stronger model. The cost is bounded — one call per book,
/// ~5K input tokens (chapter titles + opening text per chapter)
/// + ~1K output (decision per chapter). Lands around $0.03–$0.05
/// per book at Sonnet 4.6 rates. Negligible next to the other
/// Cloud features.
///
/// Conservative posture: rejected candidates are MERGED into the
/// previous chapter (the splitter's break point becomes a section
/// header inside the merged chapter), never deleted. Accepted
/// candidates may have their title / epub:type updated. The pass
/// does NOT propose new chapter breaks the splitter missed — that
/// would need full-document text and a more expensive call;
/// follow-up if measurement on the corpus warrants it.
///
/// Returns the chapter list unchanged on budget exhaustion /
/// refusal / parse failure / no decisions — same fail-open
/// posture as `ClaudeCoherenceAnalyzer`.
public struct ClaudeChapterStructureAnalyzer: Sendable {
    public let client: AnthropicAPIClient
    public let budget: CloudCallBudget
    public var model: CloudModel
    public var maxOutputTokens: Int

    public init(
        client: AnthropicAPIClient,
        budget: CloudCallBudget,
        model: CloudModel = .sonnet4_6,
        maxOutputTokens: Int = 2048
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    /// Per-chapter decision from Sonnet. `index` matches the input
    /// chapter index; `accept` is the headline call — when false,
    /// the caller merges this chapter's content into the previous
    /// chapter. `title` and `epubType` carry refinements when
    /// `accept` is true. Nil fields mean "keep the original."
    public struct Decision: Sendable, Equatable, Hashable {
        public let index: Int
        public let accept: Bool
        public let title: String?
        public let epubType: String?
        /// Human-readable note (rejection reason, title-change
        /// rationale). Surfaced in the debug log for diagnostic
        /// review; never user-facing.
        public let note: String?

        public init(
            index: Int, accept: Bool,
            title: String? = nil, epubType: String? = nil,
            note: String? = nil
        ) {
            self.index = index
            self.accept = accept
            self.title = title
            self.epubType = epubType
            self.note = note
        }
    }

    /// Run the pass + apply the decisions. Returns the refined
    /// chapter list. On any failure path (budget exhausted, API
    /// error, refusal, parse failure, empty decisions) returns
    /// the input chapters unchanged.
    public func analyzeAndApply(chapters: [Chapter]) async -> [Chapter] {
        let decisions = await analyze(chapters: chapters)
        guard !decisions.isEmpty else { return chapters }
        return Self.apply(decisions: decisions, to: chapters)
    }

    /// The Sonnet-call half of the pass. Returns the raw decisions
    /// (no application). Empty on any failure path.
    public func analyze(chapters: [Chapter]) async -> [Decision] {
        // Need at least two chapters for the pass to be useful —
        // with a single chapter there's nothing to validate as a
        // break (nothing for it to be a break "from").
        guard chapters.count >= 2 else { return [] }
        let digest = Self.buildDigest(chapters: chapters)
        guard !digest.isEmpty else { return [] }
        guard await budget.tryConsume() else { return [] }
        try? Task.checkCancellation()

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
            // Cache the system prompt — same prompt across every
            // book, so the second-book call onward hits the cache.
            system: .cached(Self.systemPrompt, ttl: .oneHour),
            messages: [
                Message(role: .user, content: .plain(digest)),
            ],
            thinking: .disabled
        )

        let response: AnthropicMessageResponse
        do {
            response = try await client.send(request)
        } catch {
            return []
        }
        await budget.recordUsage(response.usage, for: model)

        if response.didRefuse { return [] }
        guard let raw = response.primaryText, !raw.isEmpty else { return [] }
        return Self.parse(raw, expectedCount: chapters.count)
    }

    // MARK: - digest

    /// Build the Sonnet input. Format per chapter:
    ///
    ///   Chapter 0
    ///   currentTitle: <title or "(untitled)">
    ///   epubType:     <current type or "(none)">
    ///   firstHeading: <first heading block in chapter, if any>
    ///   opening:      <first ~300 chars of body paragraphs>
    ///
    /// Cap at `maxChars` total so very long books still fit in
    /// Sonnet's context window comfortably. Caps the per-chapter
    /// opening at 300 chars — that's enough for Sonnet to recognize
    /// "this looks like an appendix that got split as a chapter"
    /// without spending tokens on full chapter bodies.
    public static func buildDigest(
        chapters: [Chapter], maxChars: Int = 16000
    ) -> String {
        var out = ""
        for (idx, ch) in chapters.enumerated() {
            if out.count >= maxChars { break }
            out += "Chapter \(idx)\n"
            out += "currentTitle: \(ch.title?.nonEmpty ?? "(untitled)")\n"
            out += "epubType:     \(ch.epubType?.nonEmpty ?? "(none)")\n"
            if let heading = firstHeading(in: ch) {
                out += "firstHeading: \(heading)\n"
            }
            let opening = openingText(of: ch, maxChars: 300)
            if !opening.isEmpty {
                out += "opening: \(opening)\n"
            }
            out += "\n"
        }
        return String(out.prefix(maxChars))
    }

    private static func firstHeading(in chapter: Chapter) -> String? {
        for block in chapter.blocks {
            guard case .heading(_, let runs) = block else { continue }
            let text = runs.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    private static func openingText(of chapter: Chapter, maxChars: Int) -> String {
        var collected = ""
        for block in chapter.blocks {
            guard case .paragraph(let runs) = block else { continue }
            let text = runs.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if collected.isEmpty {
                collected = text
            } else {
                collected += " " + text
            }
            if collected.count >= maxChars { break }
        }
        return String(collected.prefix(maxChars))
    }

    // MARK: - parse

    /// Decode Sonnet's response. Expected wire shape:
    ///   `{"decisions":[{"index":0,"accept":true,"title":"...","epubType":"chapter","note":"..."}, ...]}`
    /// Strips outer code-fence wrappers. Returns empty on decode
    /// failure or when no decisions match an actual chapter index
    /// (guards against the model wildly miscounting).
    public static func parse(
        _ raw: String, expectedCount: Int
    ) -> [Decision] {
        let cleaned = stripCodeFence(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let data = cleaned.data(using: .utf8) else {
            return []
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            return []
        }
        return wire.decisions
            .filter { $0.index >= 0 && $0.index < expectedCount }
            .map { d in
                Decision(
                    index: d.index, accept: d.accept,
                    title: d.title?.nonEmpty,
                    epubType: d.epubType?.nonEmpty,
                    note: d.note?.nonEmpty
                )
            }
    }

    private struct Wire: Decodable {
        struct D: Decodable {
            let index: Int
            let accept: Bool
            let title: String?
            let epubType: String?
            let note: String?
        }
        let decisions: [D]
    }

    static func stripCodeFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
            return trimmed
        }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if !lines.isEmpty { lines.removeFirst() }
        if !lines.isEmpty,
           lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - apply

    /// Apply the decisions to the chapter list. Strategy:
    ///   * Iterate left-to-right.
    ///   * For each chapter, look up its decision (if any).
    ///   * `accept == true`: update title / epub:type per the
    ///     decision; emit the chapter as-is otherwise.
    ///   * `accept == false`: merge this chapter's content into
    ///     the previous emitted chapter. The candidate "chapter
    ///     break" becomes content within the previous chapter
    ///     (its first block becomes a section break inside that
    ///     chapter). If this is index 0 (the first chapter), we
    ///     can't merge backwards — keep it as-is.
    ///
    /// Decisions for indices the model invented or that don't
    /// match a real chapter are silently dropped by `parse`.
    /// Chapters with no decision keep their original shape.
    public static func apply(
        decisions: [Decision], to chapters: [Chapter]
    ) -> [Chapter] {
        let byIndex = Dictionary(
            uniqueKeysWithValues: decisions.map { ($0.index, $0) }
        )
        var result: [Chapter] = []
        for (idx, original) in chapters.enumerated() {
            let decision = byIndex[idx]
            // No-decision OR accepted: emit (possibly with updates).
            if decision?.accept ?? true {
                var copy = original
                if let newTitle = decision?.title {
                    copy.title = newTitle
                }
                if let newType = decision?.epubType {
                    copy.epubType = newType
                }
                result.append(copy)
                continue
            }
            // Rejected — merge backwards. Index-0 can't merge; keep.
            guard !result.isEmpty else {
                result.append(original)
                continue
            }
            var prev = result.removeLast()
            // Promote this chapter's title to an h2 heading inside
            // the merged chapter, so its content stays addressable
            // in the prose. Skip when there's no title (the merge
            // is then seamless).
            if let title = original.title?.nonEmpty {
                let heading = Block.heading(
                    level: 2,
                    runs: [InlineRun(title)]
                )
                prev.blocks.append(heading)
            }
            prev.blocks.append(contentsOf: original.blocks)
            prev.footnotes.append(contentsOf: original.footnotes)
            result.append(prev)
        }
        return result
    }

    // MARK: - prompt

    static let systemPrompt = """
        You are reviewing the chapter structure of a book that an OCR pipeline has split into chapters. \
        Each entry in the user message describes one chapter the pipeline produced — its current title, \
        EPUB structural type, first heading (if any), and the first few hundred characters of body text. \
        Your job is to validate each chapter break.

        For each chapter, decide:
        1. ACCEPT or REJECT. Accept when this really is the start of a new chapter, preface, appendix, \
        bibliography, or other top-level book section. Reject when the chapter break is wrong — for example, \
        when the "chapter" is actually a mid-chapter section header that the heuristic splitter promoted by \
        mistake, or a running header / page artifact mistaken for a heading. Rejected chapters get merged \
        into the previous chapter; their content is preserved.
        2. TITLE: a clean canonical title for the chapter. Strip OCR cruft (stray digits, leading numerals \
        if redundant with chapter numbering, broken word fragments). Use null when the current title is \
        already clean.
        3. EPUB:TYPE: one of these EPUB 3 structural roles:
           chapter, preface, foreword, introduction, prologue, epilogue, conclusion, afterword,
           dedication, acknowledgements, contributors, copyright-page, titlepage, halftitlepage,
           toc, appendix, bibliography, glossary, index, notes, errata, abstract, part.
           Use null when the current type is already correct, or when no specific type applies and "chapter" is fine.

        Conservative posture: REJECTing is a strong call — only reject when the evidence is clear (mid-chapter \
        section header pattern, no plausible chapter content, etc.). When uncertain, ACCEPT and leave the title \
        and epub:type unchanged.

        Do NOT propose new chapter breaks the pipeline missed; that's out of scope for this pass.

        Output ONE JSON object, no preamble or commentary, no markdown code fences. Schema:

        {
          "decisions": [
            {
              "index": 0,
              "accept": true,
              "title": "Introduction" | null,
              "epubType": "preface" | null,
              "note": "short reason for the decision; optional"
            },
            ...
          ]
        }

        Include an entry for every chapter index in the input. Use null (not empty string) for fields you don't want to change.
        """
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
