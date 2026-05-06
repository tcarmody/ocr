import Foundation
import AppKit
import EPUB

/// Backing model for the editor's "Check Document Spelling" sheet.
/// Wraps `NSSpellChecker` for a single editor document — document
/// tag is unique per session so "Ignore" decisions don't leak
/// between books, and "Learn" goes to the user's system-wide
/// dictionary.
///
/// The session walks the editor's loaded source text, filters out
/// XHTML tag content (so attribute values and element names don't
/// generate noise), and exposes the remaining misspellings as a
/// linear cursor (`current`, `next()`, `prev()`).
///
/// **Replacements** mutate the caller's source binding via
/// `applyReplacement(_:)` returning the new text — the caller
/// (EditorViewModel) is responsible for assigning that back to
/// `sourceText`. After a replace, the session re-scans so any
/// downstream range shifts are absorbed.
@MainActor
final class SpellCheckSession: ObservableObject {

    /// Position of one misspelled word in the source text. Range is
    /// in NSString-compatible UTF-16 units (since NSSpellChecker
    /// returns `NSRange`); the caller is responsible for converting
    /// to Swift String indices when applying replacements.
    struct Misspelling: Identifiable, Equatable {
        let id = UUID()
        var word: String
        var range: NSRange
        var suggestions: [String]
        /// ~30 chars before / after `range` for the panel's
        /// "in context" display. Substituted whitespace runs are
        /// collapsed to single spaces for readability.
        var contextBefore: String
        var contextAfter: String
    }

    @Published private(set) var misspellings: [Misspelling] = []
    /// Index into `misspellings` for whichever entry the panel is
    /// currently showing. When `>= misspellings.count`, the panel
    /// shows "no more misspellings."
    @Published private(set) var currentIndex: Int = 0

    /// `NSSpellChecker` document tag — keeps "Ignore" decisions
    /// scoped to this session.
    private let documentTag: Int

    /// Words the user has explicitly ignored this session. NSSpellChecker
    /// does this via `ignoreWord(_:inSpellDocumentWithTag:)` but the
    /// list is opaque from Swift; we keep our own copy so the
    /// re-scan after replacements drops them.
    private var ignored: Set<String> = []

    init() {
        self.documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    }

    deinit {
        // Releasing the document tag isn't required — NSSpellChecker
        // tags are integers and the cleanup is for memory hygiene
        // around the spell server's per-document state. Off the
        // main actor on dealloc is also fine.
        NSSpellChecker.shared.closeSpellDocument(withTag: documentTag)
    }

    /// True when there's a current misspelling to act on. Drives
    /// the sheet's button enable state.
    var hasCurrent: Bool {
        currentIndex < misspellings.count
    }

    /// Misspelling currently shown to the user (or nil when the
    /// session has been exhausted).
    var current: Misspelling? {
        guard hasCurrent else { return nil }
        return misspellings[currentIndex]
    }

    /// Total misspellings the session detected on its most recent
    /// scan, for the "Word X of Y" counter.
    var totalCount: Int { misspellings.count }

    /// Start a fresh session against `text`. Walks the source,
    /// filters tag content, and populates the misspellings list.
    func scan(text: String) {
        misspellings = Self.findMisspellings(
            in: text,
            ignoring: ignored,
            documentTag: documentTag
        )
        currentIndex = 0
    }

    /// Advance the cursor without changing the text. Used by
    /// "Skip" and after a successful replace (where we re-scan and
    /// stay at index 0 — the just-fixed misspelling drops out).
    func advance() {
        currentIndex = min(currentIndex + 1, misspellings.count)
    }

    /// Tell `NSSpellChecker` to ignore future occurrences of the
    /// current word in *this* session, then advance the cursor and
    /// drop other instances of the same word from the list. Doesn't
    /// touch the user's system-wide dictionary.
    func ignoreCurrent() {
        guard let word = current?.word else { return }
        NSSpellChecker.shared.ignoreWord(
            word, inSpellDocumentWithTag: documentTag
        )
        ignored.insert(word.lowercased())
        // Drop matching entries from the remaining list so the user
        // doesn't have to skip them one by one.
        let kept = misspellings.enumerated().compactMap { (i, m) -> Misspelling? in
            if i < currentIndex { return m }
            return m.word.lowercased() == word.lowercased() ? nil : m
        }
        misspellings = kept
        // Don't bump currentIndex — the next misspelling has slid
        // into the slot we were already looking at.
    }

    /// Add the current word to the user's system-wide dictionary
    /// via `NSSpellChecker.learnWord`, then advance.
    func learnCurrent() {
        guard let word = current?.word else { return }
        NSSpellChecker.shared.learnWord(word)
        // Same drop-rest logic as ignore — once "Learn"-ed, the
        // word will pass on re-scan anyway, but skipping ahead
        // avoids a re-scan round trip.
        let kept = misspellings.enumerated().compactMap { (i, m) -> Misspelling? in
            if i < currentIndex { return m }
            return m.word.lowercased() == word.lowercased() ? nil : m
        }
        misspellings = kept
    }

