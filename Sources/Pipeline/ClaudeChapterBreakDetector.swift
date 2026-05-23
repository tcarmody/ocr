import Foundation
import AI
import Document

/// Cloud Phase 9 / P-Sonnet-Structure (missed-break pass).
/// Complement to `ClaudeChapterStructureAnalyzer`: that pass
/// validates the local splitter's existing chapter breaks, this
/// one tries to find the breaks the splitter never saw at all.
///
/// Why this matters: the local splitter (heuristic + PDF outline +
/// printed-TOC paths) can only break on signals it can detect —
/// dominant heading levels, TOC entries with matching titles,
/// PDF bookmarks. Books where chapter starts are typographically
/// indistinguishable from body text ("Chapter Three" set in
/// regular type, narrative-style transitions between chapters
/// with no heading at all, inconsistent typography across
/// chapters) slip through unchanged. The validation pass can't
/// help — it only sees candidates that already exist.
///
/// The detector reads the full text of each existing chapter and
/// flags blocks where a new chapter should begin. Insertions are
/// applied left-to-right within a chapter and right-to-left
/// across the chapter list (so earlier indices stay valid).
///
/// Cost: ~80K input + ~500 output ≈ $0.24/book at Sonnet 4.6
/// rates. Caps the per-chapter digest so very long books stay
/// inside the budget — truncates from the middle of each chapter
/// when the aggregate would exceed `maxInputTokens`. Missed
/// breaks inside a truncated region won't be detected; the prompt
/// tells Sonnet so it doesn't try to guess.
///
/// Fail-open: budget exhaustion / refusal / parse failure /
/// zero insertions returns the input chapters unchanged. Order
/// matters: this pass runs BEFORE
/// `ClaudeChapterStructureAnalyzer` so the validator sees the
/// augmented chapter list and can reject any insertion that
/// turned out to look like a section break in retrospect.
public struct ClaudeChapterBreakDetector: Sendable {
    public let client: AnthropicAPIClient
    public let budget: CloudCallBudget
    public var model: CloudModel
    public var maxOutputTokens: Int
    /// Hard cap on the input digest size, measured in approximate
    /// tokens (4 chars/token rule of thumb). Defaults to 80K to
    /// keep per-book input cost under ~$0.25 at Sonnet 4.6 rates.
    public var maxInputTokens: Int

    public init(
        client: AnthropicAPIClient,
        budget: CloudCallBudget,
        model: CloudModel = .sonnet4_6,
        maxOutputTokens: Int = 2048,
        maxInputTokens: Int = 80_000
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
        self.maxInputTokens = maxInputTokens
    }

    /// One proposed chapter break. `chapterIndex` is the chapter in
    /// the input list to split; `blockIndex` is the position inside
    /// `chapters[chapterIndex].blocks` where the new chapter starts
    /// (everything at and after this block moves into the new
    /// chapter). `title` is Sonnet's proposed title; `epubType` is
    /// the EPUB 3 structural role. `reason` is a short human-readable
    /// note for the debug log.
    public struct Insertion: Sendable, Equatable, Hashable {
        public let chapterIndex: Int
        public let blockIndex: Int
        public let title: String?
        public let epubType: String?
        public let reason: String?

        public init(
            chapterIndex: Int, blockIndex: Int,
            title: String? = nil, epubType: String? = nil,
            reason: String? = nil
        ) {
            self.chapterIndex = chapterIndex
            self.blockIndex = blockIndex
            self.title = title
            self.epubType = epubType
            self.reason = reason
        }
    }

    /// Run the pass + apply the insertions. Returns the (possibly
    /// expanded) chapter list. No-op on any failure path.
    public func analyzeAndApply(chapters: [Chapter]) async -> [Chapter] {
        let insertions = await analyze(chapters: chapters)
        guard !insertions.isEmpty else { return chapters }
        return Self.apply(insertions: insertions, to: chapters)
    }

    /// The Sonnet-call half of the pass. Returns raw insertions
    /// without applying them; the caller decides whether / how to
    /// apply. Empty on any failure path.
    public func analyze(chapters: [Chapter]) async -> [Insertion] {
        guard !chapters.isEmpty else { return [] }
        let digest = Self.buildDigest(
            chapters: chapters, maxChars: maxInputTokens * 4
        )
        guard digest.count >= 200 else { return [] }
        guard await budget.tryConsume() else { return [] }
        try? Task.checkCancellation()

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
            // Cache the system prompt — byte-stable across every
            // book in a session so the second-book call onward
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
        return Self.parse(raw, chapters: chapters)
    }

