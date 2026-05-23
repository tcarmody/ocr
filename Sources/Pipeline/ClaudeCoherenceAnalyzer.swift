import Foundation
import AI
import Document

/// Tier 9 / Q-Coherence. One Haiku call per book that looks at a
/// digest of every chapter (title + first ~200 chars of body) and
/// identifies recurring OCR errors that should be normalized
/// across the whole book — character names misread the same way
/// in three places, place names with stripped diacritics,
/// ligature artifacts that survived the typography pass.
///
/// Returns a list of `Suggestion`s the caller applies as a guarded
/// global find/replace. The guardrail rejects suggestions that
/// look like hallucinations (length jumps too far, replacement
/// already present, replacement empty), and skips suggestions
/// whose `wrong` form doesn't actually recur in the document.
///
/// Cheap: one Haiku call per book, output tokens dominated by
/// the suggestion list (≤ 10 entries × ~30 chars = ~300 tokens).
/// Effectively free at Haiku rates.
public struct ClaudeCoherenceAnalyzer: Sendable {
    public let client: AnthropicAPIClient
    public let budget: CloudCallBudget
    public var model: CloudModel
    public var maxOutputTokens: Int

    public init(
        client: AnthropicAPIClient,
        budget: CloudCallBudget,
        model: CloudModel = .haiku4_5,
        maxOutputTokens: Int = 1024
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    /// One Haiku-suggested rewrite. `wrong` and `right` are
    /// verbatim strings; the caller does whitespace / punctuation
    /// matching when applying.
    public struct Suggestion: Sendable, Equatable, Hashable {
        public let wrong: String
        public let right: String

        public init(wrong: String, right: String) {
            self.wrong = wrong
            self.right = right
        }
    }

    /// Run the coherence pass. Returns the updated chapters with
    /// guardrail-accepted, document-confirmed substitutions
    /// applied. On budget exhaustion / refusal / parse failure /
    /// no suggestions, returns the input chapters unchanged.
    public func analyzeAndApply(chapters: [Chapter]) async -> [Chapter] {
        let suggestions = await analyze(chapters: chapters)
        guard !suggestions.isEmpty else { return chapters }
        return Self.applyWithGuardrails(suggestions: suggestions, to: chapters)
    }

    /// The Haiku-call half of the pass. Returns raw suggestions
    /// (without guardrail filtering or document confirmation).
    public func analyze(chapters: [Chapter]) async -> [Suggestion] {
        let digest = Self.buildDigest(chapters: chapters)
        guard digest.count >= 200 else { return [] }
        guard await budget.tryConsume() else { return [] }
        try? Task.checkCancellation()

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
            // Cache the system prompt — same prompt across every
            // book in a session, so the second-book call onward
            // hits the cache.
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
        return Self.parse(raw)
    }

    // MARK: - digest

    /// Build the input digest: chapter title + first ~200 chars of
    /// each chapter's body, capped at `maxChars` total. Walks
    /// headings + paragraphs only — figures / tables / anchors
    /// don't contribute. Surveying every chapter's opening gives
    /// Haiku enough variety to spot recurring errors without
    /// blowing the input-token budget on full-document text.
    public static func buildDigest(
        chapters: [Chapter], maxChars: Int = 8000
    ) -> String {
        var collected = ""
        for chapter in chapters {
            if collected.count >= maxChars { break }
            if let title = chapter.title, !title.isEmpty {
                collected += "[\(title)]\n"
            }
            var bodyChars = 0
            let bodyCharCap = 200
            for block in chapter.blocks {
                if bodyChars >= bodyCharCap { break }
                let text: String
                switch block {
                case .heading(_, let runs), .paragraph(let runs):
                    text = runs.map(\.text).joined()
                default:
                    continue
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let take = min(trimmed.count, bodyCharCap - bodyChars)
                collected += String(trimmed.prefix(take))
                collected += "\n"
                bodyChars += take
                if collected.count >= maxChars { break }
            }
        }
        return String(collected.prefix(maxChars))
    }

    // MARK: - parse

    /// Decode Haiku's response. Expected wire shape:
    ///   `{"suggestions":[{"wrong":"Schafer","right":"Schäfer"}, ...]}`
    /// Empty list when nothing recurs / Haiku declines to suggest.
    /// Strips outer code-fence wrappers.
    public static func parse(_ raw: String) -> [Suggestion] {
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
        return wire.suggestions
            .map { Suggestion(wrong: $0.wrong, right: $0.right) }
    }

    private struct Wire: Decodable {
        struct W: Decodable {
            let wrong: String
            let right: String
        }
        let suggestions: [W]
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

    /// Number of times `wrong` must occur in the assembled
    /// document text to qualify as "recurring" — single-occurrence
    /// candidates aren't worth a global rewrite (and may be
    /// legitimate variation the user wrote).
    public static let minOccurrences = 3

    /// Maximum length-ratio difference between `wrong` and `right`.
    /// Beyond this, the rewrite looks like a different word —
    /// reject as hallucination.
    public static let maxLengthRatio: Double = 0.5

    /// Assembled plain text from every text-bearing run in
    /// `chapters` — what the occurrence / collision guardrails
    /// count against. Exposed publicly so the EPUB-import path
    /// (which does text-only replacement directly on XHTML rather
    /// than going through `[Chapter]`) can build the same docText
    /// from its digest chapters before calling
    /// `filterByGuardrails`.
    public static func docText(for chapters: [Chapter]) -> String {
        chapters.flatMap { ch -> [String] in
            ch.blocks.flatMap { block -> [String] in
                switch block {
                case .heading(_, let runs), .paragraph(let runs):
                    return runs.map(\.text)
                case .figure(_, _, let caption):
                    return caption.map(\.text)
                case .table(let rows, let caption):
                    let cellTexts = rows.flatMap { row in
                        row.flatMap { $0.runs.map(\.text) }
                    }
                    return cellTexts + caption.map(\.text)
                case .verse(let lines):
                    return lines.flatMap { $0.runs.map(\.text) }
                case .anchor:
                    return []
                }
            }
        }.joined()
    }

    /// Filter raw suggestions through the guardrails (length-ratio,
    /// empty/equal, document-occurrence floor, no-collision). The
    /// returned list is safe to apply via string replacement on
    /// any representation of the same text (Chapter IR, raw XHTML,
    /// plain text). Exposed so callers can reuse the same gating
    /// independent of where they store the text.
    public static func filterByGuardrails(
        suggestions: [Suggestion], docText: String
    ) -> [Suggestion] {
        suggestions.filter { shouldApply(suggestion: $0, in: docText) }
    }

    /// Apply guardrail-accepted suggestions to the chapters.
    /// For each suggestion:
    ///   1. Length-ratio guardrail: `|wrong| / |right|` and
    ///      vice-versa must be within `maxLengthRatio`.
    ///   2. Empty / equal guardrail: `right` is non-empty and
    ///      different from `wrong`.
    ///   3. Document-occurrence guardrail: count `wrong` across
    ///      the assembled text; require ≥ `minOccurrences`.
    ///   4. No-collision guardrail: skip if `right` already
    ///      appears in the document — applying a "fix" that's
    ///      already valid in some passages would homogenize them
    ///      incorrectly.
    /// Surviving suggestions get applied as plain (case-sensitive)
    /// global string replacements across every text-bearing run.
    public static func applyWithGuardrails(
        suggestions: [Suggestion], to chapters: [Chapter]
    ) -> [Chapter] {
        let assembled = docText(for: chapters)
        let accepted = filterByGuardrails(
            suggestions: suggestions, docText: assembled
        )
        guard !accepted.isEmpty else { return chapters }

        return chapters.map { chapter in
            Chapter(
                title: applyToString(chapter.title, accepted: accepted),
                blocks: chapter.blocks.map {
                    applyToBlock($0, accepted: accepted)
                },
                footnotes: chapter.footnotes,
                pageAnchors: chapter.pageAnchors,
                figureAssets: chapter.figureAssets,
                epubType: chapter.epubType
            )
        }
    }

    static func shouldApply(suggestion: Suggestion, in docText: String) -> Bool {
        let w = suggestion.wrong
        let r = suggestion.right
        guard !w.isEmpty, !r.isEmpty, w != r else { return false }
        // Length-ratio guardrail.
        let wLen = Double(w.count), rLen = Double(r.count)
        let minLen = min(wLen, rLen), maxLen = max(wLen, rLen)
        guard maxLen > 0 else { return false }
        guard minLen / maxLen >= maxLengthRatio else { return false }
        // Occurrence count of `wrong` in the document. Substring
        // search is fine — the rewrites we accept are short
        // tokens that occur ≥ 3 times.
        let count = docText.components(separatedBy: w).count - 1
        guard count >= minOccurrences else { return false }
        // No-collision: `right` shouldn't already appear, or we'd
        // be homogenizing legitimate variants.
        if docText.contains(r) { return false }
        return true
    }

    private static func applyToString(_ s: String?, accepted: [Suggestion]) -> String? {
        guard var s else { return nil }
        for sug in accepted {
            s = s.replacingOccurrences(of: sug.wrong, with: sug.right)
        }
        return s
    }

    private static func applyToBlock(_ block: Block, accepted: [Suggestion]) -> Block {
        switch block {
        case .heading(let level, let runs):
            return .heading(level: level, runs: applyToRuns(runs, accepted: accepted))
        case .paragraph(let runs):
            return .paragraph(runs: applyToRuns(runs, accepted: accepted))
        case .figure(let assetId, let alt, let caption):
            return .figure(
                assetId: assetId, alt: alt,
                caption: applyToRuns(caption, accepted: accepted)
            )
        case .table(let rows, let caption):
            let updatedRows = rows.map { row in
                row.map { cell in
                    TableCell(
                        runs: applyToRuns(cell.runs, accepted: accepted),
                        isHeader: cell.isHeader,
                        rowspan: cell.rowspan,
                        colspan: cell.colspan
                    )
                }
            }
            return .table(rows: updatedRows, caption: applyToRuns(caption, accepted: accepted))
        case .verse(let lines):
            // Coherence pass corrections (typo fixes, etc.) apply
            // line-by-line — preserve the indent bucket so the
            // layout isn't reset by post-OCR cleanup.
            let updatedLines = lines.map { line in
                VerseLine(
                    runs: applyToRuns(line.runs, accepted: accepted),
                    indent: line.indent
                )
            }
            return .verse(lines: updatedLines)
        case .anchor:
            return block
        }
    }

    private static func applyToRuns(
        _ runs: [InlineRun], accepted: [Suggestion]
    ) -> [InlineRun] {
        runs.map { run in
            // Don't touch math runs — their `text` is a plain-text
            // fallback like "[formula]" or the LaTeX inner, never
            // prose the OCR-fix dictionary applies to. Rewriting
            // it would also strand the `rawXHTML` / `latexFallback`
            // markup if a substitution happened to match.
            if run.rawXHTML != nil { return run }
            var t = run.text
            for sug in accepted {
                t = t.replacingOccurrences(of: sug.wrong, with: sug.right)
            }
            return InlineRun(
                t,
                language: run.language,
                noterefId: run.noterefId,
                isItalic: run.isItalic,
                isBold: run.isBold,
                rawXHTML: run.rawXHTML,
                latexFallback: run.latexFallback
            )
        }
    }

    // MARK: - prompt

    static let systemPrompt = """
        You audit OCR output from a book for RECURRING errors — \
        the same misreading appearing multiple times across the \
        text — and suggest corrections.

        The user message contains a digest: chapter titles in \
        brackets, followed by the first ~200 characters of each \
        chapter's body. You are looking for character / place \
        names spelled inconsistently, missing diacritics that \
        should be present given the language, and ligature \
        artifacts (like "rn" misread as "m").

        Return ONE JSON object with EXACTLY this shape:

          {"suggestions":[{"wrong":"...","right":"..."}, ...]}

        Rules:
          * Up to 10 suggestions. Empty list is fine when nothing \
        clearly recurs as an error.
          * "wrong" must be a substring you observed in the \
        digest, verbatim. "right" is your proposed correction, \
        verbatim.
          * Only suggest single-token rewrites (a name, a word) — \
        not whole-sentence rewrites.
          * Skip variants that could be legitimate authorial \
        choice (different speakers, deliberate spellings).
          * Skip the same fix repeated for case variations (just \
        one entry per unique pair).

        Return ONLY the JSON object — no preface, no commentary, \
        no markdown fences.
        """
}
