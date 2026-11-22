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
/// (`normalizeYear`, `normalizeISBN`, and `nilIfEmpty`'s placeholder
/// filter) reuses the Cloud impl's helpers verbatim.
///
/// The on-device model is small enough to copy formatting examples
/// from its prompt as answers (it once returned the author
/// "FirstName LastName, OtherName OtherLastName" and year "2003" for
/// a page with neither), so the prompt describes formats without
/// sample values, and `grounded(_:in:)` drops any field whose value
/// doesn't appear in the front matter — the instructions already
/// require verbatim values.
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
        let result = Self.grounded(
            ClaudeMetadataExtractor.Result(
                title: ClaudeMetadataExtractor.nilIfEmpty(response.title),
                author: ClaudeMetadataExtractor.nilIfEmpty(response.author),
                year: ClaudeMetadataExtractor.normalizeYear(response.year),
                publisher: ClaudeMetadataExtractor.nilIfEmpty(response.publisher),
                isbn: ClaudeMetadataExtractor.normalizeISBN(response.isbn)
            ),
            in: trimmed
        )
        return result.isEmpty ? nil : result
    }

    // MARK: - Grounding

    /// Keep only the fields whose values are present in `source`.
    /// Text fields match case- and whitespace-insensitively; an author
    /// list matches when every listed name does; the year must appear
    /// as a standalone four-digit number; the ISBN's digits must appear
    /// in the source's digit stream (hyphens and spaces ignored).
    static func grounded(
        _ result: ClaudeMetadataExtractor.Result, in source: String
    ) -> ClaudeMetadataExtractor.Result {
        let haystack = normalizedForMatch(source)
        func present(_ value: String?) -> String? {
            guard let value else { return nil }
            let needle = normalizedForMatch(value)
            return !needle.isEmpty && haystack.contains(needle) ? value : nil
        }
        func authorPresent(_ value: String?) -> String? {
            guard let value else { return nil }
            let names = value
                .replacingOccurrences(of: " and ", with: ",")
                .replacingOccurrences(of: "&", with: ",")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !names.isEmpty,
                  names.allSatisfy({ present($0) != nil }) else { return nil }
            return value
        }
        func yearPresent(_ value: String?) -> String? {
            guard let value else { return nil }
            return source.range(
                of: #"(?<!\d)"# + value + #"(?!\d)"#, options: .regularExpression
            ) != nil ? value : nil
        }
        func isbnPresent(_ value: String?) -> String? {
            guard let value else { return nil }
            let digits = source.uppercased()
                .filter { $0.isNumber || $0 == "X" }
            return digits.contains(value) ? value : nil
        }
        return ClaudeMetadataExtractor.Result(
            title: present(result.title),
            author: authorPresent(result.author),
            year: yearPresent(result.year),
            publisher: present(result.publisher),
            isbn: isbnPresent(result.isbn)
        )
    }

    /// Lowercased, curly quotes straightened, whitespace runs (line
    /// breaks included) collapsed to one space.
    static func normalizedForMatch(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - @Generable schema

    /// Closed shape the on-device model is constrained to emit.
    /// All fields optional — the model returns `nil` for any field
    /// that isn't visible in the front matter rather than guessing.
    @Generable
    struct BookMetadata {
        @Guide(description: "The book's main title only — exclude subtitles and series names unless typographically inseparable. Nil if not visible.")
        var title: String?

        @Guide(description: "Author name(s) exactly as printed in the text, multiple authors separated by commas. Editors and translators excluded. Nil if no author name is printed.")
        var author: String?

        @Guide(description: "Publication year as printed in the text, four digits. Pick the original publication year when both reprint and original are visible. Nil if no year is printed.")
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
        DO NOT synthesize from related fields. Never answer with a \
        stand-in such as "nil", "unknown" or an example value — \
        leave the field empty instead.

        Conventions:
          * `title`: the main book title only — exclude subtitles \
        and series names unless typographically inseparable.
          * `author`: the name or names exactly as printed; separate \
        several authors with commas. Editors / translators excluded.
          * `year`: the four-digit publication year as printed. Pick \
        the original publication year when both reprint and original \
        are visible.
          * `publisher`: publisher name only — exclude city, imprint.
          * `isbn`: ISBN-10 or ISBN-13 as printed (hyphens OK).
        """
}
