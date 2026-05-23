import Foundation
import AI
import Document

/// Cloud Phase 9 / P-Sonnet-Structure (bundled-matter pass).
/// Third in the structural-refinement chain after
/// `ClaudeChapterBreakDetector` (finds missed breaks anywhere)
/// and `ClaudeChapterStructureAnalyzer` (validates the list +
/// refines titles / `epub:type`s). This pass takes chapters
/// that the structure pass labelled as front-matter or back-
/// matter and looks for *bundling* — a single "chapter" that
/// actually contains, say, a dedication followed by an epigraph
/// followed by a preface, or a bibliography followed by an
/// index. The OCR pipeline is bad at keeping these apart
/// because they often share styling and run continuously across
/// pages.
///
/// Why a third pass instead of folding into the missed-break
/// detector: the detector reads the entire book and is
/// expensive (~$0.25). This pass reads only the chapters
/// already flagged as front / back-matter — typically 2-6
/// short chapters worth of text. Cost is bounded around
/// $0.05-0.10 per book regardless of book length. Skipping
/// when no candidate chapters exist keeps the floor at $0.
///
/// Cost: depends on how much front/back-matter the book has.
/// A typical academic monograph (preface + introduction +
/// epilogue + bibliography + index = ~5 candidate chapters
/// × ~3K chars each = 15K input tokens) lands around $0.05.
/// Capped per-chapter at 10K chars to keep pathological cases
/// bounded.
///
/// Fail-open: budget exhaustion / refusal / parse failure /
/// zero proposed splits returns the input chapters unchanged.
/// Reuses `ClaudeChapterBreakDetector.Insertion` + `.apply` so
/// the data model and split logic stay shared.
public struct ClaudeFrontBackMatterSplitter: Sendable {
    public let client: AnthropicAPIClient
    public let budget: CloudCallBudget
    public var model: CloudModel
    public var maxOutputTokens: Int
    /// Per-chapter cap for the digest. Keeps a single very long
    /// "appendix" from monopolizing the input budget. 10K chars
    /// ≈ 2500 tokens — enough for Sonnet to recognize bundling
    /// without spending tokens on full prose.
    public var maxCharsPerChapter: Int

    public init(
        client: AnthropicAPIClient,
        budget: CloudCallBudget,
        model: CloudModel = .sonnet4_6,
        maxOutputTokens: Int = 1024,
        maxCharsPerChapter: Int = 10_000
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
        self.maxCharsPerChapter = maxCharsPerChapter
    }

    /// EPUB 3 structural roles that mark a chapter as front-matter
    /// or back-matter — the only chapters this pass scans. Body
    /// chapters (`epubType == "chapter"` or nil) are skipped because
    /// the missed-break detector already covers them and the
    /// bundling pattern this pass exists to catch is rare in body
    /// content.
    public static let candidateEpubTypes: Set<String> = [
        // Front-matter
        "titlepage", "halftitlepage", "copyright-page",
        "dedication", "epigraph", "foreword", "preface",
        "introduction", "prologue", "acknowledgements",
        "contributors", "toc", "abstract",
        // Back-matter
        "epilogue", "conclusion", "afterword",
        "appendix", "bibliography", "glossary",
        "index", "notes", "errata", "colophon",
    ]

    public func analyzeAndApply(chapters: [Chapter]) async -> [Chapter] {
        let candidates = Self.candidateIndices(in: chapters)
        guard !candidates.isEmpty else { return chapters }
        let insertions = await analyze(
            chapters: chapters, candidateIndices: candidates
        )
        guard !insertions.isEmpty else { return chapters }
        return ClaudeChapterBreakDetector.apply(
            insertions: insertions, to: chapters
        )
    }

    /// Run the Sonnet call. Returns the raw insertions (using the
    /// `ClaudeChapterBreakDetector.Insertion` shape, since the
    /// split semantics are identical). Empty on any failure path.
    public func analyze(
        chapters: [Chapter], candidateIndices: [Int]
    ) async -> [ClaudeChapterBreakDetector.Insertion] {
        let digest = buildDigest(
            chapters: chapters, candidateIndices: candidateIndices
        )
        guard digest.count >= 200 else { return [] }
        guard await budget.tryConsume() else { return [] }
        try? Task.checkCancellation()

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
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
        // Reuse the detector's parser — same wire shape, same
        // validation rules (insertion must point at a real,
        // text-bearing block; blockIndex must be > 0).
        return ClaudeChapterBreakDetector.parse(raw, chapters: chapters)
    }

    /// Chapter indices whose `epubType` matches the candidate set.
    /// Indices preserve document order so the digest reads
    /// front → back the way a reader sees the book.
    public static func candidateIndices(in chapters: [Chapter]) -> [Int] {
        chapters.enumerated().compactMap { idx, ch in
            guard let type = ch.epubType?.lowercased(),
                  candidateEpubTypes.contains(type) else { return nil }
            return idx
        }
    }

