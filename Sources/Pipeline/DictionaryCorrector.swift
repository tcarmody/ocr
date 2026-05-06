import Foundation
import AppKit
import NaturalLanguage

/// Post-OCR dictionary-match cleanup. Walks each region's joined
/// text, finds words that aren't in the language's dictionary, and
/// when there's an unambiguous Levenshtein-1 candidate that **is**
/// in the dictionary, applies it. Catches the bulk of "obvious"
/// scanner-noise garblings — `thc` → `the`, `Engiish` → `English`,
/// `tlie` → `the` — for free, before Haiku post-OCR cleanup runs.
///
/// **Multi-language via NSSpellChecker.** macOS ships spelling
/// dictionaries for English, French, Italian, Spanish, Portuguese,
/// Catalan, German (and many more). We use those rather than
/// bundling our own wordlists. Per-region language hint comes from
/// `NLLanguageRecognizer`; falls back to the document's primary
/// language for short / ambiguous regions, and to "skip this region"
/// when neither resolves to a supported BCP-47 code.
///
/// **Conservative correction policy.** Three guards keep the pass
/// from damaging proper nouns and technical terms:
/// 1. Only attempt on Latin-script tokens. Greek / Hebrew / Arabic /
///    Cyrillic / CJK words are skipped entirely (their
///    correction would need a different dictionary).
/// 2. Only apply when the top suggestion is Levenshtein distance 1
///    from the original (single-character typo). Distance 2+
///    is usually genuine OCR garbage that needs Sonnet anyway.
/// 3. Skip words shorter than 3 characters and words with
///    embedded digits or punctuation (URLs, model numbers).
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
        var working = nsText.mutableCopy() as! NSMutableString
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

        // Apply case to the suggestion to match the original.
        return Self.matchCase(of: word, target: top)
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
