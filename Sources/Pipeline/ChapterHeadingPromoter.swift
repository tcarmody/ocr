import Foundation
import Document

/// Pattern-based chapter-marker promotion. Runs after typography
/// normalization and before `ChapterSplitter`.
///
/// Surya's layout model classifies regions visually — chapter
/// titles set in body-size or small-caps typography (a long-
/// standing convention in mid-century academic editions, e.g. the
/// 1978 Roth & Wittich Weber translation) come back as plain
/// `.text` regions. `RegionAwareReflow` then emits them as
/// `Block.paragraph`, and `ChapterSplitter` sees zero `Block.heading`
/// blocks to break on. The documented "one chapter, all blocks"
/// fallback fires correctly, but the user gets a 1,200-page
/// single-chapter EPUB.
///
/// This promoter scans the flat block stream for paragraphs whose
/// text matches a strong chapter-marker pattern (`CHAPTER 1`,
/// `Chapter II`, `PART ONE`, `I. INTRODUCTION`, etc.), promotes
/// them to `Block.heading(level: 2, …)`, and — when the following
/// block looks like a chapter title (short, capitalized,
/// not-itself-a-marker) — fuses the two into one heading so the
/// rendered EPUB reads "CHAPTER 1: BASIC SOCIOLOGICAL TERMS"
/// instead of "CHAPTER 1" alone.
///
/// Conservative posture: every gate (length floor, marker shape,
/// non-marker neighbor) errs on the side of *not* promoting. A
/// missed promotion produces today's behavior (one chapter); a
/// false-positive promotion produces a bogus chapter break the
/// user has to fix manually. The latter is the worse failure.
public enum ChapterHeadingPromoter {

    /// Result of running the promoter. Carries diagnostics so the
    /// pipeline's debug log can record what fired and what was
    /// considered but rejected.
    public struct Result: Sendable, Equatable {
        public var blocks: [Block]
        public var diagnostics: Diagnostics

        public init(blocks: [Block], diagnostics: Diagnostics) {
            self.blocks = blocks
            self.diagnostics = diagnostics
        }
    }

    public struct Diagnostics: Sendable, Equatable {
        /// Per-promotion record: the original paragraph text + the
        /// title text consumed (if any) + the final heading text.
        public struct Promotion: Sendable, Equatable {
            public var marker: String
            public var fusedTitle: String?
            public var headingText: String

            public init(marker: String, fusedTitle: String?, headingText: String) {
                self.marker = marker
                self.fusedTitle = fusedTitle
                self.headingText = headingText
            }
        }
        public var promotions: [Promotion]
        /// Total paragraphs scanned; useful denominator for "what
        /// share of body text the promoter touched."
        public var paragraphsScanned: Int

        public init(promotions: [Promotion] = [], paragraphsScanned: Int = 0) {
            self.promotions = promotions
            self.paragraphsScanned = paragraphsScanned
        }
    }

    /// Maximum length (chars, post-trim) of a paragraph that can be
    /// considered for promotion. Real chapter markers are short —
    /// "CHAPTER XVIII" is 13 chars; even a fused "Part One: The
    /// Method of Inquiry" rarely exceeds 60. The cap defends
    /// against long body sentences that happen to start with the
    /// word "Chapter".
    public static let maxMarkerLength = 80

    /// Maximum length of the *neighbor* paragraph fused as the
    /// title. Picked separately so a long descriptive subtitle
    /// (uncommon but real, e.g. "FOUNDATIONS OF THE THEORY OF
    /// SOCIAL ACTION AND ITS RELATION TO POLITICAL ORDER") still
    /// fuses while ordinary body sentences don't.
    public static let maxFusedTitleLength = 140

    /// Same heading text repeated this many times across the
    /// document is a running-head pattern, not a chapter boundary.
    /// Matches `ChapterSplitter.maxChapterHeadingRepetition`; we
    /// gate here so we don't promote dozens of identical "CHAPTER"
    /// labels that the splitter would then strip back to paragraphs.
    public static let maxMarkerRepetition = 3

