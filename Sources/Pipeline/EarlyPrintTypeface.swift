import Foundation

/// E-Vision-Modes / Early Print track. Typeface selector for the
/// Claude Sonnet early-printed-book OCR path. Material is *typeset*
/// (not handwritten) but uses period orthography that needs a
/// normalizing pass: long-s (ſ), u↔v and i↔j interchange, ligatures
/// (æ œ ﬁ ﬂ), catchwords, signature marks. Different typefaces
/// (Roman / antiqua, Blackletter / Fraktur, Italic) need different
/// recognition emphasis even though the post-processing is similar.
///
/// `auto` is the default — let the model identify the typeface and
/// transcribe. The specific cases load a tuned prompt for cases
/// where Auto isn't producing what the user expects.
///
/// Transcription posture across all sub-modes is *fluent
/// normalization*: silently modernize long-s → s, expand standard
/// ligatures, resolve u/v and i/j per modern convention. Preserve
/// period spelling otherwise (publick stays publick; phisick stays
/// phisick). Contrast with Manuscript's *diplomatic* posture which
/// preserves everything and expands abbreviations explicitly.
public enum EarlyPrintTypeface: String, CaseIterable, Sendable, Codable {
    /// Generic — let the model identify the typeface from the
    /// page and transcribe. Default; user only flips when Auto
    /// produces something off.
    case auto

    /// Roman / Antiqua — the standard early modern roman type
    /// (15th c. onward). Letterforms close to modern; long-s is
    /// the main quirk. Most early modern English, French,
    /// Italian, Spanish books use this.
    case romanAntiqua

    /// Blackletter family — Textura, Fraktur, Schwabacher. German
    /// printing (15th–19th c.), early English incunabula (Caxton).
    /// Letterforms diverge from modern Roman; eszett (ß) and
    /// umlaut handling are German-specific.
    case blackletterFraktur

    /// Italic / Cancellaresca — entire-work italic typesetting,
    /// rarer than mixed roman/italic. Same letterforms as Roman
    /// but slanted; long-s present. Often used for dedications,
    /// prefaces, or vernacular poetry.
    case italic

