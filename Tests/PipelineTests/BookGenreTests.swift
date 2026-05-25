import XCTest
@testable import Pipeline

/// R-Auto-Collections Phase 2: `BookGenre`'s display logic.
/// The classifier itself can't be unit-tested without
/// Apple Intelligence on the test machine; this covers the
/// taxonomy invariants the sidebar relies on.
final class BookGenreTests: XCTestCase {

    // MARK: - topLevel

    func test_fiction_subgenres_share_one_topLevel() {
        let fictionCases: [BookGenre] = [
            .fictionLiterary,  // legacy
            .fictionLiteraryEnglish, .fictionLiteraryFrench,
            .fictionLiteraryGerman, .fictionLiteraryRussian,
            .fictionLiteraryHispanic, .fictionLiteraryItalian,
            .fictionLiteraryEastAsian, .fictionLiteraryOther,
            .fictionFantasy, .fictionScienceFiction,
            .fictionMystery, .fictionRomance, .fictionHistorical,
            .fictionGeneral
        ]
        for c in fictionCases {
            XCTAssertEqual(c.topLevel, "Fiction",
                "\(c) should rollup to Fiction")
        }
    }

    func test_science_subgenres_share_one_topLevel() {
        let cases: [BookGenre] = [
            .sciencePhysics, .scienceChemistry, .scienceLifeSciences,
            .scienceEarthAstro, .scienceGeneral
        ]
        for c in cases {
            XCTAssertEqual(c.topLevel, "Science",
                "\(c) should rollup to Science")
        }
    }

    func test_technology_subgenres_share_one_topLevel() {
        let cases: [BookGenre] = [
            .technologyAI, .technologyComputing,
            .technologyEngineering, .technologyGeneral
        ]
        for c in cases {
            XCTAssertEqual(c.topLevel, "Technology",
                "\(c) should rollup to Technology")
        }
    }

    func test_philosophy_periods_share_one_topLevel() {
        let cases: [BookGenre] = [
            .philosophy,  // legacy
            .philosophyAncient, .philosophyMedieval,
            .philosophyEarlyModern, .philosophyModern
        ]
        for c in cases {
            XCTAssertEqual(c.topLevel, "Philosophy",
                "\(c) should rollup to Philosophy")
        }
    }

    func test_history_regions_share_one_topLevel() {
        let cases: [BookGenre] = [
            .history,  // legacy
            .historyAncient, .historyEurope, .historyAmericas,
            .historyAsia, .historyAfrica, .historyMiddleEast,
            .historyGlobal
        ]
        for c in cases {
            XCTAssertEqual(c.topLevel, "History",
                "\(c) should rollup to History")
        }
    }

    func test_socialScience_subgenres_share_one_topLevel() {
        let cases: [BookGenre] = [
            .socialScienceEconomics, .socialSciencePolitics,
            .socialSciencePsychology, .socialScienceGeneral
        ]
        for c in cases {
            XCTAssertEqual(c.topLevel, "Social Science",
                "\(c) should rollup to Social Science")
        }
    }

    func test_standalone_genres_are_their_own_topLevel() {
        // Single-level genres (no sub-genres). topLevel ==
        // displayName-ish; leafName == topLevel. Philosophy and
        // History were single-level pre-2026-05-25; they now have
        // sub-genres so they're out of this list and validated
        // separately above.
        let cases: [BookGenre] = [
            .poetry, .drama, .mathematics, .religion,
            .linguistics, .arts, .reference, .education,
            .howTo, .travel, .children
        ]
        for c in cases {
            XCTAssertEqual(c.leafName, c.topLevel,
                "\(c) is single-level; leafName should equal topLevel")
            XCTAssertFalse(c.hasSubGenres,
                "\(c) should report hasSubGenres == false")
        }
    }

    func test_subgenres_report_hasSubGenres_true() {
        XCTAssertTrue(BookGenre.fictionFantasy.hasSubGenres)
        XCTAssertTrue(BookGenre.fictionLiteraryEnglish.hasSubGenres)
        XCTAssertTrue(BookGenre.sciencePhysics.hasSubGenres)
        XCTAssertTrue(BookGenre.technologyAI.hasSubGenres)
        XCTAssertTrue(BookGenre.technologyComputing.hasSubGenres)
        XCTAssertTrue(BookGenre.philosophyAncient.hasSubGenres)
        XCTAssertTrue(BookGenre.historyEurope.hasSubGenres)
        XCTAssertTrue(BookGenre.socialScienceEconomics.hasSubGenres)
    }

