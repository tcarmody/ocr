import Foundation
import LibraryIndexing

/// One paragraph picked by `SurfaceParagraphSelector.pick`. Carries
/// just enough to render the "From your library" sheet and route
/// an "Open Book" click — title / author for the header, location
/// indices for the citation line, the paragraph text for display,
/// and the catalog entry so the open path can hand off to
/// `OpenRouter`.
struct SurfacedParagraph: Sendable, Equatable {
    let libraryEntry: LibraryEntry
    let chapterIdx: Int
    let paragraphIdx: Int
    let text: String
}

/// Picks one "worth re-reading" paragraph at random from the user's
/// library — backs the Library window's sparkles button (feature
/// #11 from the "think big" brainstorm). Reads per-book embedding
/// sidecars directly rather than going through the federated index
/// because the discovery surface should work even when the library
/// chat pane hasn't been opened (i.e. the in-memory federated index
/// isn't built yet).
///
/// Selection is rejection-sample over per-book paragraphs:
///   1. pick a random catalog entry
///   2. read its sidecar (skip if missing / empty)
///   3. pick a random paragraph that has cached `text`
///   4. score it against the "worth re-reading" rubric
///   5. consult the recency-history store; skip if just surfaced
///   6. return on first match, retrying up to `maxAttempts`
///
/// The rubric (see `score`) filters out: short snippets, chapter /
/// section headers, low type-token-ratio repetition, and very long
/// wall-of-text paragraphs. Caps roughly correspond to "two- or
/// three-sentence quote-shaped passages" which is what's actually
/// re-encounterable on a button click.
enum SurfaceParagraphSelector {

    /// Try up to `maxAttempts` random picks. Returns `nil` only if
    /// the library is empty or every sampled book lacked usable
    /// paragraphs. At library scale (~2k books) the bound rarely
    /// matters — most queries find a candidate in <5 tries.
    static func pick(
        libraryEntries: [LibraryEntry],
        history: SurfaceHistoryStore,
        store: EmbeddingsSidecarStore = EmbeddingsSidecarStore(),
        maxAttempts: Int = 40,
        rng: inout SystemRandomNumberGenerator
    ) -> SurfacedParagraph? {
        guard !libraryEntries.isEmpty else { return nil }
        // Track the best-scoring candidate as a fallback so a tight
        // recency window doesn't return nil on a small library — we
        // surface the best-of-attempts even if it was shown recently.
        var bestFallback: (paragraph: SurfacedParagraph, score: Double)?

        for _ in 0..<maxAttempts {
            guard let entry = libraryEntries.randomElement(using: &rng)
            else { continue }
            guard let sidecar = store.read(
                for: entry.epubURL, libraryID: entry.id
            ) else { continue }

            let scored = sidecar.paragraphs.compactMap {
                p -> (paragraph: EmbeddingsSidecar.Entry, score: Double)? in
                guard let text = p.text else { return nil }
                let s = score(text)
                guard s > 0 else { return nil }
                return (p, s)
            }
            guard !scored.isEmpty else { continue }

            // Weight by score so high-quality paragraphs are more
            // likely to land — but use the dictionary-lookup pattern
            // instead of plain `randomElement` so a single very-high
            // candidate doesn't dominate every pick from that book.
            guard let pick = weightedChoice(scored, rng: &rng) else { continue }
            let candidate = SurfacedParagraph(
                libraryEntry: entry,
                chapterIdx: pick.paragraph.chapterIdx,
                paragraphIdx: pick.paragraph.paragraphIdx,
                text: pick.paragraph.text ?? ""
            )

            if history.isRecent(
                bookURL: entry.epubURL,
                chapterIdx: candidate.chapterIdx,
                paragraphIdx: candidate.paragraphIdx
            ) {
                // Keep the best recently-shown candidate as a
                // tiny-library fallback; otherwise reject and retry.
                if (bestFallback?.score ?? 0) < pick.score {
                    bestFallback = (candidate, pick.score)
                }
                continue
            }
            return candidate
        }
        return bestFallback?.paragraph
    }

    /// Score a paragraph's "worth re-reading" eligibility. Returns
    /// 0 when the paragraph fails any filter; otherwise returns a
    /// positive weight used by `weightedChoice` to pick among
    /// passing candidates within a book.
    ///
    /// Filters (any zeroes out the score):
    ///   • length 200–1500 chars — short snippets are usually
    ///     fragments, long ones are wall-of-text;
    ///   • doesn't open with a heading word (Chapter / Section /
    ///     Part / Figure / Table / Appendix) — those are TOC-like;
    ///   • at least two sentences (period count ≥ 2) — surfacing
    ///     a sentence fragment defeats the re-encounter goal;
    ///   • ≥ 30 word-shaped tokens — same idea, with a hard floor;
    ///   • type-token ratio ≥ 0.4 — filters out repetition-heavy
    ///     passages and OCR garbage with collapsing vocabulary.
    static func score(_ text: String) -> Double {
        let length = text.count
        guard (200...1500).contains(length) else { return 0 }

        let lowered = text.lowercased()
        let headingStarts = [
            "chapter ", "section ", "part ", "figure ",
            "table ", "appendix ", "preface", "introduction "
        ]
        if headingStarts.contains(where: { lowered.hasPrefix($0) }) {
            return 0
        }

        let periodCount = text.filter { $0 == "." }.count
        guard periodCount >= 2 else { return 0 }

        let words = text.split { !$0.isLetter }
        guard words.count >= 30 else { return 0 }

        let unique = Set(words.map { $0.lowercased() })
        let ttr = Double(unique.count) / Double(words.count)
        guard ttr >= 0.4 else { return 0 }

        // Length component: triangular, peaking near 500–1000 chars.
        let len = Double(length)
        let lengthComp: Double
        if len < 500 {
            lengthComp = len / 500
        } else if len <= 1000 {
            lengthComp = 1.0
        } else {
            lengthComp = max(0, (1500 - len) / 500)
        }
        return ttr * lengthComp
    }

    /// Weighted random pick — total-weight normalize, uniform draw,
    /// cumulative-sum lookup. Returns nil only when every element
    /// scored 0 (caller filtered those upstream, so this is mostly
    /// defensive). The dependency on the caller's RNG keeps the
    /// surface deterministic under test seeds.
    private static func weightedChoice<T>(
        _ items: [(paragraph: T, score: Double)],
        rng: inout SystemRandomNumberGenerator
    ) -> (paragraph: T, score: Double)? {
        let total = items.reduce(0.0) { $0 + $1.score }
        guard total > 0 else { return items.randomElement(using: &rng) }
        let r = Double.random(in: 0..<total, using: &rng)
        var cumulative = 0.0
        for item in items {
            cumulative += item.score
            if r < cumulative { return item }
        }
        return items.last
    }
}
