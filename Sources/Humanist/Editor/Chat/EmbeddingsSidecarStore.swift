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
    /// Per-book named-entity index from NLTagger. Optional for
    /// forward compatibility; populated by `BookEntityIndex.build`
    /// during the embedding pipeline. Drives entity-shaped
    /// retrieval and library-wide entity federation.
    var entities: BookEntityIndex?

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
            hierarchy: nil,
            entities: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, backendIdentifier, dimension
        case paragraphs, hierarchy, entities
    }

    init(
        schemaVersion: Int,
        backendIdentifier: String,
        dimension: Int,
        paragraphs: [Entry],
        hierarchy: BookHierarchyIndex?,
        entities: BookEntityIndex?
    ) {
        self.schemaVersion = schemaVersion
        self.backendIdentifier = backendIdentifier
        self.dimension = dimension
        self.paragraphs = paragraphs
        self.hierarchy = hierarchy
        self.entities = entities
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.backendIdentifier = try c.decode(String.self, forKey: .backendIdentifier)
        self.dimension = try c.decode(Int.self, forKey: .dimension)
        self.paragraphs = try c.decode([Entry].self, forKey: .paragraphs)
        // Optional decode so v1 sidecars still load; the build
        // pass refreshes the hierarchy / entities on next open.
        self.hierarchy = try c.decodeIfPresent(
            BookHierarchyIndex.self, forKey: .hierarchy
        )
        self.entities = try c.decodeIfPresent(
            BookEntityIndex.self, forKey: .entities
        )
    }
}

/// Disk persistence for `EmbeddingsSidecar`. Two storage modes
/// coexist:
///
///   * **UUID-keyed** (preferred when a `LibraryEntry.id` is
///     available): the sidecar filename is `<uuid>.json`, stored
///     in `~/Library/Application Support/Humanist/Embeddings/`.
///     Always local — embeddings are *not* synced across Macs.
///     The share-library-across-machines toggle covers
///     `library.json` and aliases only; embeddings would blow
///     well past iCloud sync's design envelope (53 GB / 1k+ JSON
///     files across one user library) and double the federated
///     index build cost from local-disk speed to iCloud-metadata
///     speed. Pre-Phase-A sidecars that lived in the iCloud root
///     are moved into this directory on first launch by
///     `EmbeddingsCloudMigration.runIfNeeded`.
///
///   * **SHA-keyed** (legacy / uncataloged-fallback): the filename
///     is `SHA256(canonicalEpubPath).json`, always under
///     Application Support. Used for books not in the library
///     catalog (which today should be rare given auto-catalog on
///     editor open) and as a read-side fallback during the
///     migration window.
///
/// Reads use a fallback chain: UUID-at-shared-root, UUID-at-app-
/// support, SHA-at-app-support. Writes always go to the current
/// preferred location for the libraryID. Result: existing
/// SHA-keyed sidecars stay readable until they're naturally
/// refreshed, and turning sharing on doesn't strand any work.
///
/// Tradeoff: moving the .epub orphans its sidecar. With UUID
/// keying the rename problem disappears (id is stable, location
/// is irrelevant). The old SHA-keyed orphans are still possible
/// for uncataloged books; auto-catalog on editor open keeps this
/// rare.
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

    /// Where to *write* the sidecar for this lookup. UUID-keyed
    /// under the local Application Support directory when
    /// `libraryID` is provided; SHA-keyed for uncataloged callers.
    /// Public for tests + Settings cache-size compute. UUID-keyed
    /// writes use the `.emb` binary format; SHA-keyed (rare,
    /// uncataloged) keeps the legacy `.json` shape.
    func writeURL(for epubURL: URL, libraryID: UUID?) -> URL {
        if let libraryID {
            return baseDirectory.appendingPathComponent(
                "\(libraryID.uuidString).emb"
            )
        }
        return legacySHAFileURL(for: epubURL)
    }

    /// Compatibility shim — original single-arg call. Resolves to
    /// the SHA-keyed legacy path so existing call sites that
    /// haven't been threaded through libraryID still work. New
    /// code should call `writeURL(for:libraryID:)`.
    func fileURL(for epubURL: URL) -> URL {
        legacySHAFileURL(for: epubURL)
    }

    /// Ordered list of *read* candidates for this lookup. The
    /// load chain stops at the first file that exists + decodes
    /// cleanly. Order: UUID `.emb` (preferred binary), UUID `.json`
    /// (pre-Phase-C legacy), SHA `.json` (uncataloged-fallback).
    /// All local; iCloud paths are no longer consulted (any
    /// pre-Phase-A files in iCloud have been moved here by
    /// `EmbeddingsCloudMigration` on launch). Visible-internal
    /// for tests.
    func readCandidateURLs(
        for epubURL: URL, libraryID: UUID?
    ) -> [URL] {
        var out: [URL] = []
        if let libraryID {
            out.append(baseDirectory.appendingPathComponent(
                "\(libraryID.uuidString).emb"
            ))
            out.append(baseDirectory.appendingPathComponent(
                "\(libraryID.uuidString).json"
            ))
        }
        out.append(legacySHAFileURL(for: epubURL))
        return out
    }

    /// Read the sidecar for `epubURL`. Walks the candidate chain
    /// returning the first usable file. Returns nil when none of
    /// them exist or the schemaVersion is too old. Dispatches to
    /// the binary decoder for `.emb` files and the legacy JSON
    /// decoder for everything else.
    func read(for epubURL: URL, libraryID: UUID? = nil) -> EmbeddingsSidecar? {
        for url in readCandidateURLs(for: epubURL, libraryID: libraryID) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url)
            else { continue }
            let payload: EmbeddingsSidecar?
            if url.pathExtension == "emb" {
                payload = try? EmbeddingsSidecarBinaryFormat.decode(data)
            } else {
                payload = try? Self.decoder.decode(
                    EmbeddingsSidecar.self, from: data
                )
            }
            guard let payload,
                  payload.schemaVersion >= EmbeddingsSidecar.currentSchemaVersion
            else { continue }
            return payload
        }
        return nil
    }

    /// Write the sidecar for `epubURL`. Creates the storage directory
    /// if needed; failures are silent — losing the cache means a
    /// rebuild on next open, not a broken editor. UUID-keyed
    /// writes go through the `.emb` binary encoder; SHA-keyed
    /// (uncataloged) writes keep the legacy JSON shape.
    func write(
        _ sidecar: EmbeddingsSidecar,
        for epubURL: URL,
        libraryID: UUID? = nil
    ) {
        let url = writeURL(for: epubURL, libraryID: libraryID)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data: Data?
        if url.pathExtension == "emb" {
            data = try? EmbeddingsSidecarBinaryFormat.encode(sidecar)
        } else {
            data = try? Self.encoder.encode(sidecar)
        }
        guard let data else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Drop every known location for this book's sidecar (UUID +
    /// SHA at app support). Used by Settings → "Clear all indexes"
    /// (per-book variant) and tests.
    func clear(for epubURL: URL, libraryID: UUID? = nil) {
        for url in readCandidateURLs(for: epubURL, libraryID: libraryID) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Path helpers

    private func legacySHAFileURL(for epubURL: URL) -> URL {
        let canonical = epubURL.canonicalForFile.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return baseDirectory.appendingPathComponent("\(hex).json")
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