    /// Build the Sonnet input. Format per candidate chapter:
    ///
    ///   === Chapter 0 — "Front Matter" (epub:type: preface) ===
    ///   [0.0] (h2) Dedication
    ///   [0.1] To my mother...
    ///   [0.2] (h2) Acknowledgements
    ///   [0.3] I thank...
    ///   [0.4] (h2) Preface
    ///   [0.5] When I first set out to write this book...
    ///
    /// Truncates from the middle when a chapter exceeds the
    /// per-chapter cap. Body chapters (not in the candidate set)
    /// are omitted entirely.
    private func buildDigest(
        chapters: [Chapter], candidateIndices: [Int]
    ) -> String {
        var out = ""
        for idx in candidateIndices {
            let chapter = chapters[idx]
            out += renderChapter(
                chapter: chapter, index: idx,
                maxBodyChars: maxCharsPerChapter
            )
        }
        return out
    }

    private func renderChapter(
        chapter: Chapter, index: Int, maxBodyChars: Int
    ) -> String {
        var out = ""
        let title = chapter.title?.nonEmpty ?? "(untitled)"
        let type = chapter.epubType?.nonEmpty ?? "chapter"
        out += "=== Chapter \(index) — \(title) (epub:type: \(type)) ===\n"

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

        let totalChars = entries.reduce(0) { $0 + $1.text.count }
        let visible: [Entry]
        var truncatedCount = 0
        if totalChars <= maxBodyChars {
            visible = entries
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
            let headSet = Set(head.map(\.blockIdx))
            let dedupedTail = tail.filter { !headSet.contains($0.blockIdx) }
            truncatedCount = entries.count - head.count - dedupedTail.count
            visible = head + dedupedTail
        }

        var lastBlockIdx = -1
        var emittedTruncationMarker = false
        for e in visible {
            if !emittedTruncationMarker,
               truncatedCount > 0,
               lastBlockIdx >= 0,
               e.blockIdx > lastBlockIdx + 1 {
                out += "… [truncated, \(truncatedCount) block\(truncatedCount == 1 ? "" : "s") omitted]\n"
                emittedTruncationMarker = true
            }
            // Cap individual paragraph length so a single 5K-char
            // appendix entry can't dominate. 500 chars on each end.
            let textBudget = 1000
            let trimmed = e.text.count > textBudget
                ? String(e.text.prefix(textBudget / 2))
                    + " … "
                    + String(e.text.suffix(textBudget / 2))
                : e.text
            let kindPrefix = e.kind == "p" ? "" : "(\(e.kind)) "
            out += "[\(index).\(e.blockIdx)] \(kindPrefix)\(trimmed)\n"
            lastBlockIdx = e.blockIdx
        }
        out += "\n"
        return out
    }

    // MARK: - prompt

    static let systemPrompt = """
        The user message lists FRONT-MATTER and BACK-MATTER chapters from a book that an OCR \
        pipeline has produced — chapters whose `epub:type` is something like preface, foreword, \
        introduction, acknowledgements, appendix, bibliography, glossary, index, notes, etc.

        These chapters sometimes BUNDLE multiple distinct sections together: a single "chapter" \
        that's actually a Dedication followed by an Epigraph followed by a Preface, or a \
        Bibliography immediately followed by an Index, or several short appendices that should \
        each be their own chapter. The OCR pipeline groups them because they share styling and \
        run continuously across pages.

        Your job is to find the splits inside each bundled chapter. For each split, return:
        - chapterIndex: the chapter in the digest to split
        - blockIndex: where the new chapter STARTS (must be > 0 and point at a text-bearing block)
        - title: a clean canonical title for the new chapter (typically lifted from the heading at \
        that block)
        - epubType: the structural role for the new chapter. One of:
          preface, foreword, introduction, prologue, epilogue, conclusion, afterword,
          dedication, epigraph, acknowledgements, contributors, copyright-page, titlepage,
          halftitlepage, toc, appendix, bibliography, glossary, index, notes, errata, colophon
        - reason: short explanation of why this is a section boundary

        Signals to look for:
        - A new heading partway through a chapter that names a distinct structural role \
        ("Acknowledgements" appearing inside a "Preface", "Index" appearing inside a "Bibliography").
        - Multiple appendices grouped as one ("Appendix A", "Appendix B" inside a single \
        "Appendix" chapter).
        - A back-matter chapter that runs from bibliography → index → notes with no chapter break.

        CONSERVATIVE POSTURE. Only flag splits when the evidence is clear (named heading with \
        recognizable structural-role label, content shift that clearly maps to a different EPUB \
        type). Don't flag generic sub-section breaks within a single section. If you're unsure \
        whether something is a real section or a sub-heading, DON'T flag it.

        Many books need ZERO splits from this pass — front/back-matter that's already been split \
        correctly by the earlier passes shows up here too. Only call out genuine bundling.

        The chapter indices shown in the digest are non-contiguous (we skip body chapters) — \
        always use the index as shown, not a 0-based position within the digest.

        Output ONE JSON object, no preamble or commentary, no markdown code fences. Schema:

        {
          "insertions": [
            {
              "chapterIndex": 3,
              "blockIndex": 12,
              "title": "Acknowledgements",
              "epubType": "acknowledgements",
              "reason": "block 12 opens with an 'Acknowledgements' heading inside what's currently the Preface chapter"
            }
          ]
        }

        If no bundling is found, return `{"insertions": []}`.
        """
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
