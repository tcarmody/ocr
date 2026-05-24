import Foundation

/// Built-in synonym map collapsing canonical entity names that
/// refer to the same underlying concept but get split into
/// separate rows by NLTagger's literal-string canonicalization.
/// Real-library probe surfaced obvious duplicates: `america` vs
/// `united states`, `france` vs `french`, `cambridge` vs
/// `cambridge university press`, etc. — each split inflates the
/// concept count and dilutes co-occurrence signal.
///
/// Applied during `LibraryConceptGraph.build`: each entity is
/// mapped through `canonical(for:)` before coverage rows and
/// co-occurrence edges are written, so the federated map sees one
/// merged row per real concept.
///
/// The map is intentionally conservative. We only merge when the
/// alias relationship is unambiguous (e.g. there's no realistic
/// chat query where the user wants to distinguish "France" from
/// "French"). Anything contested ("ancient greece" vs "greece"?)
/// stays separate; the user-editable alias dictionary (existing
/// `R-Chat-Graph-Lite` follow-up) handles cases that need
/// per-library taste.
enum ConceptAliases {

    /// Return the canonical primary form for `canonical`. If the
    /// input isn't in the alias map, return it unchanged so
    /// non-aliased entities pass through untouched.
    static func canonical(for canonical: String) -> String {
        aliasMap[canonical] ?? canonical
    }

    /// Snapshot of the alias map for inspection / tests.
    static var snapshot: [String: String] { aliasMap }

    /// Alias → primary. Primary is the form we want to surface
    /// in UI; it's the "Display canonical." Pick the most
    /// commonly-used form, lowercased.
    private static let aliasMap: [String: String] = {
        var out: [String: String] = [:]
        // Each group's first element is the primary; remaining
        // elements are aliases that collapse onto it.
        let groups: [[String]] = [
            // Countries / nationalities
            [
                "united states", "america", "u.s.", "u.s.a.",
                "usa", "us", "united states of america",
            ],
            ["united kingdom", "britain", "great britain", "uk"],
            ["soviet union", "ussr", "soviet"],
            // Cities + their press / institution variants. We
            // collapse the press onto the city ONLY when the
            // stopword filter isn't dropping both — but since
            // both the city and the press are in
            // ConceptStopwords for cities-of-publication, this
            // is defensive. Kept here so if we relax the
            // stopwords later (per-library opt-out), the alias
            // still does the right thing.
            ["cambridge university press", "cambridge university"],
            ["oxford university press", "oxford university"],
            ["harvard university press", "harvard university"],
            // The publisher Harper has multiple imprints.
            ["harper", "harper & row", "harpercollins"],
            // Greek + Latin authors with multiple spellings.
            ["plato", "platon"],
            ["aristotle", "aristoteles"],
            ["jesus", "jesus christ", "christ"],
        ]
        for group in groups {
            guard let primary = group.first else { continue }
            for alias in group.dropFirst() {
                out[alias] = primary
            }
        }
        return out
    }()
}
