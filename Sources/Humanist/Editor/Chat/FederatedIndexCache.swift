import Foundation
import CryptoKit
import EPUB

/// Disk-persisted federated library index — the assembled product
/// of `LibraryEmbeddingIndex.build` + `LibraryEntityIndex.build`,
/// snapshotted to a single binary file under Application Support.
///
/// Why this exists: each `build` pass walks every per-book sidecar,
/// JSON-decodes the embedding vectors, and reassembles the in-
/// memory shape. At library scale (1k+ books, tens of GB of
/// sidecar JSON), that walk dominates the cold-start latency on
/// every library-chat send where the in-memory cache has been
/// dropped (window close + reopen, settings change, etc.). Persisting
/// the assembled blob lets a cold start re-hydrate in ~10× less
/// wall time and ~0× JSON-decode CPU.
///
/// Invalidation: fingerprint is a SHA-256 over the backend identity
/// + every contributing sidecar's (libraryID, mtime, size) tuple.
/// Sidecar changes — new books indexed, existing books rebuilt,
/// backend switched — invalidate naturally without explicit
/// signaling. `stat`-only; no sidecar bytes are read for the
/// fingerprint, so the cache-hit check stays cheap.
///
/// Format: hand-rolled little-endian binary, magic-prefixed.
/// Header values + per-source / per-paragraph metadata are
/// length-prefixed strings; vector blobs are packed Float32. The
/// shape isn't intended to be portable — both sides of the wire
/// are this app, macOS-only, same architecture. Loader is defensive
/// (throws on any short read or unknown magic) so a corrupt file
/// falls through to a fresh rebuild rather than crashing.
enum FederatedIndexCache {

    /// Magic + format-version prefix. Bump the trailing byte and
    /// older caches get rejected on load and rebuilt cleanly.
    /// Version `\x02` adds a length-prefixed `bookAuthor` field
    /// after `bookTitle` in each source, supporting the
    /// `PRIMARY SOURCES FIRST` rendered-context block.
    private static let magic: [UInt8] = [
        0x48, 0x55, 0x4D, 0x41, 0x4E, 0x43, 0x41, 0x02  // "HUMANCA\x02"
    ]

    /// Per-call payload returned to the chat VM on a cache hit.
    /// Mirrors the two index objects the VM keeps alongside each
    /// other; the VM rehydrates `LibraryEmbeddingIndex` with the
    /// live backend reference (not serialized — backends carry
    /// keys/clients/etc. that don't belong on disk).
    struct Payload {
        let backendIdentifier: String
        let dimension: Int
        let fingerprint: String
        let stats: LibraryEmbeddingIndex.Stats
        let sources: [LibraryEmbeddingIndex.Source]
        let entityIndex: LibraryEntityIndex
    }

    // MARK: - Paths

