import Foundation

/// On-disk binary encoding for `EmbeddingsSidecar` (the per-book
/// embedding cache). The legacy `.json` format encoded the vector
/// arrays as JSON-numbered `[Float]`, which is 5–10× the size of
/// packed Float32 and ~50–100× the decode cost (every number
/// strtod-parsed). At library scale (1k+ books × tens of GB of
/// vector data) that decode cost dominates every federated-index
/// rebuild.
///
/// Format (version 1):
///
/// ```
/// [8 bytes]   magic + version: "HUMSIDC\x01"
/// [u32 LE]    header byte length N
/// [N bytes]   JSON header — `EmbeddingsSidecar` minus the
///             per-paragraph `vector` field (text/hash/idx etc.
///             stay JSON-readable for debuggability)
/// [...]       vector blob: paragraphCount × dimension × 4 bytes,
///             packed Float32, in paragraphs-order
/// ```
///
/// JSON-encoding the header (vs. fully binary) keeps the small
/// metadata easy to inspect with `jq` / hex dump tools. The decode
/// is bounded by paragraph count (~thousands), not by dimension ×
/// paragraphCount (~millions of floats), so the vector blob being
/// raw bytes is what actually drives the speedup.
///
/// Old `.json` sidecars stay readable via the store's read-candidate
/// chain; new writes go to `.emb`. A separate bulk upgrade migrates
/// legacy files on next launch.
enum EmbeddingsSidecarBinaryFormat {

    private static let magic: [UInt8] = [
        0x48, 0x55, 0x4D, 0x53, 0x49, 0x44, 0x43, 0x01  // "HUMSIDC\x01"
    ]

    enum FormatError: Error {
        case badMagic
        case shortRead
        case headerDecode(Error)
        case blobSizeMismatch(expected: Int, actual: Int)
        case vectorCountMismatch(headerParagraphs: Int, blobVectors: Int)
    }

    // MARK: - Encode

    static func encode(_ sidecar: EmbeddingsSidecar) throws -> Data {
        let header = HeaderShape(
            schemaVersion: sidecar.schemaVersion,
            backendIdentifier: sidecar.backendIdentifier,
            dimension: sidecar.dimension,
            paragraphs: sidecar.paragraphs.map { p in
                HeaderShape.HeaderEntry(
                    chapterIdx: p.chapterIdx,
                    paragraphIdx: p.paragraphIdx,
                    textHash: p.textHash,
                    text: p.text
                )
            },
            hierarchy: sidecar.hierarchy,
            entities: sidecar.entities
        )
        let headerJSON = try Self.encoder.encode(header)

        var out = Data()
        out.append(contentsOf: magic)
        var headerLen = UInt32(headerJSON.count).littleEndian
        withUnsafeBytes(of: &headerLen) { out.append(contentsOf: $0) }
        out.append(headerJSON)

        // Vector blob — append each paragraph's Float32 vector in
        // order. Dimension validation (count == sidecar.dimension)
        // is the caller's responsibility on the build side; we
        // round-trip whatever shape was handed in.
        for p in sidecar.paragraphs {
            p.vector.withUnsafeBufferPointer { ptr in
                out.append(contentsOf: UnsafeRawBufferPointer(ptr))
            }
        }
        return out
    }

    // MARK: - Decode

    static func decode(_ data: Data) throws -> EmbeddingsSidecar {
        guard data.count >= magic.count + 4 else {
            throw FormatError.shortRead
        }
        guard data.prefix(magic.count).elementsEqual(magic) else {
            throw FormatError.badMagic
        }
        var offset = magic.count

        // Header length: 4 LE bytes.
        let headerLen = Int(data.subdata(in: offset..<(offset + 4))
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        offset += 4

        guard offset + headerLen <= data.count else {
            throw FormatError.shortRead
        }
        let headerData = data.subdata(in: offset..<(offset + headerLen))
        offset += headerLen

        let header: HeaderShape
        do {
            header = try Self.decoder.decode(HeaderShape.self, from: headerData)
        } catch {
            throw FormatError.headerDecode(error)
        }

        let vectorByteCount = header.paragraphs.count
            * header.dimension * MemoryLayout<Float>.size
        let remaining = data.count - offset
        if remaining != vectorByteCount {
            throw FormatError.blobSizeMismatch(
                expected: vectorByteCount, actual: remaining
            )
        }

        var paragraphs: [EmbeddingsSidecar.Entry] = []
        paragraphs.reserveCapacity(header.paragraphs.count)
        for headerEntry in header.paragraphs {
            let bytes = data.subdata(in: offset..<(offset + header.dimension * 4))
            offset += header.dimension * 4
            let vector: [Float] = bytes.withUnsafeBytes { raw in
                let ptr = raw.bindMemory(to: Float.self)
                return Array(UnsafeBufferPointer(
                    start: ptr.baseAddress, count: header.dimension
                ))
            }
            paragraphs.append(EmbeddingsSidecar.Entry(
                chapterIdx: headerEntry.chapterIdx,
                paragraphIdx: headerEntry.paragraphIdx,
                textHash: headerEntry.textHash,
                vector: vector,
                text: headerEntry.text
            ))
        }

        return EmbeddingsSidecar(
            schemaVersion: header.schemaVersion,
            backendIdentifier: header.backendIdentifier,
            dimension: header.dimension,
            paragraphs: paragraphs,
            hierarchy: header.hierarchy,
            entities: header.entities
        )
    }

    // MARK: - Header shape

    /// Mirror of `EmbeddingsSidecar` minus per-paragraph vectors —
    /// what gets JSON-encoded into the header block. Separate type
    /// (not custom Codable on `Entry`) keeps the in-memory shape
    /// honest: a real `Entry` always carries its vector.
    private struct HeaderShape: Codable {
        let schemaVersion: Int
        let backendIdentifier: String
        let dimension: Int
        let paragraphs: [HeaderEntry]
        let hierarchy: BookHierarchyIndex?
        let entities: BookEntityIndex?

        struct HeaderEntry: Codable {
            let chapterIdx: Int
            let paragraphIdx: Int
            let textHash: String
            let text: String?
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()
}
