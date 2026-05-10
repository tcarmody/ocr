import Foundation
import CryptoKit
import EPUB

/// On-disk wire format for the per-book embedding cache. Mirrors
/// `ChatTranscriptStore.Payload` in style: schema-versioned JSON with
/// a top-level `paragraphs` array; future fields can be added without
/// breaking older readers.
///
/// Stored as a discrete JSON document — gzip is tempting but the
/// app's existing sidecars (chat transcripts, correction trail) are
/// plain JSON and the size win at v1 (~2 MB → ~700 KB) doesn't
/// outweigh the debuggability hit. If real-world libraries grow past
/// 50 MB total embedding cache, switch to `Data(contentsOf:).gunzipped()`
/// later — the schema doesn't have to change.
struct EmbeddingsSidecar: Codable, Sendable {
    /// Schema version. Bump and old sidecars get rebuilt on next
    /// open. Bumped from 1 to 2 in `R-Chat-Graph-Lite` to add the
    /// `hierarchy` section.
    static let currentSchemaVersion: Int = 2

    var schemaVersion: Int
    /// Backend identity (`apple.nl.sentence.en`, `voyage.voyage-3-lite`,
    /// etc.). A change forces a full rebuild — the vector spaces are
    /// not comparable across backends.
    var backendIdentifier: String
    /// Vector dimension. Stored alongside the identifier as a defense
    /// against a backend whose dimension changes between versions
    /// (Matryoshka models, different output_dim configs, etc.).
    var dimension: Int
    var paragraphs: [Entry]
    /// Per-book chapter/section tree built from `nav.xhtml`. Optional
    /// for forward compatibility — earlier sidecars (schemaVersion 1)
    /// loaded with a nil hierarchy and trigger a rebuild that
    /// populates it.
    var hierarchy: BookHierarchyIndex?

    struct Entry: Codable, Sendable {
        let chapterIdx: Int
        let paragraphIdx: Int
        let textHash: String
        let vector: [Float]
        /// Verbatim paragraph text. Optional for backward
        /// compatibility — early v2 sidecars (between the schema
        /// bump and this add) don't carry it. Populated by
        /// `BookEmbeddingIndex.build` going forward; library-scope
        /// chat falls back to opening the book on disk when text
        /// is missing.
        ///
        /// Storing the text here avoids a per-query EPUB unzip
        /// when library-scope retrieval surfaces hits across books
        /// the user doesn't have open. Cost is ~1-2 MB extra per
        /// book on disk — small relative to the source EPUB.
        let text: String?

        private enum CodingKeys: String, CodingKey {
            case chapterIdx, paragraphIdx, textHash, vector, text
        }

        init(
            chapterIdx: Int,
            paragraphIdx: Int,
            textHash: String,
            vector: [Float],
            text: String? = nil
        ) {
            self.chapterIdx = chapterIdx
            self.paragraphIdx = paragraphIdx
            self.textHash = textHash
            self.vector = vector
            self.text = text
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.chapterIdx = try c.decode(Int.self, forKey: .chapterIdx)
            self.paragraphIdx = try c.decode(Int.self, forKey: .paragraphIdx)
            self.textHash = try c.decode(String.self, forKey: .textHash)
            self.vector = try c.decode([Float].self, forKey: .vector)
            self.text = try c.decodeIfPresent(String.self, forKey: .text)
        }
    }

