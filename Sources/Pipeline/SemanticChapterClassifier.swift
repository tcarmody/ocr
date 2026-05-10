import Foundation
import Document

/// Common interface for chapter-classification engines. Both the
/// Cloud-mode `ClaudeChapterClassifier` and the on-device
/// `AppleFoundationModelClassifier` (Phase 1 of `L-Foundation-Models`)
/// conform. The pipeline picks one at runtime based on processing
/// mode, Settings toggles, and runtime availability.
///
/// Returning `nil` is the explicit "no label" outcome — the caller
/// emits the chapter without an `epub:type`. We prefer absence over
/// guessing, since a wrong label changes how readers display the
/// chapter (skipping front matter, jumping to bibliography, etc.).
public protocol SemanticChapterClassifier: Sendable {
    /// Classify one chapter. Returns the validated EPUB 3
    /// structural-semantics label (`chapter`, `preface`,
    /// `bibliography`, ...) or nil when:
    ///  * the engine refused / returned an unknown label;
    ///  * a runtime budget was exhausted (Claude path);
    ///  * the underlying model isn't available (AFM path).
    func classify(chapter: Chapter) async -> String?
}

/// Closed label set both classifier impls converge on. The Cloud
/// path's `ClaudeChapterClassifier.systemPrompt` hardcodes this list
/// (so the cached prompt stays byte-stable); the AFM path uses the
/// same set as the cases of a `@Generable` enum that constrains the
/// on-device model to one of these tokens. Order is roughly book-
/// flow (front matter → body → back matter) for clarity.
public enum SemanticChapterLabel: String, CaseIterable, Sendable {
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

extension ClaudeChapterClassifier: SemanticChapterClassifier {}
