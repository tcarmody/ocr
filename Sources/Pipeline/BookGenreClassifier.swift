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

    /// Closed label set mirroring `BookGenre` 1:1 by raw value
    /// for every case the classifier currently emits. The three
    /// legacy cases (`philosophy`, `history`, `fictionLiterary`)
    /// are intentionally absent — they're decodable on existing
    /// catalogs but the model no longer picks them; `Library
    /// AutoCollections.classifyMissingGenres` re-runs the
    /// classifier on books carrying any legacy case so the
    /// taxonomy refinement propagates without manual intervention.
    /// Order matters for prompt-cache stability — don't reorder
    /// without considering the schema cache implications.
    @Generable
    enum LibraryGenreLabel: String {
        // Poetry / Drama
        case poetry, drama
        // Fiction — literary by language, then genre-fiction sub-genres
        case fictionLiteraryEnglish, fictionLiteraryFrench
        case fictionLiteraryGerman, fictionLiteraryRussian
        case fictionLiteraryHispanic, fictionLiteraryItalian
        case fictionLiteraryEastAsian, fictionLiteraryOther
        case fictionFantasy, fictionScienceFiction
        case fictionMystery, fictionRomance, fictionHistorical
        case fictionGeneral
        // Mathematics / Science
        case mathematics
        case sciencePhysics, scienceChemistry, scienceLifeSciences
        case scienceEarthAstro, scienceGeneral
        // Technology
        case technologyAI, technologyComputing
        case technologyEngineering, technologyGeneral
        // Humanities — Philosophy by period
        case philosophyAncient, philosophyMedieval
        case philosophyEarlyModern, philosophyModern
        case religion
        // History by region
        case historyAncient, historyEurope, historyAmericas
        case historyAsia, historyAfrica, historyMiddleEast, historyGlobal
        case biographyMemoir, linguistics
        case literaryCriticism, literaryTheory
        case arts
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
    /// Science vs Technology on engineering material; History vs
    /// Historical Fiction; etc.).
    static let instructions = """
        You classify books into a closed library taxonomy by genre. Output one label from the closed set.

        Coverage spans both humanities + technical material:
          * Poetry, drama — literary forms.
          * Literary fiction by first language:
              - fictionLiteraryEnglish — Anglophone literary fiction (any country).
              - fictionLiteraryFrench, fictionLiteraryGerman, fictionLiteraryRussian, fictionLiteraryItalian — pick by the language the author wrote in originally, not the translation language.
              - fictionLiteraryHispanic — Spanish or Portuguese, European or Latin American.
              - fictionLiteraryEastAsian — Chinese, Japanese, Korean.
              - fictionLiteraryOther — any other source language (Arabic, Hindi, Scandinavian, Greek modern, Hebrew modern, etc.).
          * Other fiction sub-genres: Fantasy, Science Fiction, Mystery, Romance, Historical (the novel form, NOT history — see disambiguation below), General (clearly fiction but no specific sub-genre fits).
          * Mathematics — algebra, calculus, geometry, statistics, number theory, etc.
          * Science sub-genres: Physics, Chemistry, Life Sciences (biology, medicine, ecology), Earth & Astronomy (geology, oceanography, astronomy), General (popular / multi-disciplinary science).
          * Technology sub-genres:
              - technologyAI — machine learning, deep learning, LLMs, neural networks, classical AI, AI ethics / policy / safety, books *about* AI as a field. ML practice + research + criticism all live here.
              - technologyComputing — programming languages, software engineering, systems, distributed computing, CS theory, databases. Non-AI computing.
              - technologyEngineering — mechanical, electrical, civil, chemical, materials.
              - technologyGeneral — broader tech / industry / how-things-work for non-specialists.
          * Philosophy by period (use the author's milieu, not the publication date):
              - philosophyAncient — pre-500 CE: Plato, Aristotle, the Stoics, Epicureans, Neoplatonism, classical Indian + Chinese philosophy.
              - philosophyMedieval — 500-1500: Aquinas, Anselm, Maimonides, Avicenna, Averroes, scholastics.
              - philosophyEarlyModern — 1500-1800: Descartes, Spinoza, Locke, Berkeley, Hume, Kant, Leibniz, Spinoza.
              - philosophyModern — 1800 to present: Hegel, Marx, Nietzsche, Kierkegaard, Husserl, Heidegger, Wittgenstein, Russell, Sartre, de Beauvoir, Foucault, Derrida, Rawls, Habermas, all 20th–21st c. analytic + continental.
          * Religion — theology, comparative religion, scripture-as-subject (scripture-as-text in Literary Criticism instead).
          * History by region (use the region the history is *about*, not the historian's nationality):
              - historyAncient — pre-500 CE: Greco-Roman, ancient Near East, ancient Egypt, ancient China, ancient India. Period overrides region pre-500 CE because the boundaries don't map to modern regions.
              - historyEurope — medieval through modern European history.
              - historyAmericas — North America, South America, Caribbean; pre-Columbian through modern.
              - historyAsia — East Asia (post-ancient), South Asia, Central Asia, Southeast Asia, modern.
              - historyAfrica — African history; pre-colonial, colonial, post-colonial.
              - historyMiddleEast — modern Middle East (post-500 CE through present); Islamic empires, Ottoman, modern states.
              - historyGlobal — world history, comparative / cross-regional studies, big-history work that doesn't fit any single region.
          * Biography & Memoir, Linguistics, Literary Criticism (close readings of specific authors / works / periods), Literary Theory (structuralism, post-structuralism, hermeneutics, narratology, reader-response, etc.), Arts (art history / criticism of visual or performing arts / music).
          * Social Science sub-genres: Economics, Politics, Psychology, General (sociology, anthropology, etc.).
          * Reference (dictionaries, encyclopedias, manuals), Education (textbooks, study guides), How-to (cookbooks, hobby manuals, self-help, practical guides), Travel, Children's books.

        Disambiguation cues:
          * **History vs Historical Fiction** is the most common false-positive trap. *Historical Fiction* is the **novel form** — invented protagonist, narrative voice in scene, dialogue between characters, present-tense action set in a past period. *History* is a **non-fiction** account — argument, primary-source citation, footnotes / endnotes, "the author argues / shows," scholarly apparatus. "Historical" in a title NEVER means historical fiction by itself. A history *of* the Roman Empire, *of* Medieval France, *of* the Thirty Years' War, *of* the slave trade, *of* the Black Death → History (pick the region). Only pick fictionHistorical when the book is clearly a novel.
          * A computing textbook used in a class → Computing (or AI if the subject is AI specifically) — Education is for textbooks whose subject is the *learning experience itself* or that span subjects.
          * Programming an AI system → technologyAI (the subject is AI). A general programming book that has a short AI chapter → technologyComputing. A philosophy-of-AI book → technologyAI (it's *about* AI as a field even if it's also philosophy; pick AI when the AI angle is the through-line).
          * A memoir by a scientist → Biography & Memoir — not Science.
          * A historian's memoir → Biography & Memoir — not History.
          * A technical-manual cookbook → How-to — not Reference.
          * Poetry collections → Poetry — even when the author is a philosopher or scientist.
          * A close reading of a specific novel / poet / period → Literary Criticism. A book *about* how to read literature in general, or about a theoretical school (Derrida on grammatology, Iser on reception, etc.) → Literary Theory. When in doubt between the two, pick Literary Criticism for author-focused or work-focused studies and Literary Theory for method-focused or framework-focused work.
          * Philosophy of language / aesthetics that treats literature only incidentally → Philosophy (pick the period). Reserve Literary Theory for books where the analysis of literature is the primary object.
          * For literary fiction, **use the original composition language** (Russian for Tolstoy, French for Proust, Japanese for Murakami) — even when the user's copy is in English translation. Author's nationality is a hint but not authoritative (Conrad wrote in English; Beckett wrote in both French and English — pick the language of the specific book).
          * When in doubt between a specific sub-genre and the family's *General, pick *General — better a slightly less specific tag than a wrong specific one. Do the same when in doubt between two periods of philosophy or two regions of history (philosophyModern catches a stunning range; historyGlobal exists for genuine cross-region work).

        Pick `uncategorized` ONLY when no case fits at all. Never guess between unrelated genres; never invent labels.
        """
}
