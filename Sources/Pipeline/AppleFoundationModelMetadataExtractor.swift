import Foundation
import FoundationModels
import AI
import Document

/// Phase 2 of `L-Foundation-Models`. On-device counterpart to
/// `ClaudeMetadataExtractor` — same role, same input shape, same
/// output type. Reads the first ~4 KB of front-matter prose and
/// emits the canonical 5 publication fields (title, author, year,
/// publisher, ISBN).
///
/// Probably AFM's strongest suit: small input, structured output,
/// lots of overlap between Apple's training corpus and standard
/// publication conventions. Schema-guided generation pins every
/// field to a string, so parsing succeeds without the JSON-fence
/// stripping the Cloud path needs. The text post-processing
/// (`normalizeYear`, `normalizeISBN`) reuses the Cloud impl's
/// helpers verbatim.
public struct AppleFoundationModelMetadataExtractor: BookMetadataExtractor {
    public let client: AppleFoundationModelClient

    public init(client: AppleFoundationModelClient = AppleFoundationModelClient()) {
        self.client = client
    }

    public func extract(
        frontMatterText: String
    ) async -> ClaudeMetadataExtractor.Result? {
        let trimmed = frontMatterText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Same stub-input gate as the Cloud path. AFM is free, but
        // there's no signal to extract from a 50-character input
        // and the output would be misleading.
        guard trimmed.count >= 80 else { return nil }
        try? Task.checkCancellation()
        let response: BookMetadata
        do {
            response = try await client.respond(
                instructions: Self.instructions,
                prompt: trimmed
            )
        } catch {
            return nil
        }
        let result = ClaudeMetadataExtractor.Result(
            title: ClaudeMetadataExtractor.nilIfEmpty(response.title),
            author: ClaudeMetadataExtractor.nilIfEmpty(response.author),
            year: ClaudeMetadataExtractor.normalizeYear(response.year),
            publisher: ClaudeMetadataExtractor.nilIfEmpty(response.publisher),
            isbn: ClaudeMetadataExtractor.normalizeISBN(response.isbn)
        )
        return result.isEmpty ? nil : result
    }

    // MARK: - @Generable schema

    /// Closed shape the on-device model is constrained to emit.
    /// All fields optional — the model returns `nil` for any field
    /// that isn't visible in the front matter rather than guessing.
    @Generable
    struct BookMetadata {
        @Guide(description: "The book's main title only — exclude subtitles and series names unless typographically inseparable. Nil if not visible.")
        var title: String?

        @Guide(description: "Author name(s). Single name, or 'FirstName LastName, OtherName OtherLastName' for multiple authors. Editors and translators excluded. Nil if not visible.")
        var author: String?

        @Guide(description: "Four-digit publication year as a string. Pick the original publication year when both reprint and original are visible. Nil if not visible.")
        var year: String?

        @Guide(description: "Publisher name only — exclude city, imprint, etc. Nil if not visible.")
        var publisher: String?

        @Guide(description: "ISBN-10 or ISBN-13 as printed (hyphens OK; the caller strips them). Nil if not visible.")
        var isbn: String?
    }

    // MARK: - Instructions

    /// Mirrors `ClaudeMetadataExtractor.systemPrompt` so cross-impl
    /// quality comparisons are apples-to-apples. The schema-guided
    /// `@Generable` constraint replaces the "return JSON only"
    /// portion of the Cloud prompt — the framework guarantees the
    /// shape.
    static let instructions = """
        You extract publication metadata from the front matter of a \
        book (title page, copyright page, half-title). The user \
        message contains OCR'd text from the first few pages.

        For each field, return the value verbatim as it appears in \
        the text, or leave it nil if it isn't visible. DO NOT guess. \
        DO NOT synthesize from related fields.

        Conventions:
          * `title`: the main book title only — exclude subtitles \
        and series names unless typographically inseparable.
          * `author`: single name or "FirstName LastName, OtherName \
        OtherLastName" for multiple authors. Editors / translators \
        excluded.
          * `year`: four-digit publication year as a string ("2003"). \
        Pick the original publication year when both reprint and \
        original are visible.
          * `publisher`: publisher name only — exclude city, imprint.
          * `isbn`: ISBN-10 or ISBN-13 as printed (hyphens OK).
        """
}
