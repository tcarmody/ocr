import Foundation

/// Seed wordlists for `DictionaryCorrector`'s Guard 6 (classical-
/// vocabulary skip). Two sets:
///   * Latin classical-prose vocabulary: most-common forms from
///     Caesar, Cicero, Virgil, Tacitus, plus high-frequency
///     function words and indeclinable particles. macOS doesn't
///     ship a Latin NSSpellChecker dictionary, so without this
///     list a primary-English book with Latin quotations would
///     see its Latin "corrected" to graphically-similar English.
///   * Greek-in-Latin-letter transliteration: the classical
///     academic vocabulary scholars routinely embed in English
///     prose. Restricted to terms NSSpellChecker English flags
///     as misspelled — common English borrowings like "logos",
///     "ethos", "pathos" pass NSSpellChecker English so they
///     don't need a skip-guard.
///
/// **Maintenance.** Both lists are deliberately compact (a few
/// hundred entries each) to keep the Guard cheap and the failure
/// mode familiar — when a real conversion surfaces a missed
/// classical term, append it here. Lowercase entries only; the
/// `isClassicalVocabulary(word:)` check lowercases the input.
extension DictionaryCorrector {

    /// Latin classical-vocabulary skip list. Source: high-
    /// frequency function words + the most-common forms of
    /// classical-Latin nouns / verbs / adjectives that
    /// English-language scholars cite in inflected form rather
    /// than translating. Not exhaustive — covers the bulk of
    /// what surfaces in academic English prose; users extend
    /// it by adding entries below.
    static let latinClassicalWords: Set<String> = [
        // Function words / particles
        "et", "est", "sunt", "in", "ad", "ab", "ex", "de", "cum",
        "sed", "non", "nec", "neque", "ne", "ut", "uti", "si",
        "nisi", "quia", "quod", "quoque", "etiam", "autem",
        "enim", "ergo", "igitur", "tamen", "vel", "aut", "atque",
        "ac", "an", "anne", "num", "ne", "per", "pro", "post",
        "ante", "inter", "intra", "extra", "supra", "infra",
        "circa", "circum", "praeter", "trans", "ultra", "iuxta",
        "apud", "sine", "propter", "ob", "secundum", "contra",
        // Common pronouns / determiners
        "is", "ea", "id", "eum", "eam", "eos", "eas", "ei", "iis",
        "hic", "haec", "hoc", "huius", "huic", "hunc", "hanc",
        "ille", "illa", "illud", "ipse", "ipsa", "ipsum", "idem",
        "eadem", "qui", "quae", "quod", "cui", "cuius", "quem",
        "quam", "quibus", "quos", "quas", "quid", "quis", "quo",
        // High-frequency nouns
        "res", "rei", "rem", "rebus", "deus", "dei", "deum",
        "homo", "hominis", "hominem", "homines", "vir", "viri",
        "vita", "vitae", "vitam", "mors", "mortis", "mortem",
        "anima", "animae", "animum", "animus", "corpus",
        "corporis", "corpora", "amor", "amoris", "amorem",
        "lex", "legis", "legem", "leges", "ius", "iuris",
        "natura", "naturae", "naturam", "ratio", "rationis",
        "rationem", "veritas", "veritatis", "veritatem",
        "tempus", "temporis", "tempora", "annus", "anni",
        "annum", "dies", "diei", "diem", "manus", "manus",
        "manum", "verbum", "verbi", "verba", "liber", "libri",
        "librum", "imperium", "imperii", "regnum", "regni",
        "civitas", "civitatis", "populus", "populi", "populum",
        "senatus", "consul", "consulis", "rex", "regis", "regem",
        "bellum", "belli", "bella", "pax", "pacis", "pacem",
        "urbs", "urbis", "urbem", "patria", "patriae",
        // High-frequency adjectives / participles
        "magnus", "magna", "magnum", "magni", "magnae", "maior",
        "maxima", "maximus", "maximum", "bonus", "bona", "bonum",
        "boni", "melior", "optimus", "malus", "mala", "malum",
        "pessimus", "novus", "nova", "novum", "novi", "novae",
        "antiquus", "antiqua", "antiquum", "longus", "longa",
        "longum", "altus", "alta", "altum", "totus", "tota",
        "totum", "omnis", "omne", "omnia", "omnium", "omnibus",
        "alius", "alia", "aliud", "alter", "altera", "alterum",
        "primus", "prima", "primum", "secundus", "tertius",
        "ultimus", "tantus", "tanta", "tantum", "talis", "tale",
        "qualis", "quale", "felix", "felicis", "miser", "miseri",
        // High-frequency verbs (common forms)
        "fuit", "fuerunt", "erat", "erant", "esse", "fore",
        "futurus", "esset", "essent", "sit", "sint", "habet",
        "habent", "habebat", "habebant", "habeo", "habere",
        "fecit", "fecerunt", "fecit", "facere", "facit",
        "faciunt", "fiat", "fiunt", "potest", "possunt",
        "poterat", "poterant", "posset", "potuit", "potuerunt",
        "posse", "vult", "volunt", "velit", "velint", "voluit",
        "velle", "dicit", "dicunt", "dixit", "dixerunt", "dicere",
        "videt", "vident", "vidit", "videre", "venit", "veniunt",
        "venerunt", "venire", "audit", "audiunt", "audivit",
        "audire", "scit", "sciunt", "scivit", "scire", "scribit",
        "scribunt", "scripsit", "scribere", "credit", "credunt",
        "credidit", "credere", "amat", "amant", "amavit", "amare",
        // Common philosophical / rhetorical idioms scholars cite
        "summa", "summi", "summum", "primum", "principium",
        "principia", "causa", "causae", "causam", "finis",
        "finem", "modus", "modi", "modum", "ordo", "ordinem",
        "forma", "formae", "formam", "materia", "materiae",
        "species", "speciei", "essentia", "essentiae", "actus",
        "potentia", "potentiae", "virtus", "virtutis", "virtutem",
        "voluntas", "voluntatis", "intellectus", "intellectum",
        "sapientia", "sapientiae", "scientia", "scientiae",
        "doctrina", "doctrinae", "verbum", "verbo", "logos",
        // Citation conventions
        "ibid", "ibidem", "loc", "passim", "cf", "et al", "etc",
        "sic", "viz", "vid", "circa", "ca", "fl", "floruit",
        "vide", "vide supra", "vide infra", "ad loc", "ad locum",
        "scilicet", "scil", "videlicet",
    ]