    // MARK: - collectionName

    func test_collectionName_for_subgenre_uses_TopLevel_Leaf_format() {
        XCTAssertEqual(BookGenre.fictionFantasy.collectionName,
                       "Fiction: Fantasy")
        XCTAssertEqual(BookGenre.fictionLiteraryEnglish.collectionName,
                       "Fiction: Literary (English)")
        XCTAssertEqual(BookGenre.sciencePhysics.collectionName,
                       "Science: Physics")
        XCTAssertEqual(BookGenre.technologyAI.collectionName,
                       "Technology: Artificial Intelligence")
        XCTAssertEqual(BookGenre.technologyComputing.collectionName,
                       "Technology: Computing")
        XCTAssertEqual(BookGenre.philosophyAncient.collectionName,
                       "Philosophy: Ancient")
        XCTAssertEqual(BookGenre.philosophyEarlyModern.collectionName,
                       "Philosophy: Early Modern")
        XCTAssertEqual(BookGenre.historyEurope.collectionName,
                       "History: Europe")
        XCTAssertEqual(BookGenre.historyMiddleEast.collectionName,
                       "History: Middle East")
        XCTAssertEqual(BookGenre.socialScienceEconomics.collectionName,
                       "Social Science: Economics")
    }

    func test_collectionName_for_single_level_genre_is_plain() {
        XCTAssertEqual(BookGenre.poetry.collectionName, "Poetry")
        XCTAssertEqual(BookGenre.mathematics.collectionName, "Mathematics")
        XCTAssertEqual(BookGenre.religion.collectionName, "Religion")
        XCTAssertEqual(BookGenre.linguistics.collectionName, "Linguistics")
    }

    // MARK: - Legacy compatibility

    func test_legacyCases_set_is_exactly_the_three_pre_refinement_leaves() {
        XCTAssertEqual(BookGenre.legacyCases,
                       Set([.philosophy, .history, .fictionLiterary]))
    }

    // MARK: - Coverage breadth

    func test_taxonomy_covers_humanities_and_technical_material() {
        // Sanity check that the broadening pass landed — the
        // user's explicit request was "include technical /
        // computing, math, science, etc." Verify each family is
        // present in the enum.
        XCTAssertTrue(BookGenre.allCases.contains(.mathematics))
        XCTAssertTrue(BookGenre.allCases.contains(.technologyAI))
        XCTAssertTrue(BookGenre.allCases.contains(.technologyComputing))
        XCTAssertTrue(BookGenre.allCases.contains(.scienceLifeSciences))
        XCTAssertTrue(BookGenre.allCases.contains(.philosophyAncient))
        XCTAssertTrue(BookGenre.allCases.contains(.philosophyModern))
        XCTAssertTrue(BookGenre.allCases.contains(.historyEurope))
        XCTAssertTrue(BookGenre.allCases.contains(.historyGlobal))
        XCTAssertTrue(BookGenre.allCases.contains(.fictionLiteraryEnglish))
        XCTAssertTrue(BookGenre.allCases.contains(.fictionLiteraryOther))
        XCTAssertTrue(BookGenre.allCases.contains(.fictionFantasy))
        XCTAssertTrue(BookGenre.allCases.contains(.literaryCriticism))
        XCTAssertTrue(BookGenre.allCases.contains(.literaryTheory))
        XCTAssertTrue(BookGenre.allCases.contains(.uncategorized))
    }

    func test_every_case_has_non_empty_display_strings() {
        for c in BookGenre.allCases {
            XCTAssertFalse(c.topLevel.isEmpty,
                "\(c) has empty topLevel")
            XCTAssertFalse(c.leafName.isEmpty,
                "\(c) has empty leafName")
            XCTAssertFalse(c.collectionName.isEmpty,
                "\(c) has empty collectionName")
        }
    }

    // MARK: - Codable

    func test_BookGenre_rawValue_round_trips_through_JSON() {
        // BookGenre is Codable via rawValue. Verify each case
        // survives a JSON encode/decode trip without ambiguity.
        for c in BookGenre.allCases {
            let data = try! JSONEncoder().encode(c)
            let back = try! JSONDecoder().decode(BookGenre.self, from: data)
            XCTAssertEqual(c, back, "\(c) should round-trip")
        }
    }
}
