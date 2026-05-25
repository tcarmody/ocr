import Foundation
import NaturalLanguage
import EPUB

/// Per-book named-entity index. Runs Apple's `NLTagger` with the
/// `.nameType` scheme over every paragraph and aggregates the
/// detected PERSON / PLACE / ORG names into a `name → [anchor]`
/// table.
///
/// Used by the chat retriever to handle entity-shaped queries
/// ("every paragraph that mentions Foucault," "what does the book
/// say about Athens?") and, when federated across the library, the
/// cross-corpus form ("which books discuss both Foucault and
/// Bourdieu?"). Entity matches contribute to the RRF fusion as a
/// boost — paragraphs mentioning a matched entity rank higher
/// alongside BM25 + embedding signals.
///
/// Quality is moderate on contemporary English and weaker on
/// classical-script text. The user-facing alias dictionary
/// (R-Chat-Graph-Lite Settings) is the planned remediation for
/// missed entities; for v1 the index just records what NLTagger
/// surfaces.
public struct BookEntityIndex: Sendable, Codable, Equatable {

    /// One paragraph anchor — mirrors the embedding sidecar's
    /// (chapterIdx, paragraphIdx) tuple so a hit can be projected
    /// onto the same paragraph identity space the cosine path uses.
    public struct Anchor: Sendable, Codable, Equatable, Hashable {
        public let chapterIdx: Int
        public let paragraphIdx: Int

        public init(chapterIdx: Int, paragraphIdx: Int) {
            self.chapterIdx = chapterIdx
            self.paragraphIdx = paragraphIdx
        }
    }

    /// Canonical (lowercased, whitespace-trimmed) entity name →
    /// every anchor that mentions it. Sorted within the array by
    /// (chapterIdx, paragraphIdx) for deterministic output.
    public let mentions: [String: [Anchor]]
    /// Canonical name → best display-cased form we saw. Used by
    /// the retriever to label entity hits and by the alias-
    /// dictionary editor (planned) to show users what's there.
    public let displayNames: [String: String]

    public static let empty = BookEntityIndex(mentions: [:], displayNames: [:])

    public init(mentions: [String: [Anchor]], displayNames: [String: String]) {
        self.mentions = mentions
        self.displayNames = displayNames
    }

    // MARK: - Building

    /// Walk every paragraph in the book, run NER on each, and
    /// aggregate by canonical name. Sequential — NLTagger is fast
    /// enough that a 1500-paragraph book completes in seconds, and
    /// the build sits inside the existing embedding-build task so
    /// it doesn't add to perceived latency.
    ///
    /// `aliasTerms` are user-curated concept seeds (from
    /// `AliasDictionary`) that get folded into the index as
    /// additional first-class "entities" — every paragraph
    /// mentioning an alias term registers an anchor under that
    /// term's canonical key. Lets the Topics view surface
    /// concepts that NLTagger's `.nameType` scheme can't recognize
    /// (multi-word phrases with prepositions like "will to power",
    /// classical/transliterated names, domain jargon like
    /// "biopolitics" or "heterotopia"). Default empty for tests +
    /// CLI paths that don't have an alias dictionary handy.
    public static func build(
        from book: EPUBBook, aliasTerms: Set<String> = []
    ) -> BookEntityIndex {
        let items = ParagraphExtractor.extract(from: book)
        var mentions: [String: [Anchor]] = [:]
        var displayNames: [String: String] = [:]

        // Pass 1: NER. Extracts personalName / placeName /
        // organizationName via NLTagger's nameType scheme. Same
        // logic as the v1 entity index.
        for item in items {
            let pairs = EntityExtractor.extract(from: item.text)
            for (canonical, displayName) in pairs {
                let anchor = Anchor(
                    chapterIdx: item.chapterIdx,
                    paragraphIdx: item.paragraphIdx
                )
                if mentions[canonical]?.last != anchor {
                    mentions[canonical, default: []].append(anchor)
                }
                let existing = displayNames[canonical] ?? ""
                if Self.scoreDisplay(displayName) > Self.scoreDisplay(existing) {
                    displayNames[canonical] = displayName
                }
            }
        }

        // Pass 2: statistical concept mining. NLTagger's
        // `.lexicalClass` scheme tags every word with a part-of-
        // speech; we collect runs of adjacent (noun | adjective)
        // tokens ending in a noun, length 2-4. Per-book frequency
        // gate (>=3 mentions) drops noise; the federated rollup
        // applies a second cross-book filter on top. The two
        // passes share the `mentions` table — concepts are
        // first-class entities for the purposes of the Topics
        // view; differentiating them in UI is a v2 if real use
        // shows it matters.
        var conceptHits: [String: [Anchor]] = [:]
        var conceptCounts: [String: Int] = [:]
        var conceptDisplay: [String: String] = [:]
        for item in items {
            let pairs = ConceptExtractor.extract(from: item.text)
            let anchor = Anchor(
                chapterIdx: item.chapterIdx,
                paragraphIdx: item.paragraphIdx
            )
            for (canonical, display) in pairs {
                if conceptHits[canonical]?.last != anchor {
                    conceptHits[canonical, default: []].append(anchor)
                }
                conceptCounts[canonical, default: 0] += 1
                let existing = conceptDisplay[canonical] ?? ""
                if Self.scoreDisplay(display) > Self.scoreDisplay(existing) {
                    conceptDisplay[canonical] = display
                }
            }
        }
        // Merge concepts that pass the per-book frequency gate.
        // NER entries already in `mentions` win — if NER and the
        // concept extractor both surfaced the same canonical
        // (e.g. an org name that's also a common noun phrase),
        // NER's display form sticks.
        for (canonical, count) in conceptCounts {
            guard count >= conceptMinPerBook else { continue }
            if mentions[canonical] == nil {
                mentions[canonical] = conceptHits[canonical] ?? []
                if let display = conceptDisplay[canonical] {
                    displayNames[canonical] = display
                }
            }
        }

        // Pass 3: alias dictionary scan. The user curated these
        // explicitly so they bypass the frequency gate — even a
        // single paragraph mentioning "biopolitics" should
        // register. Case-insensitive substring match.
        if !aliasTerms.isEmpty {
            for item in items {
                let lowered = item.text.lowercased()
                let anchor = Anchor(
                    chapterIdx: item.chapterIdx,
                    paragraphIdx: item.paragraphIdx
                )
                for term in aliasTerms {
                    guard !term.isEmpty, lowered.contains(term) else { continue }
                    if mentions[term]?.last != anchor {
                        mentions[term, default: []].append(anchor)
                    }
                    if displayNames[term] == nil {
                        displayNames[term] = term.capitalized
                    }
                }
            }
        }

        return BookEntityIndex(
            mentions: mentions,
            displayNames: displayNames
        )
    }

