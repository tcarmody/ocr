import Foundation
import AI
import Document

/// Cloud Phase 6d. For each chapter in the assembled book, asks
/// Haiku one short question: which EPUB 3 Structural Semantics
/// Vocabulary token best describes this section? The answer
/// becomes the chapter's `epub:type`, surfaced in `<body>` and on
/// the chapter's nav.xhtml entry so readers can navigate the book
/// semantically (skip front matter, jump to bibliography, etc.).
///
/// One Haiku call per chapter. A typical 15-chapter book costs ~$0.01
/// — semantic-classification's "tiny prompt + closed label set"
/// shape is pretty much the cheapest Cloud feature in the system.
///
/// The label set below is a curated subset of the EPUB 3 Structural
/// Semantics Vocabulary, biased toward what's useful in academic
/// books (Humanist's primary use case). Haiku is allowed to return
/// any of these labels; anything else is treated as "unknown" and
/// the chapter goes unlabeled.
public struct ClaudeChapterClassifier: Sendable {
    public let client: AnthropicAPIClient
    public let budget: ClaudeCallBudget
    public var model: AnthropicModel
    public var maxOutputTokens: Int

    public init(
        client: AnthropicAPIClient,
        budget: ClaudeCallBudget,
        model: AnthropicModel = .haiku4_5,
        maxOutputTokens: Int = 32  // ample for a single label string
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    /// Closed label set — Haiku is constrained to one of these. Order
    /// is roughly book-flow (front matter → body → back matter) for
    /// clarity in the prompt and tests.
    public static let supportedLabels: [String] = [
        "frontmatter",
        "preface",
        "foreword",
        "introduction",
        "acknowledgments",
        "dedication",
        "prologue",
        "chapter",
        "conclusion",
        "epilogue",
        "afterword",
        "appendix",
        "bibliography",
        "glossary",
        "index",
        "notes",
    ]

    /// Classify one chapter. Returns the validated label or nil if
    /// Haiku refused, the response didn't parse to a known label,
    /// or the budget was exhausted. Caller falls back to no label
    /// on nil — `chapter` is the safe default but we'd rather emit
    /// nothing than guess.
    public func classify(chapter: Chapter) async -> String? {
        guard await budget.tryConsume() else { return nil }
        try? Task.checkCancellation()

        let context = Self.makeContext(from: chapter)
        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
            // Cache the system prompt — fired once per chapter, so
            // a 15-chapter book hits the cache 14 times. 1h TTL
            // fits the typical few-minute conversion run plus
            // cross-book reuse in a session.
            system: .cached(Self.systemPrompt, ttl: .oneHour),
            messages: [
                Message(role: .user, content: .plain(context)),
            ],
            thinking: .disabled
        )

        let response: AnthropicMessageResponse
        do {
            response = try await client.send(request)
        } catch {
            return nil
        }
        await budget.recordUsage(response.usage, for: model)

        if response.didRefuse { return nil }
        guard let raw = response.primaryText else { return nil }
        return Self.normalize(raw)
    }

    /// Build the per-chapter prompt. Title (when present) carries
    /// most of the signal; first ~200 chars of body text covers
    /// the case where the title is generic ("Chapter 3") but the
    /// content is identifiable (an opening footnote convention or a
    /// classic appendix-style table).
    static func makeContext(from chapter: Chapter) -> String {
        let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let opening = Self.openingText(of: chapter, maxChars: 200)
        return """
            Title: \(title.isEmpty ? "(none)" : title)

            Opening text (first ~200 chars):
            \(opening.isEmpty ? "(none)" : opening)
            """
    }

    /// Walk the chapter's blocks and pull plain text out of headings
    /// and paragraphs until we hit `maxChars`. Skip figures /
    /// tables / anchors — they don't help the model identify the
    /// section's role.
    static func openingText(of chapter: Chapter, maxChars: Int) -> String {
        var collected = ""
        for block in chapter.blocks {
            switch block {
            case .heading(_, let runs), .paragraph(let runs):
                let text = runs.map(\.text).joined()
                if !collected.isEmpty { collected += " " }
                collected += text
                if collected.count >= maxChars {
                    return String(collected.prefix(maxChars))
                }
            case .verse(let lines):
                let text = lines.flatMap(\.runs).map(\.text)
                    .joined(separator: " ")
                if !collected.isEmpty { collected += " " }
                collected += text
                if collected.count >= maxChars {
                    return String(collected.prefix(maxChars))
                }
            case .anchor, .figure, .table:
                continue
            }
        }
        return collected
    }

    /// Normalize and validate the model's response: trim, lowercase,
    /// strip surrounding punctuation, then check against the closed
    /// label set. Returns nil for unknown labels — better to emit
    /// nothing than guess.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'`"))
            .lowercased()
        // Sometimes the model says "chapter." or just "chapter".
        // Both should pass through normalization to "chapter".
        guard supportedLabels.contains(trimmed) else { return nil }
        return trimmed
    }

    /// Stable system prompt — keep byte-stable so the prefix is
    /// cacheable across the per-chapter calls in a book. The label
    /// list is hardcoded into the prompt rather than built from
    /// `supportedLabels` at call time so the rendered string stays
    /// identical (any reordering of supportedLabels in code would
    /// invalidate cache otherwise).
    static let systemPrompt = """
        You classify book chapters using the EPUB 3 Structural \
        Semantics Vocabulary. Read the chapter's title and opening \
        text and respond with EXACTLY ONE label from this list:

          frontmatter, preface, foreword, introduction, \
        acknowledgments, dedication, prologue, chapter, \
        conclusion, epilogue, afterword, appendix, \
        bibliography, glossary, index, notes

        Pick `chapter` for ordinary numbered or titled body \
        chapters. Pick more specific labels (preface, appendix, \
        bibliography, etc.) when the title or opening clearly \
        identifies the section as that kind. Return the label as a \
        single lowercase word — no quotes, no punctuation, no \
        explanation.
        """
}
