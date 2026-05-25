import Foundation

/// R-Topics Phase 2. Persists per-book lists of AFM-extracted
/// intellectual concepts as `<libraryID>.json` payloads under a
/// configurable directory. Storage is small (~600 bytes per book
/// × thousands of books = a few MB) so the directory can live
/// alongside the catalog in the shared `.humanist/` folder when
/// the user has cloud sync enabled — concept extraction is
/// deterministic per book, so Mac A's extraction is also Mac B's.
///
/// **Why a separate store from `BookEntityIndex`:** the entity
/// index lives inside the embedding sidecar, which gets rebuilt
/// whenever the embedding backend changes. AFM concept
/// extraction is independent of the embedding backend — same
/// AFM output regardless of whether you're indexing against
/// Apple NLEmbedding or Gemini. Storing concepts separately
/// means switching embedding backends doesn't force re-running
/// the 5-10s-per-book AFM call.
///
/// **Lifecycle:**
///   * Written once per book when `BookConceptExtractor` runs
///     (typically at import time, optionally on bulk re-extract).
///   * Read at `BookEntityIndex.build` time and folded into the
///     alias-scan path so concepts get paragraph anchors
///     attached.
///   * Read at Topics-rollup time via the sidecar that already
///     carries the anchor-attached version. The federated
///     `LibraryConceptGraph` doesn't reach into this store
///     directly.
///   * Re-read explicitly via "Re-extract concepts" if the user
///     wants fresh AFM output (model updates, new chapters
///     added, etc.).
public struct BookConceptStore: Sendable {

    /// Disk payload. `schemaVersion` is `1` today; reserved for a
    /// future shape change without invalidating already-extracted
    /// content. `modelIdentifier` records which Apple Intelligence
    /// generation produced the list — useful when a future AFM
    /// upgrade shifts the output enough that re-extraction is
    /// worth it (the bulk-extract command can filter by older
    /// identifiers).
    public struct Payload: Codable, Equatable, Sendable {
        public static let currentSchemaVersion: Int = 1

        public let schemaVersion: Int
        /// Lowercase canonical concept strings. Same shape as the
        /// alias dictionary — `BookEntityIndex.build` treats them
        /// identically, scanning paragraphs and attaching anchors
        /// where each string appears.
        public let concepts: [String]
        public let generatedAt: Date
        public let modelIdentifier: String

        public init(
            schemaVersion: Int = currentSchemaVersion,
            concepts: [String],
            generatedAt: Date,
            modelIdentifier: String
        ) {
            self.schemaVersion = schemaVersion
            self.concepts = concepts
            self.generatedAt = generatedAt
            self.modelIdentifier = modelIdentifier
        }
    }

    /// Directory containing per-book payload files. Caller picks
    /// the location; for the production app this is either
    /// `<root>/.humanist/Concepts/` (cloud / custom-local) or
    /// `<App Support>/Humanist/Concepts/` (default local).
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public func read(libraryID: UUID) -> Payload? {
        let url = fileURL(libraryID: libraryID)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? Self.decoder.decode(Payload.self, from: data)
        else { return nil }
        return payload
    }

    /// Convenience that returns just the concept strings as a Set
    /// — the shape `BookEntityIndex.build` expects when folding
    /// concepts into the alias-scan path. Returns empty when no
    /// payload exists for this libraryID.
    public func conceptTerms(libraryID: UUID) -> Set<String> {
        guard let payload = read(libraryID: libraryID) else { return [] }
        return Set(payload.concepts)
    }

    /// True when a payload exists for `libraryID`. Cheap stat;
    /// callers use this to short-circuit re-extraction during
    /// bulk runs without parsing the JSON.
    public func hasPayload(libraryID: UUID) -> Bool {
        FileManager.default.fileExists(
            atPath: fileURL(libraryID: libraryID).path
        )
    }

    public func write(_ payload: Payload, libraryID: UUID) throws {
        try FileManager.default.createDirectory(
            at: baseDirectory, withIntermediateDirectories: true
        )
        let url = fileURL(libraryID: libraryID)
        let data = try Self.encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }

    public func delete(libraryID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(libraryID: libraryID))
    }

    private func fileURL(libraryID: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(libraryID.uuidString).json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