    /// Where the cache lives. Sibling to other Application Support
    /// state; absolute so the cache survives a process restart
    /// without re-resolving via `FileManager.urls`.
    static var defaultCacheURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Humanist", isDirectory: true)
            .appendingPathComponent("library-federated-index.bin")
    }

    // MARK: - Fingerprint

    /// SHA-256 over (backendIdentifier, dimension, sorted
    /// [libraryID, mtime-seconds, byteSize] tuples). `stat`-only —
    /// we don't read sidecar contents — so this is cheap even on
    /// libraries where every entry has a UUID-keyed file.
    static func fingerprint(
        backendIdentifier: String,
        dimension: Int,
        entries: [LibraryEntry],
        store: EmbeddingsSidecarStore = EmbeddingsSidecarStore()
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(backendIdentifier.utf8))
        var dim = Int64(dimension)
        withUnsafeBytes(of: &dim) { hasher.update(bufferPointer: $0) }

        // Tuple per entry: libraryID + (mtime-seconds, size). The
        // tuple is sorted by libraryID so the fingerprint is stable
        // across the entries-array's iteration order (which the
        // catalog re-orders on rename / reorder / etc.).
        struct Tuple {
            var id: UUID
            var mtime: Int64
            var size: Int64
        }
        var tuples: [Tuple] = []
        tuples.reserveCapacity(entries.count)
        for entry in entries {
            let mtime: Int64
            let size: Int64
            if let info = sidecarStat(for: entry, store: store) {
                mtime = info.mtime
                size = info.size
            } else {
                // Sentinel for "no sidecar yet" — distinct from
                // any real (mtime, size) so a missing file
                // contributes deterministically.
                mtime = -1
                size = -1
            }
            tuples.append(Tuple(id: entry.id, mtime: mtime, size: size))
        }
        tuples.sort { $0.id.uuidString < $1.id.uuidString }
        for i in tuples.indices {
            withUnsafeBytes(of: &tuples[i].id) { hasher.update(bufferPointer: $0) }
            withUnsafeBytes(of: &tuples[i].mtime) { hasher.update(bufferPointer: $0) }
            withUnsafeBytes(of: &tuples[i].size) { hasher.update(bufferPointer: $0) }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sidecarStat(
        for entry: LibraryEntry,
        store: EmbeddingsSidecarStore
    ) -> (mtime: Int64, size: Int64)? {
        // Walk the read-candidate chain and stat the first existing
        // file. Mirrors `EmbeddingsSidecarStore.read` without paying
        // the JSON decode.
        for url in store.readCandidateURLs(for: entry.epubURL, libraryID: entry.id) {
            guard let attrs = try? FileManager.default.attributesOfItem(
                atPath: url.path
            ) else { continue }
            let mtime = (attrs[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            return (Int64(mtime), size)
        }
        return nil
    }

    // MARK: - Save

    /// Atomic write. Returns true on success, false on any IO
    /// failure — a failed save isn't fatal (we just rebuild next
    /// time), so the caller doesn't need to surface anything.
    @discardableResult
    static func save(
        _ payload: Payload,
        to url: URL = defaultCacheURL
    ) -> Bool {
        // Stream the encoded blob to a temp file via a bounded
        // buffer rather than building one giant in-memory Data —
        // the previous `try data.write(to:)` path could peak at
        // tens of GB on big libraries (high-dim Gemini × thousands
        // of books) because Data doubles capacity on append, and
        // the in-memory `sources` payload still has to coexist
        // with the half-encoded buffer. Streaming caps the
        // transient cost at the buffer size (~256 KB).
        let parent = url.deletingLastPathComponent()
        let tempURL = parent.appendingPathComponent(
            "library-federated-index.bin.tmp-\(UUID().uuidString)"
        )
        do {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(
                atPath: tempURL.path, contents: nil
            ) else { return false }
            let handle = try FileHandle(forWritingTo: tempURL)
            do {
                var writer = StreamingByteWriter(handle: handle)
                try encode(payload, into: &writer)
                try writer.flush()
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: tempURL)
                return false
            }
            // Atomic replace. `replaceItemAt` returns the new URL
            // of the destination; we don't need it.
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    // MARK: - Load

    /// Attempt to load a cache that matches `expectedFingerprint`.
    /// Returns nil on any read failure (file missing, short read,
    /// bad magic, fingerprint mismatch, backend identity drift).
    /// Caller falls through to a full rebuild + save.
    static func load(
        expectedFingerprint: String,
        backendIdentifier: String,
        dimension: Int,
        from url: URL = defaultCacheURL
    ) -> Payload? {
        // Memory-map the cache file instead of reading the whole
        // thing into a heap `Data`. On a 48 GB Gemini-3072 cache,
        // the eager `Data(contentsOf:)` path spiked RSS by 8+ GB
        // mid-load (sampled at t=70s on PID 1908) before the
        // decoder pulled bytes out into Swift arrays. `.alwaysMapped`
        // hands the bytes to the kernel's page cache; the decoder
        // reads through `data.subdata(in:)` (which references the
        // mapping) and only the working set stays resident.
        guard let data = try? Data(
            contentsOf: url, options: .alwaysMapped
        ) else { return nil }
        let payload = try? decode(data: data)
        guard let payload else { return nil }
        guard payload.fingerprint == expectedFingerprint,
              payload.backendIdentifier == backendIdentifier,
              payload.dimension == dimension
        else { return nil }
        return payload
    }

    /// Force-clear the on-disk cache. Used by Settings → "Clear all
    /// indexes" and from tests; the in-memory cache held by
    /// `LibraryChatViewModel` is invalidated separately via its
    /// own backend-changed observer.
    static func invalidate(at url: URL = defaultCacheURL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Encode

    private static func encode(
        _ payload: Payload,
        into w: inout StreamingByteWriter
    ) throws {
        try w.writeBytes(Data(magic))
        try w.writeString(payload.fingerprint)
        try w.writeString(payload.backendIdentifier)
        try w.writeI32(Int32(payload.dimension))

        try w.writeI32(Int32(payload.stats.indexed))
        try w.writeI32(Int32(payload.stats.unindexed))
        try w.writeI32(Int32(payload.stats.backendMismatch))

        try w.writeU32(UInt32(payload.sources.count))
        for source in payload.sources {
            try w.writeString(source.epubURL.path)
            try w.writeString(source.bookTitle)
            // Empty string encodes nil — the decode side maps the
            // empty case back to nil rather than `Optional("")` so
            // a missing author doesn't read as "by " in renders.
            try w.writeString(source.bookAuthor ?? "")
            try w.writeU32(UInt32(source.paragraphs.count))
            for p in source.paragraphs {
                try w.writeI32(Int32(p.chapterIdx))
                try w.writeI32(Int32(p.paragraphIdx))
                try w.writeString(p.textHash)
                if let text = p.text {
                    try w.writeU8(1)
                    try w.writeString(text)
                } else {
                    try w.writeU8(0)
                }
                try w.writeFloatVector(p.vector, expectedCount: payload.dimension)
            }
        }

        try w.writeU32(UInt32(payload.entityIndex.mentions.count))
        for (canonical, anchors) in payload.entityIndex.mentions {
            try w.writeString(canonical)
            try w.writeU32(UInt32(anchors.count))
            for a in anchors {
                try w.writeString(a.epubURL.path)
                try w.writeString(a.bookTitle)
                try w.writeI32(Int32(a.chapterIdx))
                try w.writeI32(Int32(a.paragraphIdx))
            }
        }
        try w.writeU32(UInt32(payload.entityIndex.displayNames.count))
        for (canonical, display) in payload.entityIndex.displayNames {
            try w.writeString(canonical)
            try w.writeString(display)
        }
        try w.writeI32(Int32(payload.entityIndex.indexedBookCount))
    }

    // MARK: - Decode

    private static func decode(data: Data) throws -> Payload {
        var r = ByteReader(data: data)
        let prefix = try r.readBytes(magic.count)
        guard prefix.elementsEqual(magic) else {
            throw CacheError.badMagic
        }
        let fingerprint = try r.readString()
        let backendIdentifier = try r.readString()
        let dimension = Int(try r.readI32())

        let indexed = Int(try r.readI32())
        let unindexed = Int(try r.readI32())
        let backendMismatch = Int(try r.readI32())
        let stats = LibraryEmbeddingIndex.Stats(
            indexed: indexed,
            unindexed: unindexed,
            backendMismatch: backendMismatch
        )

        let sourceCount = Int(try r.readU32())
        var sources: [LibraryEmbeddingIndex.Source] = []
        sources.reserveCapacity(sourceCount)
        for _ in 0..<sourceCount {
            let epubPath = try r.readString()
            let bookTitle = try r.readString()
            let rawAuthor = try r.readString()
            let bookAuthor: String? = rawAuthor.isEmpty ? nil : rawAuthor
            let pCount = Int(try r.readU32())
            var paragraphs: [EmbeddingsSidecar.Entry] = []
            paragraphs.reserveCapacity(pCount)
            for _ in 0..<pCount {
                let chapterIdx = Int(try r.readI32())
                let paragraphIdx = Int(try r.readI32())
                let textHash = try r.readString()
                let hasText = try r.readU8() == 1
                let text: String? = hasText ? try r.readString() : nil
                let vector = try r.readFloatVector(count: dimension)
                paragraphs.append(EmbeddingsSidecar.Entry(
                    chapterIdx: chapterIdx,
                    paragraphIdx: paragraphIdx,
                    textHash: textHash,
                    vector: vector,
                    text: text
                ))
            }
            sources.append(LibraryEmbeddingIndex.Source(
                epubURL: URL(fileURLWithPath: epubPath),
                bookTitle: bookTitle,
                bookAuthor: bookAuthor,
                paragraphs: paragraphs
            ))
        }

        let mentionCount = Int(try r.readU32())
        var mentions: [String: [LibraryEntityIndex.LibraryAnchor]] = [:]
        mentions.reserveCapacity(mentionCount)
        for _ in 0..<mentionCount {
            let canonical = try r.readString()
            let anchorCount = Int(try r.readU32())
            var anchors: [LibraryEntityIndex.LibraryAnchor] = []
            anchors.reserveCapacity(anchorCount)
            for _ in 0..<anchorCount {
                let epubPath = try r.readString()
                let bookTitle = try r.readString()
                let chapterIdx = Int(try r.readI32())
                let paragraphIdx = Int(try r.readI32())
                anchors.append(LibraryEntityIndex.LibraryAnchor(
                    epubURL: URL(fileURLWithPath: epubPath),
                    bookTitle: bookTitle,
                    chapterIdx: chapterIdx,
                    paragraphIdx: paragraphIdx
                ))
            }
            mentions[canonical] = anchors
        }
        let displayCount = Int(try r.readU32())
        var displayNames: [String: String] = [:]
        displayNames.reserveCapacity(displayCount)
        for _ in 0..<displayCount {
            let canonical = try r.readString()
            let display = try r.readString()
            displayNames[canonical] = display
        }
        let entityIndexedCount = Int(try r.readI32())
        let entityIndex = LibraryEntityIndex(
            mentions: mentions,
            displayNames: displayNames,
            indexedBookCount: entityIndexedCount
        )

        return Payload(
            backendIdentifier: backendIdentifier,
            dimension: dimension,
            fingerprint: fingerprint,
            stats: stats,
            sources: sources,
            entityIndex: entityIndex
        )
    }

    enum CacheError: Error {
        case badMagic
        case shortRead
        case vectorDimensionMismatch(expected: Int, actual: Int)
    }
}

// MARK: - Byte writer

/// FileHandle-backed writer with a small in-memory chunk buffer.
/// Keeps peak transient memory bounded — the previous Data-backed
/// `ByteWriter` could balloon to tens of GB on big libraries
/// because `Data.append` doubles capacity on overflow and the
/// in-memory `sources` payload still has to coexist with it.
///
/// The 256 KB threshold is a balance: small enough that peak
/// memory stays trivial, large enough that we're not making a
/// syscall every few writes. With a 36 GB encoded blob (1k books
/// × 1500 paragraphs × 3072-dim Float32 + text) that's ~140 K
/// flushes — fine at ~µs each.
private struct StreamingByteWriter {
    let handle: FileHandle
    private var buffer = Data()
    private static let flushThreshold = 256 * 1024

    init(handle: FileHandle) {
        self.handle = handle
        buffer.reserveCapacity(Self.flushThreshold + 4096)
    }

    mutating func writeU8(_ v: UInt8) throws {
        buffer.append(v)
        try flushIfNeeded()
    }

    mutating func writeU32(_ v: UInt32) throws {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { buffer.append(contentsOf: $0) }
        try flushIfNeeded()
    }

    mutating func writeI32(_ v: Int32) throws {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { buffer.append(contentsOf: $0) }
        try flushIfNeeded()
    }

    mutating func writeString(_ s: String) throws {
        let bytes = Data(s.utf8)
        try writeU32(UInt32(bytes.count))
        // Large strings are flushed directly to avoid blowing
        // the buffer past its threshold in one shot.
        if bytes.count >= Self.flushThreshold {
            try flush()
            try handle.write(contentsOf: bytes)
        } else {
            buffer.append(bytes)
            try flushIfNeeded()
        }
    }

    mutating func writeBytes(_ d: Data) throws {
        if d.count >= Self.flushThreshold {
            try flush()
            try handle.write(contentsOf: d)
        } else {
            buffer.append(d)
            try flushIfNeeded()
        }
    }

    mutating func writeFloatVector(
        _ v: [Float], expectedCount: Int
    ) throws {
        if v.count != expectedCount {
            throw FederatedIndexCache.CacheError
                .vectorDimensionMismatch(expected: expectedCount, actual: v.count)
        }
        let byteCount = v.count * MemoryLayout<Float>.size
        if byteCount >= Self.flushThreshold {
            try flush()
            try v.withUnsafeBufferPointer { ptr -> Void in
                let raw = UnsafeRawBufferPointer(ptr)
                try handle.write(contentsOf: Data(raw))
            }
        } else {
            v.withUnsafeBufferPointer { ptr in
                let raw = UnsafeRawBufferPointer(ptr)
                buffer.append(contentsOf: raw)
            }
            try flushIfNeeded()
        }
    }

    mutating func flushIfNeeded() throws {
        if buffer.count >= Self.flushThreshold {
            try flush()
        }
    }

    mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

// MARK: - Byte reader

private struct ByteReader {
    let data: Data
    var offset: Int = 0

    mutating func readU8() throws -> UInt8 {
        let bytes = try readBytes(1)
        return bytes[bytes.startIndex]
    }

    mutating func readU32() throws -> UInt32 {
        let bytes = try readBytes(4)
        return bytes.withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: UInt32.self).littleEndian
        }
    }

    mutating func readI32() throws -> Int32 {
        let bytes = try readBytes(4)
        return bytes.withUnsafeBytes { ptr in
            Int32(bitPattern: ptr.loadUnaligned(as: UInt32.self).littleEndian)
        }
    }

    mutating func readString() throws -> String {
        let n = Int(try readU32())
        let bytes = try readBytes(n)
        guard let s = String(data: bytes, encoding: .utf8) else {
            throw FederatedIndexCache.CacheError.shortRead
        }
        return s
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard offset + count <= data.count else {
            throw FederatedIndexCache.CacheError.shortRead
        }
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    mutating func readFloatVector(count: Int) throws -> [Float] {
        let byteCount = count * MemoryLayout<Float>.size
        let bytes = try readBytes(byteCount)
        return bytes.withUnsafeBytes { raw -> [Float] in
            let ptr = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(
                start: ptr.baseAddress, count: count
            ))
        }
    }
}
