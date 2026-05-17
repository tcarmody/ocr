import Foundation
import os

/// Logger for first-load diagnostics on the bundled wordlists.
/// Only emits the loaded-counts on first access; runtime checks
/// are silent. Surfaces in Console.app under the same subsystem
/// as the rest of the pipeline.
private let classicalLog = Logger(
    subsystem: "com.tcarmody.Humanist",
    category: "DictionaryCorrector.ClassicalWordlists"
)

/// Bundled classical-language wordlists for `DictionaryCorrector`'s
/// Guard 6 (classical-vocabulary skip).
///
/// **Latin.** Stems extracted from **Whitaker's Words** dictionary
/// (William Whitaker, US Naval Academy, released into the public
/// domain by the author). ~31K stems covering classical and late
/// Latin lemmata. The dictionary stores stems rather than fully-
/// inflected surface forms, so the matcher does **prefix matching**
/// against the input word: `amicitia` (nominative of `amicitia,
/// -ae, f.`) matches stem `amici` and is recognized as Latin.
/// Source file: `Sources/Pipeline/Resources/latin-stems.txt`. To
/// regenerate from a fresh Whitaker pull, see the comment at the
/// top of that file.
///
/// **Greek-in-Latin-letter transliteration.** Curated inline list
/// of classical Greek academic vocabulary that English
/// NSSpellChecker flags as misspelled. Common borrowings already
/// in English dictionaries (ethos / pathos / kosmos / polis) are
/// deliberately omitted — NSSpellChecker handles those. Extend by
/// editing `greekTransliterationWords` below.
extension DictionaryCorrector {

    /// In-memory cache of Latin stems, loaded once on first
    /// access. Sorted lexicographically so prefix matching can
    /// binary-search. `nil` until the bundle resource is loaded
    /// (or load failed) — see `latinStemsCached`.
    nonisolated(unsafe) private static var latinStemsCache: [String]?
    private static let latinStemsLock = NSLock()

    /// Sorted Latin stem array. Lazy-loads from the bundled
    /// `latin-stems.txt` resource. Returns an empty array on load
    /// failure so the corrector degrades gracefully (Guard 6 will
    /// simply never fire on Latin without it; Guards 5 + 7 still
    /// catch most foreign-cognate cases).
    static var latinStems: [String] {
        latinStemsLock.lock()
        defer { latinStemsLock.unlock() }
        if let cached = latinStemsCache { return cached }
        let loaded = loadLatinStems()
        latinStemsCache = loaded
        return loaded
    }

