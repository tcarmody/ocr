import Foundation
import Document

/// Common interface for engines that extract publication metadata
/// (title, author, year, publisher, ISBN) from a book's front
/// matter. Both `ClaudeMetadataExtractor` (Cloud, Haiku 4.5) and
/// `AppleFoundationModelMetadataExtractor` (Phase 2 of
/// `L-Foundation-Models`) conform. Pipeline picks one at runtime
/// based on processing mode + per-feature toggles + availability.
///
/// Returning `nil` means "no usable metadata" — the caller falls
/// back to whatever upstream values exist (user-provided title,
/// filename derivation). Same posture as the chapter classifier:
/// absence is preferable to a guess.
public protocol BookMetadataExtractor: Sendable {
    /// Extract publication metadata from `frontMatterText` (the
    /// first ~5 pages of OCR'd body). Returns nil on:
    ///  * stub input (too short to extract anything reliable);
    ///  * runtime budget exhausted (Cloud path);
    ///  * model unavailable / parse failure;
    ///  * an empty result (every field nil).
    func extract(
        frontMatterText: String
    ) async -> ClaudeMetadataExtractor.Result?
}

extension ClaudeMetadataExtractor: BookMetadataExtractor {}
