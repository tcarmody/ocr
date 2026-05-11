import Foundation
import FoundationModels
import AI

/// R-Auto-Collections Phase 2 / L-Foundation-Models Phase 4.
/// On-device genre classifier — same shape as the existing
/// `AppleFoundationModelClassifier` (chapter-level epub:type) and
/// `AppleFoundationModelMetadataExtractor` (front-matter
/// extraction). Schema-guided generation pins the model's output
/// to a closed `LibraryGenreLabel` enum so parsing maps directly
/// to a `BookGenre` case without normalization.
///
/// Input: title + author + first ~600 chars of opening text from
/// the book's first spine resource. The taxonomy covers both
/// humanities + technical / scientific material; the model picks
/// one of ~32 leaf genres. Returns nil when the model declines
/// or the framework errors — collections treat that as
/// "uncategorized" (no auto-collection row produced).
public struct BookGenreClassifier: Sendable {
    public let client: AppleFoundationModelClient

    public init(client: AppleFoundationModelClient = AppleFoundationModelClient()) {
        self.client = client
    }

    /// Classify one book. `title` and `author` come from the OPF
    /// metadata (auto-populated by AFM metadata extraction in the
    /// import path); `openingText` is the first few hundred
    /// stripped characters of the first spine resource. All three
    /// are optional — the model handles partial input but classify
    /// quality is best with all three.
    public func classify(
        title: String?,
        author: String?,
        openingText: String
    ) async -> BookGenre? {
        try? Task.checkCancellation()
        let context = Self.makeContext(
            title: title, author: author, openingText: openingText
        )
        do {
            let response: GenreClassification = try await client.respond(
                instructions: Self.instructions,
                prompt: context
            )
            guard let genre = BookGenre(rawValue: response.label.rawValue),
                  genre != .uncategorized
            else { return nil }
            return genre
        } catch {
            return nil
        }
    }

    // MARK: - @Generable schema

    @Generable
    struct GenreClassification {
        @Guide(description: "The closest-matching genre for this book. Pick the most specific sub-genre when one fits (e.g. fictionFantasy over fictionGeneral; sciencePhysics over scienceGeneral). Pick the *General catch-all when the book fits the family but no specific sub-genre applies. Pick uncategorized only when the book genuinely doesn't fit any case — never guess between two unrelated genres.")
        var label: LibraryGenreLabel
    }

    /// Closed label set mirroring `BookGenre` 1:1 by raw value.
    /// Order matters for prompt-cache stability — don't reorder
    /// without considering the schema cache implications.
    @Generable
    enum LibraryGenreLabel: String {
        // Poetry / Drama
        case poetry, drama
        // Fiction
        case fictionLiterary, fictionFantasy, fictionScienceFiction
        case fictionMystery, fictionRomance, fictionHistorical
        case fictionGeneral
        // Mathematics / Science
        case mathematics
        case sciencePhysics, scienceChemistry, scienceLifeSciences
        case scienceEarthAstro, scienceGeneral
        // Technology
        case technologyComputing, technologyEngineering, technologyGeneral
        // Humanities
        case philosophy, religion, history
        case biographyMemoir, linguistics, arts
        // Social Sciences
        case socialScienceEconomics, socialSciencePolitics
        case socialSciencePsychology, socialScienceGeneral
        // Practical
        case reference, education, howTo, travel, children
        // Fallback
        case uncategorized
    }

    // MARK: - Prompt construction

    private static func makeContext(
        title: String?, author: String?, openingText: String
    ) -> String {
        let titleLine = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : "Title: \($0)"
        } ?? "Title: (none)"
        let authorLine = (author?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : "Author: \($0)"
        } ?? "Author: (none)"
        let openingTrimmed = openingText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let openingLine = openingTrimmed.isEmpty
            ? "Opening text: (none)"
            : "Opening text (first chars):\n\(String(openingTrimmed.prefix(600)))"
        return """
            \(titleLine)
            \(authorLine)

            \(openingLine)
            """
    }

    /// Stable instructions string. Names every genre with a short
    /// disambiguation cue so the model has explicit guidance for
    /// the harder calls (Fiction vs Biography on Bildungsroman;
    /// Science vs Technology on engineering material; etc.).
    static let instructions = """
        You classify books into a closed library taxonomy by genre. Output one label from the closed set.

        Coverage spans both humanities + technical material:
          * Poetry, drama — literary forms.
          * Fiction sub-genres: Literary, Fantasy, Science Fiction, Mystery, Romance, Historical, General (anything that's clearly fiction but doesn't fit a specific sub-genre).
          * Mathematics — algebra, calculus, geometry, statistics, number theory, etc.
          * Science sub-genres: Physics, Chemistry, Life Sciences (biology, medicine, ecology), Earth & Astronomy (geology, oceanography, astronomy), General (popular / multi-disciplinary science).
          * Technology sub-genres: Computing (programming, software, CS, AI), Engineering (mechanical, electrical, civil), General (broader tech / industry / how-things-work).
          * Philosophy, Religion, History, Biography & Memoir, Linguistics, Arts (art history / criticism / music / performing arts).
          * Social Science sub-genres: Economics, Politics, Psychology, General (sociology, anthropology, etc.).
          * Reference (dictionaries, encyclopedias, manuals), Education (textbooks, study guides), How-to (cookbooks, hobby manuals, self-help, practical guides), Travel, Children's books.

        Disambiguation cues:
          * A computing textbook used in a class → Computing (not Education) — Education is for textbooks whose subject is the *learning experience itself* or that span subjects.
          * A historical novel → Fiction (Historical) — not History.
          * A memoir by a scientist → Biography & Memoir — not Science.
          * A technical-manual cookbook → How-to — not Reference.
          * Poetry collections → Poetry — even when the author is a philosopher or scientist.
          * When in doubt between a specific sub-genre and the family's *General, pick *General — better a slightly less specific tag than a wrong specific one.

        Pick `uncategorized` ONLY when no case fits at all. Never guess between unrelated genres; never invent labels.
        """
}
