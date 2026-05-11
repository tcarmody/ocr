import Foundation

/// R-Auto-Collections Phase 2. Closed-taxonomy genre for a book —
/// the leaf level of a single-sublevel hierarchy (Fiction →
/// Fantasy, Science → Physics, Technology → Computing). Used by
/// `BookGenreClassifier` (AFM-backed) and by
/// `LibraryAutoCollections` to materialize "Auto: by Genre"
/// collections.
///
/// Taxonomy goals:
///   * Cover both humanities + technical / scientific material —
///     a typical research library spans both.
///   * Single sublevel: deep hierarchies make collections too
///     narrow to be useful at this scale, and AFM handles flat
///     closed enums best.
///   * Each top-level family has a `*General` catch-all for books
///     that fit the family but not a specific sub-genre (e.g.
///     `scienceGeneral` for popular-science cross-disciplinary
///     work).
public enum BookGenre: String, CaseIterable, Sendable, Codable, Hashable {
    // MARK: - Poetry / Drama
    case poetry
    case drama

    // MARK: - Fiction (sub-genres only — no top-level "fiction" case)
    case fictionLiterary
    case fictionFantasy
    case fictionScienceFiction
    case fictionMystery
    case fictionRomance
    case fictionHistorical
    case fictionGeneral

    // MARK: - Mathematics
    case mathematics

    // MARK: - Science (natural)
    case sciencePhysics
    case scienceChemistry
    case scienceLifeSciences  // biology, medicine, ecology
    case scienceEarthAstro    // geology, oceanography, astronomy
    case scienceGeneral       // popular science, multi-disciplinary

    // MARK: - Technology / Engineering
    case technologyComputing  // programming, CS, software, AI
    case technologyEngineering  // mechanical, electrical, civil
    case technologyGeneral

    // MARK: - Humanities
    case philosophy
    case religion
    case history
    case biographyMemoir
    case linguistics
    case arts  // art history, criticism, music, performing arts

    // MARK: - Social Sciences
    case socialScienceEconomics
    case socialSciencePolitics
    case socialSciencePsychology
    case socialScienceGeneral  // sociology, anthropology, etc.

    // MARK: - Practical / Reference / Other
    case reference  // dictionaries, encyclopedias, manuals
    case education  // textbooks, study guides
    case howTo      // cookbooks, hobby manuals, self-help
    case travel
    case children

    // MARK: - Fallback
    case uncategorized

    // MARK: - Display

    /// Group label for the sidebar — collapses sub-genres back
    /// into their top-level family. Genres that have no
    /// sub-genres return their own display name (Poetry stays
    /// "Poetry"; Philosophy stays "Philosophy").
    public var topLevel: String {
        switch self {
        case .poetry: return "Poetry"
        case .drama: return "Drama"
        case .fictionLiterary, .fictionFantasy, .fictionScienceFiction,
             .fictionMystery, .fictionRomance, .fictionHistorical,
             .fictionGeneral:
            return "Fiction"
        case .mathematics: return "Mathematics"
        case .sciencePhysics, .scienceChemistry, .scienceLifeSciences,
             .scienceEarthAstro, .scienceGeneral:
            return "Science"
        case .technologyComputing, .technologyEngineering,
             .technologyGeneral:
            return "Technology"
        case .philosophy: return "Philosophy"
        case .religion: return "Religion"
        case .history: return "History"
        case .biographyMemoir: return "Biography & Memoir"
        case .linguistics: return "Linguistics"
        case .arts: return "Arts"
        case .socialScienceEconomics, .socialSciencePolitics,
             .socialSciencePsychology, .socialScienceGeneral:
            return "Social Science"
        case .reference: return "Reference"
        case .education: return "Education"
        case .howTo: return "How-to"
        case .travel: return "Travel"
        case .children: return "Children"
        case .uncategorized: return "Uncategorized"
        }
    }

    /// Leaf-only label — the sub-genre's name on its own. For
    /// genres without a sub-level, equals `topLevel`. Used in
    /// "Top-level: Leaf" collection naming.
    public var leafName: String {
        switch self {
        case .fictionLiterary: return "Literary"
        case .fictionFantasy: return "Fantasy"
        case .fictionScienceFiction: return "Science Fiction"
        case .fictionMystery: return "Mystery"
        case .fictionRomance: return "Romance"
        case .fictionHistorical: return "Historical"
        case .fictionGeneral: return "General"
        case .sciencePhysics: return "Physics"
        case .scienceChemistry: return "Chemistry"
        case .scienceLifeSciences: return "Life Sciences"
        case .scienceEarthAstro: return "Earth & Astronomy"
        case .scienceGeneral: return "General"
        case .technologyComputing: return "Computing"
        case .technologyEngineering: return "Engineering"
        case .technologyGeneral: return "General"
        case .socialScienceEconomics: return "Economics"
        case .socialSciencePolitics: return "Politics"
        case .socialSciencePsychology: return "Psychology"
        case .socialScienceGeneral: return "General"
        default: return topLevel
        }
    }

    /// Name used for the auto-generated `BookCollection`. Sub-
    /// genres render as "Top-level: Leaf" so a flat sidebar list
    /// still reads grouped ("Fiction: Fantasy", "Science:
    /// Physics"); top-level genres without sub-levels render
    /// just as the top-level name ("Poetry", "Philosophy").
    public var collectionName: String {
        if leafName == topLevel { return topLevel }
        return "\(topLevel): \(leafName)"
    }

    /// True when this genre has siblings under the same top-
    /// level — drives sort order in the sidebar.
    public var hasSubGenres: Bool {
        leafName != topLevel
    }
}