    /// Greek-in-Latin-letter transliteration skip list. Curated
    /// to the academic-vocabulary tail that English NSSpellChecker
    /// flags — common borrowings like "ethos" / "pathos" / "polis"
    /// / "kosmos" are already in English dictionaries so they
    /// don't appear here. Coverage spans classical Greek
    /// philosophy, rhetoric, drama, and politics terms scholars
    /// embed verbatim. Extend the list when a real conversion
    /// surfaces a missed term.
    static let greekTransliterationWords: Set<String> = [
        // Philosophy
        "aletheia", "aporia", "arche", "ataraxia", "autarkeia",
        "diairesis", "doxa", "dynamis", "energeia", "entelecheia",
        "epagoge", "epistēmē", "episteme", "eudaimonia",
        "eutaxia", "hypokeimenon", "hypostasis", "kalokagathia",
        "kanonike", "katharsis", "katechon", "kerygma",
        "lekton", "logoi", "logos", "metanoia", "mimesis",
        "moira", "noesis", "noēsis", "ousia", "paideia",
        "paradeigma", "parresia", "parrhesia", "phronesis",
        "phronēsis", "physis", "pneuma", "poiesis", "praxis",
        "psyche", "rheme", "sophia", "sophrosyne", "techne",
        "telos", "theoria", "thymos", "topos", "atomos",
        "atoma", "ananke", "apokatastasis", "diaphora",
        "homoiosis", "hyle", "kairos", "menein", "noetikon",
        "phantasia", "phantasmata", "to ti en einai",
        // Rhetoric / drama
        "anabasis", "anagnorisis", "apostrophe", "apotheosis",
        "chorēgos", "choregos", "deuteragonist", "diegesis",
        "ekphrasis", "enthymeme", "epeisodion", "exodos",
        "hamartia", "histor", "hubris", "katastrophe",
        "kerygma", "logographos", "mythos", "parabasis",
        "parodos", "peripeteia", "phylax", "prologos",
        "protagonist", "rhetor", "stasimon", "synecdoche",
        // Theology / liturgy
        "agape", "anagoge", "anamnesis", "apophasis",
        "askesis", "diakonia", "didache", "doxology",
        "ekklesia", "enkrateia", "epiklesis", "epektasis",
        "eros", "hesychia", "hypostatic", "iconostasis",
        "kataphasis", "katharsis", "kenosis", "koinonia",
        "liturgia", "metanoia", "metousiosis", "mystagogia",
        "oikonomia", "ousia", "paraklesis", "philia",
        "philotimo", "philoxenia", "pneumatology", "presbyteros",
        "soteria", "theopoiesis", "theosis", "trinitas",
        // Politics / history
        "agora", "agon", "aretē", "arete", "astynomos",
        "basileus", "boule", "chōra", "chora", "demos",
        "demagogos", "demiurgos", "diadochi", "ecclesia",
        "ephebos", "ephoros", "ethnos", "genos", "gerousia",
        "hetairoi", "hopla", "hoplon", "hubris", "isegoria",
        "isonomia", "klēros", "kleros", "koinē", "koine",
        "metoikos", "nomos", "oligarchia", "panhellenion",
        "peltastes", "phratria", "phyle", "polemos", "polis",
        "politeia", "politikon", "polites", "stasis",
        "stratēgos", "strategos", "symposion", "synedrion",
        "tyche", "tyrannos", "xenia", "xenos",
        // Common classical-text section / citation markers
        "scholia", "scholion", "epigraphe", "lemma", "lemmata",
        "stichos", "stichoi", "kolon", "kola", "kommata",
    ]
}