    /// Empty sidecar with the given backend metadata. Used as the
    /// starting state when no on-disk file exists or when the loaded
    /// file's backend doesn't match the current selection.
    static func empty(backend: String, dimension: Int) -> EmbeddingsSidecar {
        EmbeddingsSidecar(
            schemaVersion: currentSchemaVersion,
            backendIdentifier: backend,
            dimension: dimension,
            paragraphs: [],
            hierarchy: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, backendIdentifier, dimension
        case paragraphs, hierarchy
    }

    init(
        schemaVersion: Int,
        backendIdentifier: String,
        dimension: Int,
        paragraphs: [Entry],
        hierarchy: BookHierarchyIndex?
    ) {
        self.schemaVersion = schemaVersion
        self.backendIdentifier = backendIdentifier
        self.dimension = dimension
        self.paragraphs = paragraphs
        self.hierarchy = hierarchy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.backendIdentifier = try c.decode(String.self, forKey: .backendIdentifier)
        self.dimension = try c.decode(Int.self, forKey: .dimension)
        self.paragraphs = try c.decode([Entry].self, forKey: .paragraphs)
        // Optional decode so v1 sidecars still load; the build
        // pass refreshes the hierarchy on next open.
        self.hierarchy = try c.decodeIfPresent(
            BookHierarchyIndex.self, forKey: .hierarchy
        )
    }
}

/// Disk persistence for `EmbeddingsSidecar`, keyed by the canonical
/// path of the EPUB the index belongs to (same scheme as
/// `ChatTranscriptStore`).
///
/// We deliberately store outside the EPUB — same reasoning as the
/// chat transcript path:
///
///  * Embeddings are derived state, not document content; coupling
///    the cache to the save flow would force a full re-zip every time
///    a paragraph changes.
///  * A spec-faithful EPUB has nothing to gain from a 2 MB binary
///    blob in `META-INF/`; readers that don't recognize it would
///    flag it.
///
/// Tradeoff: moving the .epub orphans its sidecar. Acceptable for v1
/// (rebuild on next open is ~1 minute with NLEmbedding); a follow-up
/// can index by the OPF unique-identifier metadata to follow renames.
struct EmbeddingsSidecarStore {
    private let baseDirectory: URL

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.baseDirectory = support
                .appendingPathComponent("Humanist", isDirectory: true)
                .appendingPathComponent("Embeddings", isDirectory: true)
        }
    }

    /// Where the sidecar for `epubURL` lives on disk. Exposed so the
    /// Settings UI can compute total cache size without re-deriving
    /// the hashing scheme.
    func fileURL(for epubURL: URL) -> URL {
        let canonical = epubURL.canonicalForFile.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return baseDirectory.appendingPathComponent("\(hex).json")
    }

    /// Read the sidecar for `epubURL`. Returns `nil` when no file
    /// exists, the file is unreadable, or its `schemaVersion` is
    /// older than the current version (the caller treats those
    /// equivalently — "no usable cache; build from scratch").
    func read(for epubURL: URL) -> EmbeddingsSidecar? {
        let url = fileURL(for: epubURL)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? Self.decoder.decode(EmbeddingsSidecar.self, from: data)
        else { return nil }
        // Forward-compat: a future Humanist build might write a
        // higher schemaVersion than this one knows about. Newer
        // sidecars are loaded as-is; older ones are dropped so the
        // build pass can re-populate the missing sections.
        guard payload.schemaVersion >= EmbeddingsSidecar.currentSchemaVersion else {
            return nil
        }
        return payload
    }

    /// Write the sidecar for `epubURL`. Creates the storage directory
    /// if needed; failures are silent — losing the cache means a
    /// rebuild on next open, not a broken editor.
    func write(_ sidecar: EmbeddingsSidecar, for epubURL: URL) {
        let url = fileURL(for: epubURL)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? Self.encoder.encode(sidecar) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Drop the sidecar for `epubURL`. Used by Settings → "Clear all
    /// indexes" (per-book wipe variant) and by tests.
    func clear(for epubURL: URL) {
        let url = fileURL(for: epubURL)
        try? FileManager.default.removeItem(at: url)
    }

    /// Wipe every sidecar under the storage root. Used by Settings
    /// → "Clear all indexes". Best-effort: directory-level delete +
    /// recreate so we don't have to enumerate. Returns the number of
    /// bytes reclaimed (0 on failure).
    @discardableResult
    func clearAll() -> Int {
        let total = totalBytes()
        try? FileManager.default.removeItem(at: baseDirectory)
        return total
    }

    /// Total bytes used by all sidecars under the storage root.
    /// Surfaced in Settings so the user knows what they're carrying.
    /// Cheap to compute — directory enumeration with attribute
    /// fetches; ~ms even on large libraries.
    func totalBytes() -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            guard let resourceValues = try? url.resourceValues(
                forKeys: [.fileSizeKey]
            ), let size = resourceValues.fileSize else { continue }
            total += size
        }
        return total
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Sorted keys so a sidecar diffs cleanly across rebuilds —
        // helpful when debugging "did the cache invalidate the
        // paragraphs I expected?" Pretty-printing is *not* enabled
        // because vectors balloon a 1 MB compact file to 4-5 MB.
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