    /// Per-book frequency floor for the statistical concept
    /// miner. A 1500-paragraph book is typically ~150K words —
    /// a true conceptual through-line recurs more than three
    /// times. Lower thresholds let "good thing" / "long time"
    /// flood the rollup; higher misses sparse-but-genuine
    /// concepts.
    private static let conceptMinPerBook = 3

    /// Display-form ranking heuristic: prefer longer names + more
    /// uppercase letters. "Michel Foucault" beats "Foucault" beats
    /// "michel foucault". Length acts as a tiebreaker.
    private static func scoreDisplay(_ s: String) -> Int {
        let uppers = s.filter(\.isUppercase).count
        return uppers * 10 + s.count
    }

    // MARK: - Querying

    /// Detect entities in `query` and return the canonical keys
    /// that exist in this index. Order: most-mentioned first
    /// (heavily-mentioned entities are usually more central to the
    /// book; surfacing them first makes the retriever's boost
    /// apply where it's most likely to help).
    public func entitiesMatching(query: String) -> [String] {
        let detected = EntityExtractor.extract(from: query)
            .map(\.0)
        let unique = Array(Set(detected))
        return unique
            .filter { mentions[$0] != nil }
            .sorted {
                let lhs = mentions[$0]?.count ?? 0
                let rhs = mentions[$1]?.count ?? 0
                return lhs > rhs
            }
    }

    /// Every paragraph anchor mentioning `canonical`. Empty if not
    /// present.
    public func anchors(for canonical: String) -> [Anchor] {
        mentions[canonical] ?? []
    }
}

// MARK: - Concept extractor

/// Statistical noun-phrase miner for the `BookEntityIndex` build
/// path. Uses NLTagger's `.lexicalClass` scheme to tag every word
/// as a part-of-speech, then collects adjacent runs of
/// (noun | adjective) tokens that end in a noun, length 2-4.
///
/// Designed to complement `EntityExtractor` (which only catches
/// PERSON / PLACE / ORG via NLTagger's `.nameType` scheme):
/// concept-shaped phrases that named-entity recognition misses —
/// "artificial intelligence", "speech act", "rational choice",
/// "phenomenological reduction", "critical theory". The per-book
/// frequency filter in `BookEntityIndex.build` weeds out
/// throwaway combinations like "good thing" or "long time".
///
/// Limitations:
///   * Single-word concepts ("deconstruction", "liberalism") are
///     skipped — there's no way to distinguish a meaningful
///     single noun from any other noun without library-wide
///     statistics, which the per-book pass doesn't have.
///     `AliasDictionary` is the seam for these.
///   * Preposition-bearing phrases ("will to power", "philosophy
///     of mind") are skipped — adding preposition support
///     produces too many false positives ("road to nowhere",
///     "table of contents"). Alias dictionary again.
///   * Proper-noun-shaped phrases (initial-capital tokens) are
///     skipped — NER's nameType pass already handled those.
///
/// Output canonical key is lowercase with single-space separators,
/// so "Artificial Intelligence" and "artificial  intelligence"
/// both canonicalize to "artificial intelligence".
public enum ConceptExtractor {

    public static func extract(
        from text: String
    ) -> [(canonical: String, displayName: String)] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        let options: NLTagger.Options = [
            .omitWhitespace, .omitPunctuation,
        ]
        var phrases: [[(token: String, isNoun: Bool, isCapped: Bool)]] = []
        var current: [(token: String, isNoun: Bool, isCapped: Bool)] = []