    /// Read + parse `latin-stems.txt` from the Pipeline target's
    /// resource bundle. One stem per line, already sorted +
    /// lowercased + filtered to letter-only.
    private static func loadLatinStems() -> [String] {
        guard let url = Bundle.module.url(
            forResource: "latin-stems", withExtension: "txt"
        ) else {
            classicalLog.error(
                "latin-stems.txt not found in Bundle.module — Guard 6 Latin path disabled"
            )
            return []
        }
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let stems = raw
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            classicalLog.info(
                "loaded \(stems.count, privacy: .public) Latin stems for classical-vocab guard"
            )
            return stems
        } catch {
            classicalLog.error(
                "failed to read latin-stems.txt: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// Minimum input-word length before we attempt a Latin stem-
    /// prefix match. Short English words ("the", "and", "this")
    /// would otherwise spuriously match short Latin function-word
    /// prefixes ("the" matches stem "the-" → Latin verb *thecium*
    /// surface forms; "and" might match a stem). Floor of 5
    /// rules those out without losing real Latin coverage —
    /// inflected Latin nouns + verbs are almost always 5+ chars.
    static let minWordLengthForLatinPrefixMatch: Int = 5

    /// Minimum stem length before we'll use it as a prefix match
    /// source. Avoids matching arbitrary English words against
    /// 2-3 character stems like "ab" / "ad" / "in" (which exist
    /// as Latin function words in their own right but as stems
    /// would match thousands of unrelated English words).
    static let minStemLengthForLatinPrefixMatch: Int = 4

    /// Return true when `word` matches a Latin stem via prefix.
    /// Uses binary search over the sorted stem array to find the
    /// largest stem ≤ `lowered`; that candidate is either a
    /// prefix of `lowered` or the word doesn't match anything.
    /// `O(log n)` per lookup.
    static func isLatinByStemPrefix(word: String) -> Bool {
        let lowered = word.lowercased()
        guard lowered.count >= minWordLengthForLatinPrefixMatch
        else { return false }
        let stems = latinStems
        guard !stems.isEmpty else { return false }

        // Binary search for the largest stem ≤ lowered.
        var lo = 0
        var hi = stems.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if stems[mid] <= lowered { lo = mid + 1 } else { hi = mid }
        }
        // `lo` is the count of stems ≤ lowered; the candidate
        // (if any) is at index lo - 1.
        guard lo > 0 else { return false }
        let candidate = stems[lo - 1]
        guard candidate.count >= minStemLengthForLatinPrefixMatch
        else { return false }
        // Exact match counts; prefix match also counts.
        return lowered.hasPrefix(candidate)
    }

    /// Greek-in-Latin-letter transliteration skip list. Curated
    /// to the academic-vocabulary tail that English NSSpellChecker
    /// flags — common borrowings like `ethos` / `pathos` / `polis`
    /// / `kosmos` already pass English spell-check so they don't
    /// appear here. Coverage spans classical Greek philosophy,
    /// rhetoric, drama, theology, and political vocabulary that
    /// scholars routinely embed in English prose. Extend by
    /// adding entries when a real conversion surfaces a missed
    /// term.
    static let greekTransliterationWords: Set<String> = [
        // Philosophy — epistemology / metaphysics
        "aletheia", "aporia", "arche", "ataraxia", "autarkeia",
        "diairesis", "doxa", "dynamis", "energeia", "entelecheia",
        "epagoge", "epistēmē", "episteme", "eudaimonia",
        "eutaxia", "hypokeimenon", "hypostasis", "kalokagathia",
        "kanonike", "katechon", "lekton", "logoi", "logon",
        "metanoia", "mimesis", "moira", "noesis", "noēsis",
        "ousia", "paideia", "paradeigma", "parresia", "parrhesia",
        "phronesis", "phronēsis", "physis", "pneuma", "poiesis",
        "praxis", "psyche", "rheme", "sophia", "sophrosyne",
        "techne", "telos", "theoria", "thymos", "topos",
        "atomos", "atoma", "ananke", "apokatastasis", "diaphora",
        "homoiosis", "hyle", "kairos", "menein", "noetikon",
        "phantasia", "phantasmata", "synousia", "homonoia",
        "aisthesis", "aisthetikon", "logikon", "logistikon",
        "thumoeides", "epithumetikon", "anamnesis", "noeton",
        // Rhetoric / drama
        "anabasis", "anagnorisis", "apostrophe", "apotheosis",
        "chorēgos", "choregos", "deuteragonist", "diegesis",
        "ekphrasis", "enthymeme", "epeisodion", "exodos",
        "hamartia", "histor", "hubris", "katastrophe",
        "kerygma", "logographos", "mythos", "parabasis",
        "parodos", "peripeteia", "phylax", "prologos",
        "protagonist", "rhetor", "stasimon", "synecdoche",
        "epideictic", "deictic", "stichomythia", "tragoidia",
        "komodia", "satyroi", "pathopoeia", "ethopoeia",
        // Theology / liturgy
        "agape", "anagoge", "apophasis", "askesis", "diakonia",
        "didache", "doxology", "ekklesia", "enkrateia",
        "epiklesis", "epektasis", "eros", "hesychia",
        "hypostatic", "iconostasis", "kataphasis", "katharsis",
        "kenosis", "koinonia", "liturgia", "metousiosis",
        "mystagogia", "oikonomia", "paraklesis", "philia",
        "philotimo", "philoxenia", "pneumatology", "presbyteros",
        "soteria", "theopoiesis", "theosis", "trinitas",
        "pleroma", "perichoresis", "synergeia", "theogony",
        "theopneustos", "doxazomenos", "diakrisis", "logismoi",
        "synaxis", "anaphora", "epiclesis", "anabaptism",
        // Politics / history
        "agora", "agon", "aretē", "arete", "astynomos",
        "basileus", "boule", "chōra", "chora", "demos",
        "demagogos", "demiurgos", "diadochi", "ecclesia",
        "ephebos", "ephoros", "ethnos", "genos", "gerousia",
        "hetairoi", "hopla", "hoplon", "isegoria", "isonomia",
        "klēros", "kleros", "koinē", "koine", "metoikos",
        "nomos", "oligarchia", "panhellenion", "peltastes",
        "phratria", "phyle", "polemos", "politeia", "politikon",
        "polites", "stasis", "stratēgos", "strategos",
        "symposion", "synedrion", "tyche", "tyrannos",
        "xenia", "xenos", "syngraphe", "thalassocracy",
        "synoikia", "synoikismos", "polemarchos", "archon",
        "polemarch", "metoikia", "perioikoi", "helotes",
        "thalassokratia", "kybernesis", "demosion", "idion",
        // Literary / textual conventions
        "scholia", "scholion", "epigraphe", "lemma", "lemmata",
        "stichos", "stichoi", "kolon", "kola", "kommata",
        "codex", "codices", "scholiast", "obelos", "asterisk",
        "diple", "antisigma", "paragraphos", "coronis",
        "diairesis", "epanalepsis", "anaclasis", "asyndeton",
        "polysyndeton", "hyperbaton", "anaphora", "epiphora",
        "chiasmus", "antimetabole", "hendiadys", "syllepsis",
        // Latin transliterations of Greek scholarship terms
        "ad locum", "loci classici", "ad fontes",
        // Common philosophical concepts cited untranslated
        "monad", "monads", "henad", "henads", "noumenon",
        "noumena", "phenomenon", "phenomena", "logoi spermatikoi",
        "phantasiai", "kataleptike", "akrasia", "akratic",
        "synonyma", "homonyma", "paronyma", "antikeimena",
    ]
}