    /// Human-readable label for the launcher picker.
    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .romanAntiqua: return "Roman / Antiqua"
        case .blackletterFraktur: return "Blackletter / Fraktur"
        case .italic: return "Italic"
        }
    }

    /// Hand-specific instructions appended to the page-OCR system
    /// prompt. The base prompt (XHTML output schema, what to skip,
    /// reading order) and the Early Print shared conventions
    /// (normalize long-s, ligatures, u/v, i/j; skip catchwords +
    /// signature marks) come first; this block layers on the
    /// typeface-specific recognition emphasis.
    public var promptAddendum: String {
        switch self {
        case .auto: return Self.autoPrompt
        case .romanAntiqua: return Self.romanPrompt
        case .blackletterFraktur: return Self.blackletterPrompt
        case .italic: return Self.italicPrompt
        }
    }

    // MARK: - Prompt blocks

    /// Conventions shared across all Early Print sub-modes. Each
    /// specific typeface prompt incorporates these and layers on
    /// its own recognition emphasis.
    private static let sharedConventions = """
        EARLY PRINT TRANSCRIPTION POSTURE (fluent normalization):
        - Long-s (ſ): silently render as modern <em>s</em> (no marker).
        - u↔v and i↔j: silently resolve per modern convention (Iulius → Julius, vmbra → umbra, hauing → having).
        - Standard ligatures: expand silently — æ → ae, œ → oe, ﬁ → fi, ﬂ → fl. Preserve when the ligature carries semantic weight in a proper name or technical term that's typographically inseparable.
        - Preserve period spelling otherwise. Do NOT modernize "publick" to "public", "phisick" to "physic", "honour" to "honor". 17th-18th c. spelling stays.
        - Preserve period capitalization. Random Capitalization of Common Nouns is normal for 17th-18th c. English — keep it.
        - Hyphenation at line breaks: join into one word, drop the hyphen (same as the base prompt).

        UNCERTAINTY MARKERS (early-printed pages):
        - Single word you can't confidently read (worn type, broken letter, ink bleed): [?word?] with your best guess inside.
        - Word or phrase entirely unreadable: [illegible].
        - Same markers as Manuscript mode for cross-mode consistency.

        WHAT TO SKIP (early-print-specific, in addition to the base prompt's page numbers / running heads / marginalia):
        - Catchwords: the word at the bottom-right of a page that anticipates the first word of the next page. Print convention; not semantic content.
        - Signature marks: small letter/number combinations at the bottom of pages (A, A2, A3, B, B2 …) used by binders to assemble the gatherings. Skip silently.
        - Decorative initials' embellishment — transcribe the initial as a regular capital letter; ignore the decorative border.
        """

    private static let autoPrompt = """
        \(sharedConventions)

        This page is from an early-printed book (typeset, not handwritten — likely 15th–18th century European printing). Identify the typeface family and transcribe accordingly:
        - Roman / Antiqua: letterforms close to modern; long-s is the main quirk.
        - Blackletter / Fraktur: angular letterforms; pay attention to f-vs-long-s, special characters (ß for German eszett, umlauts as superscript-e or modern diacritic).
        - Italic: same letterforms as Roman but slanted; treat the same.
        - Mixed (Roman with italic emphasis): preserve the emphasis using <em>; italic for proper nouns, foreign words, technical terms is normal.

        Apply the Early Print transcription posture above (fluent normalization). Do NOT mark up the typeface in the output — the user reads modern letterforms; period typeface conventions are recognition challenges, not content to preserve.
        """

    private static let romanPrompt = """
        \(sharedConventions)

        This page is set in Roman / Antiqua type (the standard early modern roman). Letterforms are close to modern; the main recognition challenges are:
        - Long-s (ſ) appearing in every word with internal "s" before a vowel — silently normalize to s.
        - "&" as the ampersand (Tironian et): transcribe as "and" or "&" per context — within English running prose, prefer "and"; within Latin abbreviations or technical contexts, preserve "&".
        - Ligatures (æ œ ﬁ ﬂ): expand to ae, oe, fi, fl unless typographically essential.
        - Italic insertions for proper nouns / foreign words / emphasis: preserve with <em>.

        Catchwords and signature marks: skip silently.
        """

    private static let blackletterPrompt = """
        \(sharedConventions)

        This page is set in Blackletter (Textura, Fraktur, or Schwabacher) — typical of German printing 15th–19th c. and early English incunabula. Recognition challenges:
        - Distinguish long-s (ſ) from f visually: long-s lacks the crossbar; f has a horizontal crossbar.
        - Distinguish round-r (ꝛ, used after rounded letters like o, p, b) from regular r — both transcribe as "r".
        - Distinguish German eszett (ß) vs. double-s (ss) vs. long-s followed by z (ſz). Modern convention: render ß as "ß" in German contexts; "ſz" in older German typesetting → "ß"; "ſs" → "ss".
        - Umlauts may appear as superscript-e (älteren style) or as modern dot diacritic (ä ö ü) — render with modern diacritic (ä ö ü).
        - Word-final s: in some blackletter, the long-s is replaced with a short / round s at word ends. Modernize both to s.
        - Abbreviations from medieval scribal tradition that survived into early German printing (e.g. ē for "en", tilde over vowel) — expand silently in <em> per the Manuscript-style convention.

        If German: respect German capitalization (nouns capitalized — preserve).
        """

    private static let italicPrompt = """
        \(sharedConventions)

        This page is entirely or predominantly set in Italic (Cancellaresca) — less common than Roman but found in 16th–17th c. dedications, prefaces, and vernacular poetry. Recognition challenges are essentially the same as Roman:
        - Long-s present same as Roman; normalize silently to s.
        - Letterforms slanted but otherwise close to modern italic; recognition is rarely the bottleneck.
        - When the user's page mixes italic with roman: preserve the italic emphasis using <em>.

        If the WHOLE body is italic by virtue of the typesetting (poetry, dedication), do NOT wrap the whole transcription in <em> — italic-body conventions are typographic, not semantic emphasis. Use <em> only for in-context emphasis where the writer chose italic against an otherwise roman page.
        """
}
