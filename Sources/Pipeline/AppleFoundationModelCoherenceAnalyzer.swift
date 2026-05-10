import Foundation
import FoundationModels
import AI
import Document

/// Phase 2 of `L-Foundation-Models`. On-device counterpart to
/// `ClaudeCoherenceAnalyzer` — runs the same digest-of-every-chapter
/// pass and emits a list of guarded global rewrites the caller
/// applies via `applyWithGuardrails`.
///
/// The 8 KB digest fits comfortably inside AFM's context window;
/// the schema-guided output is a small array of `{wrong, right}`
/// pairs. Reuses `ClaudeCoherenceAnalyzer.applyWithGuardrails` and
/// `buildDigest` so the pre/post processing is identical between
/// impls — only the model call itself differs.
public struct AppleFoundationModelCoherenceAnalyzer: BookCoherenceAnalyzer {
    public let client: AppleFoundationModelClient

    public init(client: AppleFoundationModelClient = AppleFoundationModelClient()) {
        self.client = client
    }

    public func analyzeAndApply(chapters: [Chapter]) async -> [Chapter] {
        let suggestions = await analyze(chapters: chapters)
        guard !suggestions.isEmpty else { return chapters }
        return ClaudeCoherenceAnalyzer.applyWithGuardrails(
            suggestions: suggestions, to: chapters
        )
    }

    public func analyze(
        chapters: [Chapter]
    ) async -> [ClaudeCoherenceAnalyzer.Suggestion] {
        let digest = ClaudeCoherenceAnalyzer.buildDigest(chapters: chapters)
        // Same input-floor gate as the Cloud path — no point asking
        // for global rewrites against 50 chars of stub.
        guard digest.count >= 200 else { return [] }
        try? Task.checkCancellation()
        let response: CoherenceSuggestions
        do {
            response = try await client.respond(
                instructions: Self.instructions,
                prompt: digest
            )
        } catch {
            return []
        }
        return response.suggestions.map {
            ClaudeCoherenceAnalyzer.Suggestion(wrong: $0.wrong, right: $0.right)
        }
    }

    // MARK: - @Generable schema

    @Generable
    struct CoherenceSuggestions {
        @Guide(description: "Up to 10 verbatim find/replace pairs that should be applied across the whole book. Empty list when nothing recurs or the input doesn't have OCR errors worth normalizing.")
        var suggestions: [Pair]
    }

    @Generable
    struct Pair {
        @Guide(description: "The exact (wrong) string as it appears in the OCR text — e.g. 'Schafer' for a name that should be 'Schäfer'.")
        var wrong: String

        @Guide(description: "The exact (correct) string to substitute. Must be a meaningful change from `wrong` — same length-or-near and clearly the intended form.")
        var right: String
    }

    // MARK: - Instructions

    static let instructions = """
        You're shown a digest of a book, one chapter at a time \
        (chapter title in brackets, then ~200 chars of body). Find \
        recurring OCR errors that should be normalized across the \
        whole book — character names misread the same way in three \
        places, place names with stripped diacritics, ligature \
        artifacts that survived the typography pass.

        Return up to 10 find/replace pairs. Each `wrong` string \
        should be the verbatim error as it appears in the digest; \
        each `right` string should be the corrected form.

        Conservative posture: prefer false negatives to false \
        positives. If you're not confident the `wrong` form is an \
        OCR error (vs intentional spelling, dialect, archaic form), \
        leave it out. Suggestions that fail length-ratio sanity \
        checks (one form much longer than the other) will be \
        filtered downstream — but it's better to not propose them.

        Empty list is a fine answer when the digest looks clean.
        """
}
