import Foundation
import AppKit
import NaturalLanguage

/// Post-OCR dictionary-match cleanup. Walks each region's joined
/// text, finds words that aren't in the language's dictionary, and
/// when there's an unambiguous Levenshtein-1 candidate that **is**
/// in the dictionary, applies it. Catches the bulk of "obvious"
/// scanner-noise garblings — `thc` → `the`, `Engiish` → `English` —
/// for free.
///
/// **Conditional execution.** Today's pipeline runs this pass only
/// when no language-model post-OCR cleanup is available (Private
/// mode without AFM, or Cloud mode with the cleanup toggle off and
/// no AFM fallback). When Haiku post-OCR cleanup or AFM cleanup
/// will run, the pipeline skips this pass entirely — the LM-based
/// passes handle the same garblings with much better context
/// awareness and don't carry the false-positive risk on foreign
/// cognates. The gating lives in `PDFToEPUBPipeline.assembleBook`.
///
/// **Multi-language via NSSpellChecker.** macOS ships spelling
/// dictionaries for English, French, Italian, Spanish, Portuguese,
/// Catalan, German (and many more). We use those rather than
/// bundling our own wordlists. Per-region language hint comes from
/// `NLLanguageRecognizer`; falls back to the document's primary
/// language for short / ambiguous regions, and to "skip this region"
/// when neither resolves to a supported BCP-47 code.
///
/// **Conservative correction policy.** Eight guards keep the pass
/// from damaging proper nouns, technical terms, and foreign words:
/// 1. Only attempt on Latin-script tokens. Greek / Hebrew / Arabic /
///    Cyrillic / CJK words are skipped entirely (their
///    correction would need a different dictionary).
/// 2. Only apply when the top suggestion is Levenshtein distance 1
///    from the original (single-character typo). Distance 2+
///    is usually genuine OCR garbage that needs Sonnet anyway.
/// 3. Skip words shorter than 3 characters and words with
///    embedded digits or punctuation (URLs, model numbers).
/// 4. Skip uppercase-initial non-sentence-start words (likely
///    proper nouns).
/// 5. Skip when the word is valid in any other installed European
///    NSSpellChecker dictionary (French, Italian, German, etc.).
/// 6. Skip when the word matches a bundled Latin or transliterated-
///    Greek classical-vocabulary list (covers the gap left by
///    macOS not shipping Latin / Greek-in-Latin dictionaries).
/// 7. Apply only when the single edit matches a known scanner-
///    confusion pattern (c↔e, i↔l, u↔n, o↔c, b↔h, r↔n, m↔n, or
///    a doubled-letter insertion/deletion). Foreign-cognate near-
///    matches don't typically match these patterns, so this gate
///    blocks them surgically.
///
/// Casing is preserved when applying — `Thc` → `The`, `THC` → `THE`.
public struct DictionaryCorrector: Sendable {

    /// Languages we have NSSpellChecker dictionaries for on macOS.
    /// Used to filter out detected languages without coverage so we
    /// don't pass nonsense codes to the spell server.
    public static let supportedLanguages: Set<String> = [
        "en", "fr", "it", "es", "pt", "ca", "de",
    ]

    /// Document's primary language (from `DocumentProfile`). Used as
    /// the fallback when per-region detection is too short to be
    /// confident.
    public var documentLanguage: String?

    public init(documentLanguage: String?) {
        // Normalize to primary subtag (`en-US` → `en`) so the
        // language-coverage lookup matches.
        self.documentLanguage = documentLanguage.map(Self.primarySubtag)
    }

