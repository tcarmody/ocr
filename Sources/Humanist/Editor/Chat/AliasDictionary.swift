import Foundation

/// User-edited list of terms NLTagger missed. The chat retriever
/// treats each alias as if it were a recognized entity: at query
/// time it scans the current scope's paragraphs for any alias that
/// appears in the query, and emits matching paragraph anchors as
/// extra RRF boosts alongside the entity index's hits.
///
/// Most useful on classical / non-English text where Apple's NER
/// recall is weak (polytonic Greek, Latin, mixed-script academic
/// books) and on domain-specific concepts NLTagger doesn't ship
/// with ("heterotopia", "biopolitics," "qualia"). Stored once
/// per-library, since most aliases are concepts the user wants to
/// surface across every book they own — not per-book.
///
/// Term comparison is case-insensitive; the disk format stores
/// lowercased terms. The UI shows whatever the user typed (preserved
/// for display via `displayTerms`); retrieval scans against the
/// lowercased forms.
struct AliasDictionary: Codable, Sendable, Equatable {
    static let currentSchemaVersion: Int = 1

    let schemaVersion: Int
    /// Lowercased canonical terms. Lookup uses these.
    var terms: Set<String>
    /// Display forms (what the user typed). Same key set as
    /// `terms`; used to render the editor without forcing
    /// lowercase on the user.
    var displayTerms: [String: String]

    static let empty = AliasDictionary(
        schemaVersion: currentSchemaVersion,
        terms: [],
        displayTerms: [:]
    )

    init(
        schemaVersion: Int = currentSchemaVersion,
        terms: Set<String>,
        displayTerms: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.terms = terms
        self.displayTerms = displayTerms
    }

    /// Build from a multi-line text blob — one alias per line. The
    /// editor UI uses this when the user finishes editing the
    /// alias list. Empty / whitespace lines are ignored.
    static func parse(_ text: String) -> AliasDictionary {
        var terms: Set<String> = []
        var display: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let lowered = raw.lowercased()
            terms.insert(lowered)
            // Prefer the longest / most-cased version when the
            // same term appears with different casing on multiple
            // lines (rare but cheap to handle).
            let existing = display[lowered] ?? ""
            if scoreDisplay(raw) > scoreDisplay(existing) {
                display[lowered] = raw
            }
        }
        return AliasDictionary(terms: terms, displayTerms: display)
    }

    /// Render as the multi-line text blob the editor UI consumes.
    /// Sorted alphabetically so the list is stable across edits.
    func render() -> String {
        terms
            .sorted()
            .map { displayTerms[$0] ?? $0 }
            .joined(separator: "\n")
    }

    private static func scoreDisplay(_ s: String) -> Int {
        let uppers = s.filter(\.isUppercase).count
        return uppers * 10 + s.count
    }
}

/// Disk persistence for the alias dictionary. Single per-library
/// file at `~/Library/Application Support/Humanist/Aliases/aliases.json`
/// — same neighborhood as the embeddings sidecars and chat
/// transcripts.
struct AliasDictionaryStore {
    private let storeURL: URL

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let dir = support
                .appendingPathComponent("Humanist", isDirectory: true)
                .appendingPathComponent("Aliases", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            self.storeURL = dir.appendingPathComponent("aliases.json")
        }
    }

    func read() -> AliasDictionary {
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let payload = try? Self.decoder.decode(
                  AliasDictionary.self, from: data
              )
        else { return .empty }
        return payload
    }

    func write(_ dict: AliasDictionary) {
        guard let data = try? Self.encoder.encode(dict) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
