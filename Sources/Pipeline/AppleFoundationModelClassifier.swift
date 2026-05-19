import Foundation
import FoundationModels
import AI
import Document

/// Phase 1 of `L-Foundation-Models`. On-device chapter classifier
/// using Apple's `FoundationModels` framework — same role as
/// `ClaudeChapterClassifier` but free, offline, and available under
/// `processingMode == .privateLocal` when Apple Intelligence is
/// enabled on the device.
///
/// Schema-guided generation pins the model's output to a closed
/// `EpubChapterLabel` enum (the `@Generable` macro emits the JSON-
/// schema constraint), so the result parses straight into a
/// `SemanticChapterLabel.rawValue` string without the post-hoc
/// normalization the Cloud path needs. If the framework throws
/// (model unavailable mid-run, generation timeout) we return nil —
/// the caller emits the chapter without an `epub:type`, matching
/// the Cloud path's "no-guess" posture.
public struct AppleFoundationModelClassifier: SemanticChapterClassifier {
    public let client: AppleFoundationModelClient

    public init(client: AppleFoundationModelClient = AppleFoundationModelClient()) {
        self.client = client
    }

    public func classify(chapter: Chapter) async -> String? {
        try? Task.checkCancellation()
        let context = Self.makeContext(from: chapter)
        do {
            let response: ChapterClassification = try await client.respond(
                instructions: Self.instructions,
                prompt: context
            )
            // Defensive cast back to the canonical SemanticChapterLabel
            // raw values — the @Generable enum's cases mirror the
            // canonical set 1:1, but going through the protocol's
            // String contract (rather than exposing the AFM enum to
            // the caller) keeps the two impls truly substitutable.
            return response.label.rawValue
        } catch {
            return nil
        }
    }

    // MARK: - @Generable schema

    /// Schema-guided wrapper. The model is constrained to emit one
    /// of `EpubChapterLabel`'s cases, so parsing succeeds against
    /// the canonical label set without a normalize step.
    @Generable
    struct ChapterClassification {
        @Guide(description: "EPUB 3 structural-semantics token that best describes this chapter. Pick `chapter` for ordinary numbered or titled body chapters; pick a more specific label only when the title or opening text clearly identifies the section as that kind.")
        var label: EpubChapterLabel
    }

    /// Closed label set. Cases mirror `SemanticChapterLabel` 1:1 by
    /// raw value, so the protocol's `String?` return type carries
    /// the same tokens the Cloud path produces. Don't reorder
    /// without checking — the order isn't load-bearing today, but
    /// any future schema-cache might key on it.
    @Generable
    enum EpubChapterLabel: String {
        case frontmatter
        case preface
        case foreword
        case introduction
        case acknowledgments
        case dedication
        case prologue
        case chapter
        case conclusion
        case epilogue
        case afterword
        case appendix
        case bibliography
        case glossary
        case index
        case notes
    }

    // MARK: - Prompt construction

    /// Per-chapter input: title (when present) + opening prose.
    /// Mirrors `ClaudeChapterClassifier.makeContext` so cross-impl
    /// quality comparisons are apples-to-apples.
    static func makeContext(from chapter: Chapter) -> String {
        let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let opening = openingText(of: chapter, maxChars: 200)
        return """
            Title: \(title.isEmpty ? "(none)" : title)

            Opening text (first ~200 chars):
            \(opening.isEmpty ? "(none)" : opening)
            """
    }

    /// Pull plain text from the chapter's leading paragraphs +
    /// headings until we hit `maxChars`. Skip figures / tables /
    /// anchors — they carry no signal for "what kind of section
    /// is this." Same posture as the Cloud path.
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
                // Verse contributes to the chapter signal too —
                // a poetry-heavy chapter shouldn't classify as
                // bibliography or front-matter just because the
                // prose content is sparse. Join lines with spaces
                // for the bag-of-words classifier input.
                let text = lines.flatMap(\.runs).map(\.text).joined(separator: " ")
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

    /// Instructions handed to `LanguageModelSession.init`. Stable —
    /// don't substitute label names from `SemanticChapterLabel`
    /// dynamically; keeping the string byte-stable lets the
    /// framework's session caching kick in across the per-chapter
    /// calls in one book.
    static let instructions = """
        You classify book chapters using the EPUB 3 Structural \
        Semantics Vocabulary. Read the chapter's title and opening \
        text and pick exactly one structural label. Pick `chapter` \
        for ordinary numbered or titled body chapters. Pick more \
        specific labels (preface, appendix, bibliography, etc.) \
        when the title or opening clearly identifies the section \
        as that kind.
        """
}