        let range = text.startIndex..<text.endIndex
        tagger.enumerateTags(
            in: range, unit: .word,
            scheme: .lexicalClass, options: options
        ) { tag, tokenRange in
            guard tokenRange.lowerBound >= text.startIndex,
                  tokenRange.upperBound <= text.endIndex
            else { return true }
            let raw = String(text[tokenRange])
            let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty, let tag else {
                flush(&current, into: &phrases)
                return true
            }
            let capped = isInitialCap(stripped)
            switch tag {
            case .noun:
                current.append((stripped.lowercased(), true, capped))
            case .adjective:
                current.append((stripped.lowercased(), false, capped))
            default:
                flush(&current, into: &phrases)
            }
            return true
        }
        flush(&current, into: &phrases)

        var out: [(String, String)] = []
        for phrase in phrases {
            // Phrase must end in a noun; length 2-4; no stopwords.
            guard (2...4).contains(phrase.count),
                  phrase.last?.isNoun == true
            else { continue }
            if phrase.contains(where: { Self.stopwords.contains($0.token) }) {
                continue
            }
            // Proper-noun-shape filter: reject phrases where every
            // content token is initial-capitalized. That catches
            // "President Wilson" and "Roman Empire" without
            // sacrificing sentence-initial concepts like
            // "Artificial intelligence" (first-cap only). Genuine
            // multi-capped concepts ("American Pragmatism")
            // currently get filtered too — alias dictionary is the
            // escape hatch when a user cares about a specific one.
            if phrase.allSatisfy(\.isCapped) { continue }
            let canonical = phrase.map(\.token).joined(separator: " ")
            // Same canonical form serves as display in v1 — the
            // BookEntityIndex's `scoreDisplay` heuristic picks the
            // best form when other passes (NER, aliases) contribute
            // alternatives.
            out.append((canonical, canonical))
        }
        return out
    }

    private static func flush(
        _ current: inout [(token: String, isNoun: Bool, isCapped: Bool)],
        into phrases: inout [[(token: String, isNoun: Bool, isCapped: Bool)]]
    ) {
        if !current.isEmpty {
            phrases.append(current)
            current = []
        }
    }

    private static func isInitialCap(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        return first.isUppercase
    }

    /// Tokens that, if they appear anywhere in a phrase, disqualify
    /// the phrase. Keeps "good thing" / "long time" / "one way"
    /// out of the rollup. Deliberately conservative — only the
    /// most-obvious nouns/adjectives that recur enough to risk
    /// dominating the Topics view.
    private static let stopwords: Set<String> = [
        "thing", "things", "way", "ways", "kind", "kinds",
        "sort", "sorts", "matter", "fact", "facts", "case",
        "cases", "part", "parts", "side", "sides", "end", "ends",
        "form", "forms", "type", "types", "lot", "lots",
        "bit", "bits", "piece", "pieces", "place", "places",
        "time", "times", "day", "days", "year", "years",
        "moment", "moments", "point", "points",
        "person", "people", "man", "men", "woman", "women",
        "child", "children", "father", "mother", "son", "daughter",
        "good", "bad", "great", "small", "large", "long", "short",
        "high", "low", "new", "old", "young", "early", "late",
        "first", "last", "next", "best", "worst",
        "other", "others", "same", "different", "many", "few",
        "much", "more", "less", "some", "any", "all", "every",
        "own", "such", "certain",
        "general", "particular", "specific", "various",
    ]
}

// MARK: - Entity extractor

/// Wrapper around `NLTagger` for the `.nameType` scheme. Returns
/// `(canonical, displayName)` pairs for every PERSON / PLACE / ORG
/// span; the caller decides how to aggregate them.
///
/// `.joinNames` means multi-token entities ("Michel Foucault") come
/// back as a single span; `.omitPunctuation` + `.omitWhitespace`
/// strips noise tokens so the enumerator only fires on content.
public enum EntityExtractor {

    public static func extract(
        from text: String
    ) -> [(canonical: String, displayName: String)] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var out: [(String, String)] = []
        let options: NLTagger.Options = [
            .omitWhitespace, .omitPunctuation, .joinNames,
        ]
        let interesting: Set<NLTag> = [
            .personalName, .placeName, .organizationName,
        ]
        let range = text.startIndex..<text.endIndex
        tagger.enumerateTags(
            in: range, unit: .word,
            scheme: .nameType, options: options
        ) { tag, tokenRange in
            guard let tag, interesting.contains(tag),
                  tokenRange.lowerBound >= text.startIndex,
                  tokenRange.upperBound <= text.endIndex
            else { return true }
            let display = String(text[tokenRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // NLTagger sometimes emits very short spans (single
            // letters at line starts after capitalization). Drop
            // them — they're false positives and would dominate
            // the entity list with noise.
            guard display.count >= 2 else { return true }
            let canonical = display.lowercased()
            guard !canonical.isEmpty else { return true }
            out.append((canonical, display))
            return true
        }
        return out
    }
}
