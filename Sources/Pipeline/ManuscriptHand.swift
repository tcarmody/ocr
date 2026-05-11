import Foundation

/// E-Vision-Modes / Manuscript track. Hand-family selector for the
/// Claude Opus manuscript-OCR path. Each case bundles a script
/// style + a transcription policy + uncertainty conventions into
/// one user-facing choice — the alternative ("pick a script" +
/// "pick a transcription style" as two separate menus) is more
/// flexible but more UI for marginal value at v1.
///
/// `auto` is the default the launcher offers when Manuscript mode
/// is on but the user hasn't picked a specific hand. The prompt
/// names the four common families and asks the model to identify +
/// transcribe whichever it sees.
///
/// Coverage scope: early-modern + modern Europe, Latin scripts. The
/// design space for paleography is much larger (Caroline,
/// Insular, Beneventan, Kurrent / Sütterlin for German tradition,
/// non-Latin scripts entirely) but the immediate testing need
/// limits us to four well-bounded sub-modes. Adding hand families
/// later is a prompt-only change.
public enum ManuscriptHand: String, CaseIterable, Sendable, Codable {
    /// Generic manuscript prompt — let the model identify the hand
    /// and transcribe accordingly. Best default; user only flips
    /// to a specific hand when this produces something off.
    case auto

    /// 16th–17th c. English/Continental secretary hand —
    /// administrative records, legal documents, correspondence.
    /// Diplomatic transcription posture: preserve original
    /// spelling, mark abbreviation expansions in italics, flag
    /// long-s / i-j / u-v ambiguity.
    case diplomatic

    /// 18th c. round hand / English roundhand (copperplate) —
    /// formal letters, engraved-source manuscripts. Regular
    /// letterforms; preserve period spelling + idiosyncratic
    /// capitalization.
    case roundHand

    /// 19th–early 20th c. cursive — correspondence, diaries,
    /// journals. Variable per writer; modern spelling. Light-
    /// touch normalization; preserve crossings-out.
    case cursive

    /// Modern handwritten notes (20th–21st c.). Mixed print +
    /// cursive common; idiosyncratic abbreviations; reading-
    /// friendly output.
    case contemporaryInformal