    /// Apply `replacement` to the current misspelling's range
    /// against `text`, returning the updated string. After the
    /// caller assigns the new text back to its source buffer, it
    /// should call `scan(text:)` again to refresh the misspelling
    /// list (the replacement shifts subsequent ranges).
    func applyReplacement(
        _ replacement: String, to text: String
    ) -> String? {
        guard let misspelling = current else { return nil }
        let nsText = text as NSString
        guard misspelling.range.location + misspelling.range.length
            <= nsText.length else { return nil }
        let updated = nsText.replacingCharacters(
            in: misspelling.range, with: replacement
        )
        return updated
    }

    // MARK: - Static scan

    /// NSSpellChecker the source for misspellings outside XHTML
    /// tag contents. Uses the same `inTag` walker as `SmartQuoter`
    /// to decide which character ranges count as "text" — attribute
    /// values, element names, doctype, processing instructions all
    /// stay out of the candidate set.
    static func findMisspellings(
        in text: String,
        ignoring: Set<String>,
        documentTag: Int
    ) -> [Misspelling] {
        let checker = NSSpellChecker.shared
        let textRanges = textOnlyRanges(in: text)
        let nsText = text as NSString
        var out: [Misspelling] = []
        for range in textRanges {
            // `check(...)` runs the multi-stage checker; we only
            // want spelling errors here, not grammar / style
            // detections (which the spell sheet doesn't surface).
            let results = checker.check(
                nsText.substring(with: range),
                range: NSRange(location: 0, length: range.length),
                types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                options: nil,
                inSpellDocumentWithTag: documentTag,
                orthography: nil,
                wordCount: nil
            )
            for result in results {
                // Translate the segment-relative range back into
                // absolute coordinates against the full source.
                let absoluteRange = NSRange(
                    location: range.location + result.range.location,
                    length: result.range.length
                )
                guard absoluteRange.location + absoluteRange.length <= nsText.length
                else { continue }
                let word = nsText.substring(with: absoluteRange)
                if ignoring.contains(word.lowercased()) { continue }
                let suggestions = checker.guesses(
                    forWordRange: absoluteRange,
                    in: text,
                    language: nil,
                    inSpellDocumentWithTag: documentTag
                ) ?? []
                let (before, after) = contextSnippets(
                    in: nsText, around: absoluteRange
                )
                out.append(Misspelling(
                    word: word,
                    range: absoluteRange,
                    suggestions: suggestions,
                    contextBefore: before,
                    contextAfter: after
                ))
            }
        }
        return out
    }

    /// Walk the source and emit ranges that lie *outside* tags. A
    /// tag opens at `<` and closes at the matching `>` — the
    /// XML / XHTML the editor produces never has raw `<` or `>` in
    /// attribute values, so the simple alternation suffices.
    static func textOnlyRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        var ranges: [NSRange] = []
        var inTag = false
        var segmentStart = 0
        for i in 0..<nsText.length {
            let ch = nsText.character(at: i)
            if inTag {
                if ch == 0x3E {  // '>'
                    inTag = false
                    segmentStart = i + 1
                }
            } else {
                if ch == 0x3C {  // '<'
                    if i > segmentStart {
                        ranges.append(NSRange(
                            location: segmentStart,
                            length: i - segmentStart
                        ))
                    }
                    inTag = true
                }
            }
        }
        if !inTag, segmentStart < nsText.length {
            ranges.append(NSRange(
                location: segmentStart,
                length: nsText.length - segmentStart
            ))
        }
        return ranges
    }

    /// 30 characters before and after `range` in `nsText`, with
    /// internal whitespace collapsed. Used by the spell sheet's
    /// "in context" display so the user can see where the
    /// misspelling lives without having to scroll the editor.
    static func contextSnippets(
        in nsText: NSString, around range: NSRange
    ) -> (before: String, after: String) {
        let span = 30
        let beforeStart = max(0, range.location - span)
        let beforeRange = NSRange(
            location: beforeStart,
            length: range.location - beforeStart
        )
        let after = range.location + range.length
        let afterEnd = min(nsText.length, after + span)
        let afterRange = NSRange(
            location: after,
            length: afterEnd - after
        )
        let beforeRaw = beforeRange.length > 0
            ? nsText.substring(with: beforeRange) : ""
        let afterRaw = afterRange.length > 0
            ? nsText.substring(with: afterRange) : ""
        let collapse: (String) -> String = { s in
            s.replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression
            )
        }
        return (collapse(beforeRaw), collapse(afterRaw))
    }
}