    // MARK: - digest

    /// Build the Sonnet input. Format per chapter:
    ///
    ///   === Chapter 0 — "Introduction" (epub:type: preface) ===
    ///   [0.0] (h2) Introduction
    ///   [0.1] First paragraph of the introduction...
    ///   [0.3] (h3) Background
    ///   [0.4] Some background text...
    ///
    /// Block index `0.3` means chapter 0, block 3 in the chapter's
    /// `blocks` array. Skipped block indices (e.g., [0.2] above)
    /// are non-text blocks — figures, tables, anchors — which we
    /// omit from the digest because they don't help break
    /// detection. Sonnet's output references the same indices.
    ///
    /// The total digest is capped at `maxChars`. When the aggregate
    /// would exceed the cap, each chapter is truncated from the
    /// middle: keep the first half and last half of the chapter's
    /// text, drop the middle, insert a `… [truncated, M blocks omitted]`
    /// marker. The prompt instructs Sonnet to skip flagging
    /// breaks inside truncated regions.
    public static func buildDigest(
        chapters: [Chapter], maxChars: Int = 320_000
    ) -> String {
        // First pass: emit every chapter in full to measure total
        // size. If under the cap, return as-is. Otherwise, compute
        // a per-chapter character budget and re-emit with mid-
        // truncation.
        let full = renderFull(chapters: chapters)
        if full.count <= maxChars { return full }

        // Over budget — distribute the cap proportionally to chapter
        // sizes, then mid-truncate each.
        let totalRaw = chapters.map { rawTextLength($0) }.reduce(0, +)
        guard totalRaw > 0 else { return String(full.prefix(maxChars)) }
        var out = ""
        for (idx, chapter) in chapters.enumerated() {
            let raw = rawTextLength(chapter)
            let chapterBudget = max(1000, Int(
                Double(raw) / Double(totalRaw) * Double(maxChars)
            ))
            out += renderChapter(
                chapter: chapter, index: idx,
                maxBodyChars: chapterBudget
            )
        }
        return String(out.prefix(maxChars))
    }

    /// Total length of text content in a chapter (paragraphs +
    /// headings only). Used to budget per-chapter digest size.
    private static func rawTextLength(_ chapter: Chapter) -> Int {
        var n = 0
        for block in chapter.blocks {
            switch block {
            case .heading(_, let runs), .paragraph(let runs):
                n += runs.reduce(0) { $0 + $1.text.count }
            default:
                continue
            }
        }
        return n
    }

    private static func renderFull(chapters: [Chapter]) -> String {
        var out = ""
        for (idx, chapter) in chapters.enumerated() {
            out += renderChapter(
                chapter: chapter, index: idx,
                maxBodyChars: .max
            )
        }
        return out
    }

    private static func renderChapter(
        chapter: Chapter, index: Int, maxBodyChars: Int
    ) -> String {
        var out = ""
        let title = chapter.title?.nonEmpty ?? "(untitled)"
        let type = chapter.epubType?.nonEmpty ?? "chapter"
        out += "=== Chapter \(index) — \(title) (epub:type: \(type)) ===\n"

        // First pass: collect text-bearing blocks with their index.
        struct Entry { let blockIdx: Int; let kind: String; let text: String }
        var entries: [Entry] = []
        for (blockIdx, block) in chapter.blocks.enumerated() {
            switch block {
            case .heading(let level, let runs):
                let text = runs.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                entries.append(Entry(
                    blockIdx: blockIdx, kind: "h\(level)", text: text
                ))
            case .paragraph(let runs):
                let text = runs.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                entries.append(Entry(
                    blockIdx: blockIdx, kind: "p", text: text
                ))
            default:
                continue
            }
        }

        // Apply per-chapter budget. When the entries' text length
        // exceeds the budget, keep half from the front and half
        // from the back; insert a truncation marker between.
        let totalChars = entries.reduce(0) { $0 + $1.text.count }
        let visibleEntries: [Entry]
        var truncatedCount: Int = 0
        if totalChars <= maxBodyChars {
            visibleEntries = entries
        } else {
            let half = maxBodyChars / 2
            var head: [Entry] = []
            var headChars = 0
            for e in entries {
                if headChars + e.text.count > half { break }
                head.append(e)
                headChars += e.text.count
            }
            var tail: [Entry] = []
            var tailChars = 0
            for e in entries.reversed() {
                if tailChars + e.text.count > half { break }
                tail.append(e)
                tailChars += e.text.count
            }
            tail.reverse()
            // Avoid overlap when head + tail spans more than entries.
            let headSet = Set(head.map(\.blockIdx))
            let dedupedTail = tail.filter { !headSet.contains($0.blockIdx) }
            truncatedCount = entries.count - head.count - dedupedTail.count
            visibleEntries = head + dedupedTail
        }

        var lastEmittedBlockIdx: Int = -1
        var sawTruncation = false
        for e in visibleEntries {
            // Insert truncation marker once when we jump over a
            // non-contiguous block index.
            if !sawTruncation,
               truncatedCount > 0,
               lastEmittedBlockIdx >= 0,
               e.blockIdx > lastEmittedBlockIdx + 1 {
                out += "… [truncated, \(truncatedCount) block\(truncatedCount == 1 ? "" : "s") omitted]\n"
                sawTruncation = true
            }
            let kindPrefix = e.kind == "p" ? "" : "(\(e.kind)) "
            // Cap individual paragraph length too — a single 10K-char
            // paragraph would dominate. 600 chars keeps the
            // distinguishing detail (opening + closing) without
            // letting one block monopolize the chapter budget.
            let textBudget = 600
            let trimmed = e.text.count > textBudget
                ? String(e.text.prefix(textBudget / 2))
                    + " … "
                    + String(e.text.suffix(textBudget / 2))
                : e.text
            out += "[\(index).\(e.blockIdx)] \(kindPrefix)\(trimmed)\n"
            lastEmittedBlockIdx = e.blockIdx
        }
        out += "\n"
        return out
    }

