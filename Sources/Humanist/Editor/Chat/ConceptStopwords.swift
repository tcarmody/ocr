import Foundation

/// Built-in denylist of canonical entity names that the federated
/// concept rollup should drop on the floor. NLTagger at library
/// scale surfaces a large amount of publication-metadata noise —
/// cities of publication, publisher names, library-catalog headers,
/// language demonyms, and single given names that NLTagger emits
/// as personal entities when they appear capitalized at sentence
/// starts. None of these carry the "what concept does this book
/// engage with?" signal the Concepts sidebar is built around.
///
/// Discovered empirically via the Phase 1 probe on the user's
/// real 2k-book library; top-25 concepts by breadth were
/// dominated by `NEW YORK`, `LONDON`, `CAMBRIDGE UNIVERSITY PRESS`,
/// `LIBRARY OF CONGRESS`, etc.
///
/// All entries are lowercased — the rollup canonicalizes before
/// the membership check. User-editable extensions land later via
/// the existing `R-Chat-Graph-Lite` alias-dictionary surface.
enum ConceptStopwords {

    /// Returns true iff `canonical` should be excluded from the
    /// federated rollup entirely (no coverage rows, no edges).
    static func contains(_ canonical: String) -> Bool {
        denylist.contains(canonical)
    }

    /// Snapshot of the current denylist. Exposed so tests can
    /// assert the contents and the Settings UI (planned) can
    /// surface "managed by Humanist" vs "added by you" rows.
    static var snapshot: Set<String> { denylist }

    private static let denylist: Set<String> = {
        var out: Set<String> = []
        out.formUnion(citiesOfPublication)
        out.formUnion(publishers)
        out.formUnion(catalogHeaders)
        out.formUnion(demonyms)
        out.formUnion(noisyGivenNames)
        out.formUnion(noisyRomanNumerals)
        out.formUnion(noisyFragments)
        return out
    }()

    // MARK: - Categories

    /// Cities that dominate the entity table because they sit in
    /// every book's title-page imprint. Real geographic chat
    /// queries still work via `search_library` — we're only
    /// suppressing the concept-browser surface where the noise
    /// crowds out substantive entities.
    private static let citiesOfPublication: Set<String> = [
        "new york", "london", "paris", "cambridge", "oxford",
        "boston", "chicago", "philadelphia", "washington",
        "berlin", "munich", "amsterdam", "rome", "venice",
        "edinburgh", "dublin", "los angeles", "san francisco",
        "tokyo", "moscow",
    ]

    /// Academic / trade publishers that NLTagger picks up as
    /// `.organizationName` and that appear in nearly every book's
    /// frontmatter or footnotes.
    private static let publishers: Set<String> = [
        "cambridge university press", "oxford university press",
        "harvard university press", "yale university press",
        "princeton university press", "stanford university press",
        "university of chicago press", "mit press", "routledge",
        "harper", "harper & row", "macmillan", "penguin",
        "vintage", "norton", "w. w. norton",
        "houghton mifflin", "knopf", "doubleday", "random house",
        "simon & schuster", "wiley", "elsevier", "springer",
        "blackwell", "sage", "palgrave", "palgrave macmillan",
    ]

    /// Library / archive header text that ends up in metadata
    /// pages and copyright fronts.
    private static let catalogHeaders: Set<String> = [
        "library of congress", "british library",
        "table of contents", "all rights reserved",
        "copyright", "isbn",
    ]

    /// Language demonyms NLTagger emits as `.placeName`. They
    /// carry breadth but no specificity — every book about
    /// anything French gets a "FRENCH" hit.
    private static let demonyms: Set<String> = [
        "french", "german", "english", "spanish", "italian",
        "greek", "european", "american", "russian", "chinese",
        "japanese", "indian", "british", "irish", "scottish",
        "dutch", "swedish", "norwegian", "danish", "polish",
        "portuguese", "latin", "arabic", "hebrew",
    ]

    /// Common single given names that NLTagger fires on whenever
    /// a capitalized first name appears at a sentence start. The
    /// per-book index already catches these; at library scale
    /// they dominate the breadth ranking with no useful signal
    /// (the user is unlikely to want to browse all books
    /// mentioning "John").
    private static let noisyGivenNames: Set<String> = [
        "john", "paul", "peter", "james", "mary", "michael",
        "david", "robert", "george", "william", "henry",
        "thomas", "richard", "charles", "edward", "louis",
        "jean", "carl", "max", "hans", "joseph", "anne",
        // Biblical / mythic single names with given-name
        // overlap — probe surfaced ADAM at 713 books, mostly
        // genealogy / scripture references that aren't
        // concept-level signal.
        "adam", "eve", "noah", "abraham", "moses", "david king",
        // Common surnames NLTagger over-detects against the
        // body of academic prose. BROWN at 919 books was the
        // worst offender on the probe library.
        "brown", "smith", "jones", "white", "green", "black",
        "young", "hall", "wright",
    ]

    /// Standalone roman-numeral fragments NLTagger sometimes
    /// emits as place-name entities (chapter / section numbers
    /// that get capitalized in the original text). "St" lands
    /// here too — it's saint-abbreviation noise that NLTagger
    /// reads as a personal name.
    private static let noisyRomanNumerals: Set<String> = [
        "i", "ii", "iii", "iv", "v", "vi", "vii", "viii",
        "ix", "x", "xi", "xii", "xiii", "xiv", "xv",
        "st", "mr", "mrs", "dr",
    ]

    /// Single-word fragments that leak through despite the
    /// multi-word stopwords elsewhere. `congress` is the worst
    /// case — caught by `library of congress` but NLTagger also
    /// emits the bare word when it appears outside that phrase.
    /// `earth` and `west` are similarly broad terms that
    /// dominate breadth rankings without being substantive
    /// concepts.
    private static let noisyFragments: Set<String> = [
        "congress", "earth", "west", "east", "north", "south",
        "ed", "trans", "vol", "no", "pp",
        // Single-letter initials with trailing dot — NLTagger
        // sometimes captures author initials like "Kant, I." as
        // standalone entities. The bare-letter forms are caught
        // by noisyRomanNumerals.
        "i.", "j.", "h.", "g.", "f.", "e.", "d.", "c.", "b.", "a.",
        "m.", "n.", "o.", "p.", "r.", "s.", "t.", "w.",
    ]
}
