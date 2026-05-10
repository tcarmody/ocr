import Foundation
import Document

/// Common interface for engines that scan a book's chapter digest
/// for recurring OCR errors and apply guarded global rewrites.
/// Both `ClaudeCoherenceAnalyzer` (Cloud, Haiku 4.5) and
/// `AppleFoundationModelCoherenceAnalyzer` (Phase 2 of
/// `L-Foundation-Models`) conform.
///
/// `analyze` produces raw suggestions (no guardrails); the caller
/// runs them through `ClaudeCoherenceAnalyzer.applyWithGuardrails`
/// to filter hallucinations and confirm document occurrence
/// thresholds before applying. `analyzeAndApply` is the convenience
/// that does both.
public protocol BookCoherenceAnalyzer: Sendable {
    /// One-shot run: analyze + filter + apply suggestions to the
    /// chapters. Returns the input chapters unchanged when the
    /// analyzer declines, the digest is too small, or no suggestions
    /// survive the guardrails.
    func analyzeAndApply(chapters: [Chapter]) async -> [Chapter]

    /// Raw analysis pass. Returns guardrail-unfiltered suggestions
    /// — used by callers that want to log / present suggestions
    /// before applying.
    func analyze(chapters: [Chapter]) async -> [ClaudeCoherenceAnalyzer.Suggestion]
}

extension ClaudeCoherenceAnalyzer: BookCoherenceAnalyzer {}