    // MARK: - parse

    /// Decode Sonnet's response. Expected wire shape:
    ///   ```
    ///   {"insertions":[
    ///     {"chapterIndex":0,"blockIndex":42,"title":"Chapter Three",
    ///      "epubType":"chapter","reason":"new chapter begins here"}
    ///   ]}
    ///   ```
    /// Drops insertions that point at non-existent chapters or
    /// block indices that aren't text-bearing (so a model
    /// hallucinating into a figure/anchor row doesn't corrupt the
    /// chapter list). Drops `blockIndex == 0` insertions — splitting
    /// at the start of a chapter is a no-op.
    public static func parse(
        _ raw: String, chapters: [Chapter]
    ) -> [Insertion] {
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
        return wire.insertions.compactMap { d -> Insertion? in
            guard d.chapterIndex >= 0,
                  d.chapterIndex < chapters.count else { return nil }
            let chapter = chapters[d.chapterIndex]
            guard d.blockIndex > 0,
                  d.blockIndex < chapter.blocks.count else { return nil }
            // Must point at a text-bearing block.
            switch chapter.blocks[d.blockIndex] {
            case .heading, .paragraph:
                break
            default:
                return nil
            }
            return Insertion(
                chapterIndex: d.chapterIndex,
                blockIndex: d.blockIndex,
                title: d.title?.nonEmpty,
                epubType: d.epubType?.nonEmpty,
                reason: d.reason?.nonEmpty
            )
        }
    }

    private struct Wire: Decodable {
        struct W: Decodable {
            let chapterIndex: Int
            let blockIndex: Int
            let title: String?
            let epubType: String?
            let reason: String?
        }
        let insertions: [W]
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

    /// Apply the insertions to the chapter list. Strategy:
    ///   * Group insertions by chapter index.
    ///   * For each chapter, sort its insertions by `blockIndex`
    ///     descending — split the LAST one first so earlier block
    ///     indices in the same chapter stay valid.
    ///   * Each split: detach blocks from `blockIndex` onward into
    ///     a new chapter; that chapter's title / `epub:type` come
    ///     from the insertion. The detached blocks' footnotes
    ///     (those referenced by the moved blocks' inline `<a
    ///     epub:type="noteref">` markers) move with them — we
    ///     can't tell which footnotes belong to which block at
    ///     this layer, so for safety we leave footnotes on the
    ///     ORIGINAL chapter. The footnote linker will re-resolve
    ///     downstream.
    ///   * Across chapters: process in reverse order so earlier
    ///     chapter indices stay valid.
    public static func apply(
        insertions: [Insertion], to chapters: [Chapter]
    ) -> [Chapter] {
        guard !insertions.isEmpty else { return chapters }

        // Group by chapter; sort each group by blockIndex desc.
        var byChapter: [Int: [Insertion]] = [:]
        for ins in insertions {
            byChapter[ins.chapterIndex, default: []].append(ins)
        }
        for key in byChapter.keys {
            byChapter[key]?.sort { $0.blockIndex > $1.blockIndex }
        }

        // Process chapters right-to-left so an insertion at chapter
        // 2 doesn't shift the indices of insertions at chapter 0.
        var result = chapters
        for chapterIdx in byChapter.keys.sorted(by: >) {
            guard let groupInsertions = byChapter[chapterIdx],
                  chapterIdx < result.count else { continue }
            var current = result[chapterIdx]
            // For this chapter, splits land in descending blockIdx
            // order. Each split takes the tail of `current.blocks`
            // and creates a new chapter that gets inserted AFTER
            // `current` in `result`.
            var spawned: [Chapter] = []
            for ins in groupInsertions {
                guard ins.blockIndex < current.blocks.count else { continue }
                let tail = Array(current.blocks[ins.blockIndex...])
                current.blocks = Array(current.blocks[..<ins.blockIndex])
                let newChapter = Chapter(
                    title: ins.title,
                    blocks: tail,
                    footnotes: [],
                    epubType: ins.epubType
                )
                spawned.append(newChapter)
            }
            // `spawned` is in descending-split-order — i.e. the
            // most recently detached tail is FIRST in the list,
            // but the original document order has it LAST. Reverse
            // so spawned reads in document order.
            spawned.reverse()
            result[chapterIdx] = current
            result.insert(contentsOf: spawned, at: chapterIdx + 1)
        }
        return result
    }