    /// Apply the dictionary pass to `text`. Returns the corrected
    /// string. Languages outside `supportedLanguages` produce a
    /// pass-through (no NSSpellChecker call) so we don't damage
    /// non-supported text.
    public func correct(_ text: String, languageHint: String? = nil) -> String {
        let language = Self.resolveLanguage(
            hint: languageHint,
            documentLanguage: documentLanguage,
            text: text
        )
        guard let language, Self.supportedLanguages.contains(language) else {
            return text
        }

        let nsText = text as NSString
        guard nsText.length > 0 else { return text }

        let checker = NSSpellChecker.shared
        let documentTag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: documentTag) }

        // Single full-text check, same shape as `SpellCheckSession`.
        // NSSpellChecker treats `<` `>` `"` etc. as word boundaries
        // so the tokenizer is fine on raw OCR strings.
        let results = checker.check(
            text,
            range: NSRange(location: 0, length: nsText.length),
            types: NSTextCheckingResult.CheckingType.spelling.rawValue,
            options: [.orthography: makeOrthography(language: language)],
            inSpellDocumentWithTag: documentTag,
            orthography: nil,
            wordCount: nil
        )

        // Apply corrections in reverse order so earlier ranges
        // don't shift under us.
        let working = nsText.mutableCopy() as! NSMutableString
        for result in results.reversed() {
            guard let correction = correctionFor(
                range: result.range,
                in: text,
                checker: checker,
                language: language,
                documentTag: documentTag
            ) else { continue }
            working.replaceCharacters(in: result.range, with: correction)
        }
        return working as String
    }

    // MARK: - Per-misspelling decision

    /// Decide whether to auto-correct a single misspelling. Returns
    /// the replacement string when all guards pass, or `nil` to
    /// leave the original alone.
    func correctionFor(
        range: NSRange,
        in text: String,
        checker: NSSpellChecker,
        language: String,
        documentTag: Int
    ) -> String? {
        let nsText = text as NSString
        guard range.location + range.length <= nsText.length else { return nil }
        let word = nsText.substring(with: range)

        // Guard 1: Latin script only. Non-Latin tokens go to a
        // dictionary we don't have — skip rather than damage.
        guard Self.isLatinScript(word) else { return nil }

        // Guard 2: Length floor. Two-letter "words" are unstable —
        // `tc`, `it`, `to` flip too easily to be safe corrections.
        guard word.count >= 3 else { return nil }

        // Guard 3: Letter-only check. Mixed-content tokens (URLs,
        // model numbers, prices) shouldn't be in the wordlist
        // anyway, and trying to "correct" them produces nonsense.
        guard Self.isLetterOnly(word) else { return nil }

        // Get suggestions. NSSpellChecker.guesses is per-call IPC,
        // but we only hit it for misspellings — already-correct
        // words don't appear in `results`.
        let suggestions = checker.guesses(
            forWordRange: range,
            in: text,
            language: language,
            inSpellDocumentWithTag: documentTag
        ) ?? []
        guard let top = suggestions.first else { return nil }

        // Guard 4: Levenshtein distance must be exactly 1 — single
        // typo. Distance 2+ is usually genuine OCR damage; let
        // Haiku handle that. (Reuses OCRChangeGuardrail's helper.)
        let distance = OCRChangeGuardrail.levenshtein(
            word.lowercased(), top.lowercased()
        )
        guard distance == 1 else { return nil }

        // Guard 5: capitalization sanity. If the original starts
        // with an uppercase letter and isn't sentence-initial, it's
        // probably a proper noun the dictionary doesn't have — skip.
        // (We can't see context here so we use the simpler rule of
        // "not all-caps and not lowercase" → conservative skip.)
        if word.first?.isUppercase == true,
           !word.allSatisfy({ $0.isUppercase || !$0.isLetter }) {
            return nil
        }

        // Guard 5 (Q-Italic-Skip, 2026-05-12): cross-language
        // validity. Vision/Tesseract paths often emit italicized
        // foreign words inside an otherwise-English paragraph as
        // a single run with no italic flag, so the per-run
        // isItalic gate upstream can't protect them. Before
        // applying an English (etc.) correction, check whether
        // the *original* word is a valid word in any of the other
        // supported European-language dictionaries. If it is,
        // skip — the safer assumption is "this is a foreign term,
        // not a misspelling of the active language."
        //
        // This catches things like Italian "vita" / "morte",
        // German "die" / "der" / "das", French "thé" / "très",
        // Latin/Portuguese "deus" inside English prose. The cost
        // is six NSSpellChecker calls per candidate (microseconds
        // each); negligible at book scale.
        if Self.isValidInOtherSupportedLanguage(
            word: word, activeLanguage: language,
            checker: checker, documentTag: documentTag
        ) {
            return nil
        }

        // Guard 6: bundled classical wordlists. macOS doesn't
        // ship a Latin dictionary, and Greek-in-Latin-letter
        // transliteration (logos, polis, kairos, …) isn't in any
        // European dictionary. Without these lists, common
        // academic-English borrowings get "corrected" to a
        // nearby English word — `kairos` → `karras` and similar
        // gibberish. The lists are small starter sets; users can
        // extend them by editing the static arrays below.
        if Self.isClassicalVocabulary(word: word) {
            return nil
        }

        // Guard 7: OCR-confusion-pattern gate. Real scanner
        // errors fit a known fingerprint — c↔e (open vs closed),
        // i↔l (thin verticals), u↔n (inverted), o↔c, b↔h, r↔n,
        // m↔n, or a doubled-letter insertion/deletion (`wel` →
        // `well`, `thaat` → `that`). Foreign-cognate near-matches
        // almost never fit these patterns: French `salade` →
        // English `salads` is an `e→s` substitution; German
        // `Haus` → `haul` is `s→l`. Requiring the single edit to
        // match a known confusion blocks those cases surgically
        // without bundling per-language dictionaries.
        if !Self.isOCRConfusionEdit(original: word, candidate: top) {
            return nil
        }

        // Apply case to the suggestion to match the original.
        return Self.matchCase(of: word, target: top)
    }

    /// Return true when `word` looks like classical-academic
    /// vocabulary the corrector should leave alone. Two paths:
    ///   * **Latin via stem-prefix match** against Whitaker's
    ///     Words (~31K stems). Catches inflected forms like
    ///     `amicitia` via stem `amici`. Length floors on both
    ///     word and stem keep short English words from spuriously
    ///     matching short Latin function-word stems.
    ///   * **Greek-in-Latin transliteration via exact match**
    ///     against a curated inline list. Greek borrowings that
    ///     are already in English dictionaries (ethos / pathos
    ///     / polis) pass through; the list covers the academic
    ///     tail that NSSpellChecker English flags.
    static func isClassicalVocabulary(word: String) -> Bool {
        if isLatinByStemPrefix(word: word) { return true }
        let lowered = word.lowercased()
        return greekTransliterationWords.contains(lowered)
    }

    /// Type of single edit between two strings at Levenshtein
    /// distance 1.
    enum EditType {
        case substitution
        case insertion  // candidate has one more char than original
        case deletion   // candidate has one fewer char
    }

    /// Identify the single edit between `a` and `b` when their
    /// Levenshtein distance is exactly 1. Returns nil for any
    /// other case (equal strings, distance ≥ 2). The position is
    /// 0-indexed in the shorter string for substitution, in the
    /// longer string for insertion / deletion.
    static func diffAtDistanceOne(
        a: String, b: String
    ) -> (type: EditType, position: Int, char: Character)? {
        let aChars = Array(a)
        let bChars = Array(b)
        // Common prefix.
        var prefix = 0
        while prefix < aChars.count, prefix < bChars.count,
              aChars[prefix] == bChars[prefix] {
            prefix += 1
        }
        // Common suffix.
        var suffix = 0
        while suffix < (aChars.count - prefix),
              suffix < (bChars.count - prefix),
              aChars[aChars.count - 1 - suffix]
                == bChars[bChars.count - 1 - suffix] {
            suffix += 1
        }
        let aRemain = aChars.count - prefix - suffix
        let bRemain = bChars.count - prefix - suffix
        switch (aRemain, bRemain) {
        case (1, 1):
            return (.substitution, prefix, bChars[prefix])
        case (0, 1):
            return (.insertion, prefix, bChars[prefix])
        case (1, 0):
            return (.deletion, prefix, aChars[prefix])
        default:
            return nil
        }
    }

    /// Return true when the single edit between `original` and
    /// `candidate` matches a known OCR scanner confusion. Called
    /// only after Guard 4 has confirmed Levenshtein distance 1.
    /// Three sub-cases — see the doc comment on the corrector for
    /// the design rationale.
    static func isOCRConfusionEdit(
        original: String, candidate: String
    ) -> Bool {
        let oLower = original.lowercased()
        let cLower = candidate.lowercased()
        guard let diff = diffAtDistanceOne(a: oLower, b: cLower)
        else { return false }
        switch diff.type {
        case .substitution:
            let origChar = Array(oLower)[diff.position]
            return confusableLetterPairs.contains(
                [origChar, diff.char]
            )
        case .insertion:
            // Insertion is only accepted when the inserted char
            // would duplicate an adjacent char in `candidate` —
            // i.e. the OCR'd word dropped one half of a doubled
            // letter (`wel` → `well`, `acros` → `across`).
            let cArr = Array(cLower)
            let pos = diff.position
            let left  = pos > 0              ? cArr[pos - 1] : nil
            let right = pos + 1 < cArr.count ? cArr[pos + 1] : nil
            return left == diff.char || right == diff.char
        case .deletion:
            // Symmetric: the deleted char must have been part of
            // a doubled pair in `original` (`thaat` → `that`).
            let oArr = Array(oLower)
            let pos = diff.position
            let left  = pos > 0              ? oArr[pos - 1] : nil
            let right = pos + 1 < oArr.count ? oArr[pos + 1] : nil
            return left == diff.char || right == diff.char
        }
    }

    /// Known scanner-confusion letter pairs. Curated tight:
    /// includes only pairs that are visually confusable in
    /// modern print at typical OCR DPI and that don't carry a
    /// high cognate-flip risk. Each pair is recorded in both
    /// directions because the original may be either of the two.
    /// Notably absent: (a, o) [Romance gender flips], (f, t)
    /// [German "fest" vs English "test"], anything involving
    /// digits [Guard 3 already excludes digit-bearing tokens].
    static let confusableLetterPairs: Set<[Character]> = [
        ["c", "e"], ["e", "c"],
        ["i", "l"], ["l", "i"],
        ["u", "n"], ["n", "u"],
        ["o", "c"], ["c", "o"],
        ["b", "h"], ["h", "b"],
        ["r", "n"], ["n", "r"],
        ["m", "n"], ["n", "m"],
    ]

    /// Return true when `word` is correctly spelled in any of the
    /// supported languages other than `activeLanguage`. Used as
    /// the cross-language skip-guard above so legitimate foreign
    /// words don't get "corrected" to similar-shape words in the
    /// active language.
    ///
    /// Important: only checks languages that NSSpellChecker
    /// actually has dictionaries for on this machine. Calling
    /// `checkSpelling(of:language:…)` with a tag whose dictionary
    /// isn't installed appears to silently fall back to a
    /// permissive default that flags very little as misspelled,
    /// which would make this guard refuse legitimate corrections
    /// (e.g. "xqzwk" validates against an absent dictionary).
    /// Intersecting `supportedLanguages` with
    /// `checker.availableLanguages` (normalized to primary
    /// subtags) keeps the check honest.
    static func isValidInOtherSupportedLanguage(
        word: String,
        activeLanguage: String,
        checker: NSSpellChecker,
        documentTag: Int
    ) -> Bool {
        let lowercased = word.lowercased()
        let installed = Set(
            checker.availableLanguages.map(primarySubtag)
        )
        for lang in supportedLanguages
        where lang != activeLanguage && installed.contains(lang) {
            let range = checker.checkSpelling(
                of: lowercased,
                startingAt: 0,
                language: lang,
                wrap: false,
                inSpellDocumentWithTag: documentTag,
                wordCount: nil
            )
            // NSNotFound location ⇒ spell check did not flag a
            // misspelling ⇒ word is valid in this language.
            if range.location == NSNotFound { return true }
        }
        return false
    }

    // MARK: - Language resolution

    /// Pick the language to use for this text. Order:
    ///   1. Explicit per-region hint from the caller (NLR-derived).
    ///   2. NLR run on the text directly when long enough to be
    ///      confident.
    ///   3. The document's primary language as the fallback.
    ///
    /// Always filters the result through `supportedLanguages` —
    /// returns nil rather than a language we don't have a
    /// dictionary for, so the caller's pass-through behavior
    /// kicks in for Greek / Hebrew / Latin / etc. instead of
    /// trying to "correct" them with the wrong dictionary.
    static func resolveLanguage(
        hint: String?,
        documentLanguage: String?,
        text: String
    ) -> String? {
        if let hint = hint.map(primarySubtag),
           supportedLanguages.contains(hint) {
            return hint
        }
        // Try NLR on the text. Below ~80 chars NLR's confidence is
        // typically too low to trust over the document hint.
        if text.count >= 80 {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            if let detected = recognizer.dominantLanguage?.rawValue {
                let primary = primarySubtag(detected)
                if supportedLanguages.contains(primary) {
                    let confidence = recognizer
                        .languageHypotheses(withMaximum: 5)[
                            recognizer.dominantLanguage!
                        ] ?? 0
                    if confidence >= 0.7 { return primary }
                }
            }
        }
        if let doc = documentLanguage,
           supportedLanguages.contains(doc) {
            return doc
        }
        return nil
    }

    /// Build an NSOrthography hint that pins NSSpellChecker to the
    /// chosen language. Without this, NSSpellChecker may auto-detect
    /// per-paragraph and pick a different dictionary than we want
    /// (e.g. detect Italian on a chapter with many Latin quotations
    /// and silently apply Italian corrections to English passages).
    func makeOrthography(language: String) -> NSOrthography {
        return NSOrthography(
            dominantScript: "Latn",
            languageMap: ["Latn": [language]]
        )
    }

    // MARK: - Token classification helpers

    static func isLatinScript(_ word: String) -> Bool {
        for scalar in word.unicodeScalars where scalar.properties.isAlphabetic {
            // Latin Extended-* + IPA covers the European-language
            // characters we care about. Outside this range → reject.
            if !(0x0041...0x024F).contains(scalar.value)
                && !(0x1E00...0x1EFF).contains(scalar.value) {
                return false
            }
        }
        return true
    }

    static func isLetterOnly(_ word: String) -> Bool {
        word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
    }

    static func primarySubtag(_ tag: String) -> String {
        let lower = tag.lowercased()
        if let dash = lower.firstIndex(of: "-") {
            return String(lower[..<dash])
        }
        return lower
    }

    /// Apply `original`'s case pattern to `target`. Three patterns:
    /// all-caps, title case, lowercase.
    static func matchCase(of original: String, target: String) -> String {
        guard !original.isEmpty, !target.isEmpty else { return target }
        let isAllCaps = original.allSatisfy {
            $0.isUppercase || !$0.isLetter
        } && original.contains(where: { $0.isLetter })
        if isAllCaps { return target.uppercased() }
        if original.first?.isUppercase == true {
            return target.prefix(1).uppercased() + target.dropFirst()
        }
        return target.lowercased()
    }
}