    /// Human-readable label for the launcher picker.
    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .diplomatic: return "Diplomatic (16th–17th c. secretary)"
        case .roundHand: return "Round hand (18th c. copperplate)"
        case .cursive: return "Cursive (19th–early 20th c.)"
        case .contemporaryInformal: return "Contemporary informal"
        }
    }

    /// Hand-specific instructions appended to the page-OCR system
    /// prompt. The base prompt (XHTML output schema, what to skip,
    /// reading order) stays shared with the typeset path; this
    /// block layers on the manuscript-specific transcription
    /// policy.
    public var promptAddendum: String {
        switch self {
        case .auto:
            return Self.autoPrompt
        case .diplomatic:
            return Self.diplomaticPrompt
        case .roundHand:
            return Self.roundHandPrompt
        case .cursive:
            return Self.cursivePrompt
        case .contemporaryInformal:
            return Self.contemporaryPrompt
        }
    }

    // MARK: - Prompt blocks

    /// Conventions shared across all manuscript sub-modes. Each
    /// specific prompt incorporates these baseline conventions and
    /// layers on its own period / script / policy details.
    private static let sharedConventions = """
        UNCERTAINTY MARKERS (manuscript pages):
        - Single word you can't confidently read: [?word?] with your best guess inside.
        - Word or phrase entirely unreadable: [illegible].
        - Editorial expansion of an abbreviation: render the expanded form in <em> tags.

        Preserve manuscript line breaks within paragraphs ONLY when the writer's intent is verse / structured list; otherwise reflow to paragraph prose.
        Marginalia, interlinear additions, struck-through text: include in reading order with a brief inline note in italics describing position (e.g. <em>[interlinear: above "word"]</em>) when the position matters.
        """

    private static let autoPrompt = """
        \(sharedConventions)

        This page is a manuscript (handwritten). Common hand families to expect: 16th–17th c. secretary; 18th c. round hand / copperplate; 19th–early 20th c. cursive; modern informal. Identify the hand family from the script style, then transcribe accordingly:
        - Pre-1700 hands: preserve original spelling exactly. Expand common abbreviations using <em>, e.g. ye → <em>the</em>, wᶜʰ → <em>which</em>, q̃ → <em>quoque</em>.
        - 18th c. round hand: preserve period spelling and idiosyncratic capitalization (capitalization of common nouns is normal for the era).
        - 19th c. onward: spelling generally matches modern English / European norms; preserve as-written; no expansion needed.
        - Letter ambiguity (long-s vs f, i vs j, u vs v): resolve to modern letter forms in the transcription. Note edge cases with [?].
        """

    private static let diplomaticPrompt = """
        \(sharedConventions)

        This page is a 16th–17th century manuscript in English secretary hand (or continental cursive Gothic). Adopt a diplomatic transcription posture:
        - Preserve original spelling EXACTLY. Do not modernize. (you/yu, an'/and, &/and all stay as written)
        - Preserve capitalization as written.
        - Expand common scribal abbreviations using <em> for the expanded form: ye → <em>the</em>, yᵗ → <em>that</em>, wᶜʰ → <em>which</em>, ꝑ (p with stroke) → <em>per</em>, ꝓ → <em>pro</em>, tilde over vowel → restored <em>n</em>/<em>m</em>, q̃ → <em>quoque</em>, etc.
        - Long-s (ſ): transcribe as <em>s</em> (modern form). f vs long-s confusion: lean on context, mark [?s?] or [?f?] when ambiguous.
        - i/j and u/v are typically interchangeable in this period: render as modern usage (Iulius → Julius) silently; note edge cases with [?].
        - Brevigraphs (& for "and", ⁊ for "and"): transcribe as the modern word.
        - Thorn (þ) and y-thorn (ye for the): treat ye as <em>the</em> when context makes "the" clear; preserve y when context demands.
        """

    private static let roundHandPrompt = """
        \(sharedConventions)

        This page is an 18th century round hand (English copperplate / engraver-influenced cursive). Letterforms are highly regular; abbreviations are uncommon. Transcription posture:
        - Preserve original spelling. Period spelling has minor differences from modern (e.g. publick → publick, not modernize to public; honour, colour stay British).
        - Preserve idiosyncratic capitalization (Nouns are commonly Capitalized in the period; do not modernize).
        - Few or no abbreviations to expand — if you encounter one, use <em>.
        - Apostrophes: 18th c. usage of "'d" for "-ed" endings (e.g. "join'd") is normal; preserve.
        """

    private static let cursivePrompt = """
        \(sharedConventions)

        This page is 19th or early 20th century cursive (correspondence, diary, journal). Letterforms vary by writer; spelling generally modern. Transcription posture:
        - Preserve original spelling — but spelling at this period mostly matches modern norms.
        - Preserve crossings-out using markdown strikethrough syntax (~~struck text~~).
        - Insertions (above the line, in the margin with a caret) — incorporate in place with an italic note: <em>[inserted above]</em> if the position matters; otherwise just splice them in.
        - Light-touch normalization: no need to mark expansion of common abbreviations like Mr., Mrs., Dr. — these are unambiguous.
        """

    private static let contemporaryPrompt = """
        \(sharedConventions)

        This page is modern handwritten notes (20th–21st century). Letterforms vary widely by writer — mix of print and cursive within a single page is common. Transcription posture:
        - Reading-friendly output. Spelling matches modern norms; preserve as-written but don't bother flagging trivial misspellings.
        - Personal shorthand (w/ for with, b/c for because, the writer's own abbreviations): transcribe verbatim — the user knows their own shorthand.
        - Bullet points, dashes, indentation: preserve structurally as Markdown-equivalent (- for bullets, etc.).
        - Skip page numbers, dates in the margin used as bookkeeping (unless they're load-bearing for the content).
        """
}