    // MARK: - prompt

    static let systemPrompt = """
        You are reviewing a book whose local OCR pipeline has split it into chapters using heuristics. \
        Some chapter breaks are MISSING — places where a new chapter should begin but the heuristics \
        didn't see a signal. Your job is to find those missed breaks.

        The user message lists every existing chapter. Each chapter shows its current title, EPUB \
        structural type, and its text blocks. Each block is prefixed with a marker like `[0.42]` — \
        chapter index 0, block index 42. Skipped block numbers are non-text content (figures, tables, \
        page anchors) and are not addressable for inserting breaks. Some long chapters are truncated \
        from the middle; you'll see a `… [truncated, N blocks omitted]` marker. Don't flag breaks \
        inside truncated regions.

        For each missed break you identify, return:
        - chapterIndex: the chapter to split (from the digest)
        - blockIndex: the block where the new chapter STARTS (everything at and after this block \
        moves into the new chapter; the block index must be > 0 and refer to a text-bearing block)
        - title: a clean canonical title for the new chapter
        - epubType: one of these EPUB 3 structural roles:
          chapter, preface, foreword, introduction, prologue, epilogue, conclusion, afterword,
          dedication, acknowledgements, contributors, copyright-page, titlepage, halftitlepage,
          toc, appendix, bibliography, glossary, index, notes, errata, abstract, part
        - reason: short explanation of why this is a chapter break

        Signals to look for:
        - A block whose text reads like a chapter opening that wasn't promoted to a heading: "Chapter \
        Three" or "III" in regular type, or an unmarked title-cased line followed by narrative.
        - A clear topic / narrative shift: end of one chapter's argument followed by a new opening \
        with no transition.
        - Front-matter → body transition: bundled "Preface + Foreword + Chapter 1" appearing as a \
        single chapter, where the preface or foreword should be its own chapter.
        - Body → back-matter transition: appendices, bibliographies, indices, glossaries, "Notes" \
        sections bundled into the previous body chapter.

        CONSERVATIVE POSTURE. False inserts are worse than false misses. The local heuristics have \
        already done the easy cases; you're catching genuine gaps. If you're unsure whether something \
        is a chapter break or a within-chapter section header, DON'T flag it — the next pass (chapter \
        structure validation) is more permissive about validating existing breaks than about inserting \
        new ones. Mid-chapter section headers ("3.1 Methodology", "An Aside", "Lemma 2.4") are NOT \
        chapter breaks.

        Most books need ZERO insertions from this pass. Some need 1-3 (typically front-matter splits \
        or back-matter splits). Books needing >10 are extremely rare and likely indicate that the \
        local splitter failed badly enough that you should still be conservative — flag only the most \
        obvious cases.

        Output ONE JSON object, no preamble or commentary, no markdown code fences. Schema:

        {
          "insertions": [
            {
              "chapterIndex": 0,
              "blockIndex": 42,
              "title": "Chapter Three: Methodology",
              "epubType": "chapter",
              "reason": "block 42 opens with 'Three' in title-case followed by what reads as a new chapter; the local splitter missed it because the title was set in regular type rather than as a heading."
            }
          ]
        }

        If no missed breaks are found, return `{"insertions": []}`.
        """
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
