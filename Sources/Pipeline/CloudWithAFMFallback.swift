import Foundation
import CoreGraphics
import Document

/// Per-protocol decorators that try a Cloud-mode primary engine and
/// fall back to an Apple Foundation Models impl when the primary
/// returns its protocol's "failure" signal (nil / empty / unchanged).
/// Used by the four one-shot text-only Cloud features that have AFM
/// siblings: post-OCR cleanup, semantic chapter classification, book
/// metadata extraction, document coherence pass.
///
/// **Failure detection** is conservative — each protocol already
/// returns nil / empty / unchanged when its impl declines (refused,
/// rate-limited, budget exhausted, network error, model unavailable),
/// so the decorator only needs to check for that single signal to
/// decide whether to retry against AFM. Limitation: the same "no
/// change" outcome can also mean "Cloud succeeded but had nothing
/// to fix" — those cases redundantly invoke AFM, but AFM is free /
/// on-device, so the cost is microseconds of work and the second
/// model occasionally catches what the first missed.
///
/// **Why not refactor the protocols to `throws`** so we could
/// distinguish transient errors from intentional skip cases: would
/// touch all four protocols + their 8 implementations + every
/// caller. Not worth it when the redundant-AFM cost is "an extra
/// on-device call that returns nothing." Revisit if Cloud-rate-
/// limited runs become common enough to bottleneck.
///
/// Constructed at conversion start by `PipelineEngineFactories`
/// when BOTH the Cloud engine and AFM are available; when only one
/// is available, the factories skip wrapping and return that impl
/// directly.

// MARK: - PostOCRProcessor

/// Try Cloud post-OCR cleanup first; on nil (Cloud declined / failed),
/// retry against AFM. Returns the first non-nil result.
struct FallbackPostOCRProcessor: PostOCRProcessor {
    let primary: any PostOCRProcessor
    let fallback: any PostOCRProcessor

    func correct(
        text: String,
        languages: [BCP47],
        mode: ClaudePostProcessor.Mode,
        regionImage: CGImage?
    ) async -> ClaudePostProcessor.Result? {
        if let result = await primary.correct(
            text: text, languages: languages,
            mode: mode, regionImage: regionImage
        ) {
            return result
        }
        // AFM is text-only; vision-mode requests it doesn't honor
        // return nil and we stop falling back. Same posture as the
        // caller would already see when Cloud succeeded with nil.
        return await fallback.correct(
            text: text, languages: languages,
            mode: mode, regionImage: regionImage
        )
    }
}

// MARK: - SemanticChapterClassifier

/// Try Cloud chapter classification first; on nil (refused /
/// unknown label / budget exhausted), retry against AFM.
struct FallbackSemanticChapterClassifier: SemanticChapterClassifier {
    let primary: any SemanticChapterClassifier
    let fallback: any SemanticChapterClassifier

    func classify(chapter: Chapter) async -> String? {
        if let label = await primary.classify(chapter: chapter) {
            return label
        }
        return await fallback.classify(chapter: chapter)
    }
}

// MARK: - BookMetadataExtractor

/// Try Cloud metadata extraction first; on nil (Cloud failed / no
/// usable metadata), retry against AFM.
struct FallbackBookMetadataExtractor: BookMetadataExtractor {
    let primary: any BookMetadataExtractor
    let fallback: any BookMetadataExtractor

    func extract(
        frontMatterText: String
    ) async -> ClaudeMetadataExtractor.Result? {
        if let result = await primary.extract(
            frontMatterText: frontMatterText
        ) {
            return result
        }
        return await fallback.extract(
            frontMatterText: frontMatterText
        )
    }
}

// MARK: - BookCoherenceAnalyzer

/// Try Cloud coherence pass first; on empty suggestions (which
/// Cloud returns when it declines / fails OR when the book is
/// genuinely clean), retry against AFM. The redundant-on-success
/// case is harmless — AFM runs on-device for free.
///
/// `analyzeAndApply` delegates to primary's full pass; if the
/// returned chapters are byte-identical to the input (no changes
/// applied), fall back. `Chapter: Equatable` makes the check
/// cheap relative to the AI calls bracketing it.
struct FallbackBookCoherenceAnalyzer: BookCoherenceAnalyzer {
    let primary: any BookCoherenceAnalyzer
    let fallback: any BookCoherenceAnalyzer

    func analyze(
        chapters: [Chapter]
    ) async -> [ClaudeCoherenceAnalyzer.Suggestion] {
        let primary = await primary.analyze(chapters: chapters)
        if !primary.isEmpty { return primary }
        return await fallback.analyze(chapters: chapters)
    }

    func analyzeAndApply(chapters: [Chapter]) async -> [Chapter] {
        let result = await primary.analyzeAndApply(chapters: chapters)
        if result != chapters { return result }
        return await fallback.analyzeAndApply(chapters: chapters)
    }
}