    /// Strong chapter-marker patterns. Match against the trimmed
    /// paragraph text. Patterns deliberately demand a number /
    /// numeral so a bare "Chapter" or "Part" running head doesn't
    /// false-positive.
    ///
    /// Order matters: the engine returns the first match, so the
    /// strict "CHAPTER 1\b" forms come before broader "Chapter
    /// One\b" forms. Word-spelled numerals are limited to 1–10
    /// because the pattern's purpose is finding chapter starts,
    /// not parsing every English ordinal.
    static let markerPatterns: [NSRegularExpression] = {
        let raw: [String] = [
            // "CHAPTER 1", "CHAPTER II", "CHAPTER XVIII"
            #"^CHAPTER\s+[IVXLCDM\d]+\.?$"#,
            // "Chapter 1", "Chapter II"
            #"^Chapter\s+[IVXLCDM\d]+\.?$"#,
            // "Chapter One" … "Chapter Ten" (Title-Case spelled)
            #"^Chapter\s+(One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten)\b"#,
            // "PART 1" / "PART I" / "PART ONE" (all-caps spelled too)
            #"^PART\s+([IVXLCDM\d]+|ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN)\.?$"#,
            // "Part 1" / "Part I" / "Part One"
            #"^Part\s+([IVXLCDM\d]+|One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten)\.?$"#,
            // "BOOK 1" / "BOOK I" / "Book One"
            #"^BOOK\s+([IVXLCDM\d]+|ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN)\.?$"#,
            #"^Book\s+([IVXLCDM\d]+|One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten)\.?$"#,
            // Roman-numeral prefix followed by a Title-Case word —
            // covers "I. INTRODUCTION", "II. The Method". Limit to
            // 6 chars of numeral so a body sentence "I. e. that is"
            // never matches (the `\p{Lu}` upper-case demand also
            // rules that out).
            #"^[IVXLCDM]{1,6}\.\s+\p{Lu}"#
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Walk the block stream and emit a copy with chapter-marker
    /// paragraphs promoted (and optionally fused) into headings.
    public static func promote(blocks: [Block]) -> Result {
        // Precompute the frequency map so we can skip promoting a
        // marker that recurs too often. Looking at the *promoted*
        // text rather than the bare paragraph text would race with
        // the fusion step, so we count distinct marker strings as
        // they'd appear in the heading. Conservatively, only count
        // exact paragraph-text matches against the marker regex.
        var markerFrequency: [String: Int] = [:]
        for block in blocks {
            guard case .paragraph(let runs) = block else { continue }
            let text = joined(runs).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.utf8.count <= maxMarkerLength * 4 else { continue }
            if matchesMarker(text) {
                markerFrequency[text, default: 0] += 1
            }
        }

        var out: [Block] = []
        out.reserveCapacity(blocks.count)
        var diagnostics = Diagnostics()
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            guard case .paragraph(let runs) = block else {
                out.append(block)
                index += 1
                continue
            }
            diagnostics.paragraphsScanned += 1
            let text = joined(runs).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= maxMarkerLength,
                  matchesMarker(text),
                  (markerFrequency[text] ?? 0) <= maxMarkerRepetition
            else {
                out.append(block)
                index += 1
                continue
            }

            // Look ahead for a title to fuse. Skip over anchor /
            // figure / table blocks — they're invisible to chapter
            // titling but legitimately interleaved at chapter
            // boundaries (the page-anchor "→" of the new chapter's
            // first page lands here).
            var lookahead = index + 1
            while lookahead < blocks.count {
                if case .anchor = blocks[lookahead] {
                    lookahead += 1
                } else {
                    break
                }
            }
            let fusion = candidateTitle(at: lookahead, in: blocks)

            let headingText: String
            if let fusion {
                headingText = "\(text): \(fusion.text)"
                diagnostics.promotions.append(.init(
                    marker: text, fusedTitle: fusion.text, headingText: headingText
                ))
                // Splice: emit the heading, then the anchors that
                // lived between marker + title, then advance past
                // the consumed title block.
                out.append(.heading(
                    level: 2, runs: [InlineRun(headingText)]
                ))
                if lookahead > index + 1 {
                    for j in (index + 1)..<lookahead {
                        out.append(blocks[j])
                    }
                }
                index = fusion.consumeUpTo + 1
            } else {
                headingText = text
                diagnostics.promotions.append(.init(
                    marker: text, fusedTitle: nil, headingText: text
                ))
                out.append(.heading(
                    level: 2, runs: [InlineRun(headingText)]
                ))
                index += 1
            }
        }
        return Result(blocks: out, diagnostics: diagnostics)
    }

    /// True iff `text` matches any chapter-marker pattern.
    static func matchesMarker(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in markerPatterns {
            if pattern.firstMatch(in: text, range: range) != nil {
                return true
            }
        }
        return false
    }

    /// One candidate title for the marker at `markerIndex`. Returns
    /// nil when no fusion is appropriate. `consumeUpTo` is the block
    /// index that should be skipped past once the title is consumed.
    private struct FusionCandidate {
        let text: String
        let consumeUpTo: Int
    }

    private static func candidateTitle(
        at probe: Int, in blocks: [Block]
    ) -> FusionCandidate? {
        guard probe < blocks.count else { return nil }
        guard case .paragraph(let runs) = blocks[probe] else { return nil }
        let text = joined(runs).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.count <= maxFusedTitleLength,
              looksLikeTitle(text)
        else { return nil }
        // Don't consume something that's itself a marker (would
        // leave the next chapter without its title), and don't
        // fuse two markers into one heading either.
        guard !matchesMarker(text) else { return nil }
        return FusionCandidate(text: text, consumeUpTo: probe)
    }

    /// Heuristic "this short paragraph reads like a chapter title."
    /// Looks for: starts with an uppercase letter or digit, no
    /// mid-text sentence terminator (the heading isn't a multi-
    /// sentence body fragment Surya mis-classified), and ends on a
    /// final punctuation we tolerate.
    static func looksLikeTitle(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        // Lowercase first letter = sentence tail, not a title.
        if first.isLetter && !first.isUppercase { return false }
        // Body fragments contain `". "` followed by another word.
        // Use the same offset floor as ChapterSplitter so a
        // "Vol. 1" prefix doesn't disqualify the line.
        let range = NSRange(text.startIndex..., in: text)
        let bodyTerminator = midSentenceTerminatorRegex
            .firstMatch(in: text, range: range)
        if let match = bodyTerminator,
           match.range.location >= ChapterSplitter.midSentenceTerminatorMinOffset {
            return false
        }
        return true
    }

    private static let midSentenceTerminatorRegex: NSRegularExpression = {
        // Same shape ChapterSplitter uses.
        try! NSRegularExpression(pattern: #"[.!?]\s+\p{L}"#)
    }()

    private static func joined(_ runs: [InlineRun]) -> String {
        return runs.map(\.text).joined()
    }
}
