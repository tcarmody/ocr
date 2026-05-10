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
    static let currentSchemaVersion: Int = 1

    let schemaVersion: Int
    /// Backend identity (`apple.nl.sentence.en`, `voyage.voyage-3-lite`,
    /// etc.). A change forces a full rebuild — the vector spaces are
    /// not comparable across backends.
    let backendIdentifier: String
    /// Vector dimension. Stored alongside the identifier as a defense
    /// against a backend whose dimension changes between versions
    /// (Matryoshka models, different output_dim configs, etc.).
    let dimension: Int
    let paragraphs: [Entry]

    struct Entry: Codable, Sendable {
        let chapterIdx: Int
        let paragraphIdx: Int
        let textHash: String
        let vector: [Float]
    }

    /// Empty sidecar with the given backend metadata. Used as the
    /// starting state when no on-disk file exists or when the loaded
    /// file's backend doesn't match the current selection.
    static func empty(backend: String, dimension: Int) -> EmbeddingsSidecar {
        EmbeddingsSidecar(
            schemaVersion: currentSchemaVersion,
            backendIdentifier: backend,
            dimension: dimension,
            paragraphs: []
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
    /// exists or the file is unreadable; the caller treats both as
    /// "no cache; build from scratch."
    func read(for epubURL: URL) -> EmbeddingsSidecar? {
        let url = fileURL(for: epubURL)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? Self.decoder.decode(EmbeddingsSidecar.self, from: data)
        else { return nil }
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
