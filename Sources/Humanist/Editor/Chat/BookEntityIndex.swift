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
struct BookEntityIndex: Sendable, Codable, Equatable {

    /// One paragraph anchor — mirrors the embedding sidecar's
    /// (chapterIdx, paragraphIdx) tuple so a hit can be projected
    /// onto the same paragraph identity space the cosine path uses.
    struct Anchor: Sendable, Codable, Equatable, Hashable {
        let chapterIdx: Int
        let paragraphIdx: Int
    }

    /// Canonical (lowercased, whitespace-trimmed) entity name →
    /// every anchor that mentions it. Sorted within the array by
    /// (chapterIdx, paragraphIdx) for deterministic output.
    let mentions: [String: [Anchor]]
    /// Canonical name → best display-cased form we saw. Used by
    /// the retriever to label entity hits and by the alias-
    /// dictionary editor (planned) to show users what's there.
    let displayNames: [String: String]

    static let empty = BookEntityIndex(mentions: [:], displayNames: [:])

    init(mentions: [String: [Anchor]], displayNames: [String: String]) {
        self.mentions = mentions
        self.displayNames = displayNames
    }

    // MARK: - Building

    /// Walk every paragraph in the book, run NER on each, and
    /// aggregate by canonical name. Sequential — NLTagger is fast
    /// enough that a 1500-paragraph book completes in seconds, and
    /// the build sits inside the existing embedding-build task so
    /// it doesn't add to perceived latency.
    static func build(from book: EPUBBook) -> BookEntityIndex {
        let items = ParagraphExtractor.extract(from: book)
        var mentions: [String: [Anchor]] = [:]
        var displayNames: [String: String] = [:]
        for item in items {
            let pairs = EntityExtractor.extract(from: item.text)
            for (canonical, displayName) in pairs {
                let anchor = Anchor(
                    chapterIdx: item.chapterIdx,
                    paragraphIdx: item.paragraphIdx
                )
                // Avoid duplicating the same anchor for repeated
                // mentions of an entity within one paragraph —
                // cheap dedup via last-anchor check (paragraphs
                // walk in order, so duplicates land contiguously).
                if mentions[canonical]?.last != anchor {
                    mentions[canonical, default: []].append(anchor)
                }
                // Prefer the longer / more-cased display form. The
                // second pass ("Foucault" vs "Michel Foucault")
                // wins when its capitalized-letter count is higher;
                // ties go to the first-seen form.
                let existing = displayNames[canonical] ?? ""
                if Self.scoreDisplay(displayName) > Self.scoreDisplay(existing) {
                    displayNames[canonical] = displayName
                }
            }
        }
        return BookEntityIndex(
            mentions: mentions,
            displayNames: displayNames
        )
    }

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
    func entitiesMatching(query: String) -> [String] {
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
    func anchors(for canonical: String) -> [Anchor] {
        mentions[canonical] ?? []
    }
}

// MARK: - Entity extractor

/// Wrapper around `NLTagger` for the `.nameType` scheme. Returns
/// `(canonical, displayName)` pairs for every PERSON / PLACE / ORG
/// span; the caller decides how to aggregate them.
///
/// `.joinNames` means multi-token entities ("Michel Foucault") come
/// back as a single span; `.omitPunctuation` + `.omitWhitespace`
/// strips noise tokens so the enumerator only fires on content.
enum EntityExtractor {

    static func extract(
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
