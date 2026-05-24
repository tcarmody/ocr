import XCTest
import LibraryIndexing
import Foundation
@testable import Humanist

/// Coverage for `EmbeddingsSidecarBinaryFormat`: round-trip,
/// shape/size validation, and corruption handling. The format is
/// the on-disk wire shape for the new `.emb` sidecars; integration
/// with `EmbeddingsSidecarStore` lives in
/// `EmbeddingsSidecarStoreKeyingTests`.
@MainActor
final class EmbeddingsSidecarBinaryFormatTests: XCTestCase {

    func test_roundtrip_preserves_full_sidecar_shape() throws {
        let original = EmbeddingsSidecar(
            schemaVersion: EmbeddingsSidecar.currentSchemaVersion,
            backendIdentifier: "apple.nl.sentence.en",
            dimension: 6,
            paragraphs: [
                EmbeddingsSidecar.Entry(
                    chapterIdx: 0,
                    paragraphIdx: 0,
                    textHash: "h0",
                    vector: [0.1, -0.2, 0.3, -0.4, 0.5, -0.6],
                    text: "first paragraph"
                ),
                EmbeddingsSidecar.Entry(
                    chapterIdx: 1,
                    paragraphIdx: 7,
                    textHash: "h1",
                    vector: [Float.infinity, -Float.infinity, 0,
                             .greatestFiniteMagnitude,
                             -.leastNormalMagnitude, .pi],
                    text: nil
                )
            ],
            hierarchy: nil,
            entities: nil
        )

        let data = try EmbeddingsSidecarBinaryFormat.encode(original)
        let restored = try EmbeddingsSidecarBinaryFormat.decode(data)

        XCTAssertEqual(restored.schemaVersion, original.schemaVersion)
        XCTAssertEqual(restored.backendIdentifier, original.backendIdentifier)
        XCTAssertEqual(restored.dimension, original.dimension)
        XCTAssertEqual(restored.paragraphs.count, original.paragraphs.count)

        // First paragraph: full fidelity on metadata + vectors +
        // text. Float equality is exact because we round-trip the
        // raw bit pattern; no JSON/strtod path in the middle.
        XCTAssertEqual(restored.paragraphs[0].chapterIdx, 0)
        XCTAssertEqual(restored.paragraphs[0].paragraphIdx, 0)
        XCTAssertEqual(restored.paragraphs[0].textHash, "h0")
        XCTAssertEqual(restored.paragraphs[0].vector,
                       original.paragraphs[0].vector)
        XCTAssertEqual(restored.paragraphs[0].text, "first paragraph")

        // Second paragraph: special-float values survive, nil text
        // stays nil (not "" — the codec preserves that distinction).
        XCTAssertEqual(restored.paragraphs[1].vector[0], .infinity)
        XCTAssertEqual(restored.paragraphs[1].vector[1], -.infinity)
        XCTAssertEqual(restored.paragraphs[1].vector[2], 0)
        XCTAssertEqual(restored.paragraphs[1].vector[3], .greatestFiniteMagnitude)
        XCTAssertEqual(restored.paragraphs[1].vector[4], -.leastNormalMagnitude)
        XCTAssertEqual(restored.paragraphs[1].vector[5], .pi)
        XCTAssertNil(restored.paragraphs[1].text)
    }

    func test_roundtrip_handles_empty_paragraph_list() throws {
        // Newly-created sidecar before any paragraphs have been
        // indexed. Encoder/decoder must handle the zero-vector case
        // without short-read errors.
        let original = EmbeddingsSidecar.empty(
            backend: "nope", dimension: 16
        )
        let data = try EmbeddingsSidecarBinaryFormat.encode(original)
        let restored = try EmbeddingsSidecarBinaryFormat.decode(data)
        XCTAssertEqual(restored.dimension, 16)
        XCTAssertEqual(restored.backendIdentifier, "nope")
        XCTAssertEqual(restored.paragraphs.count, 0)
    }

    func test_decode_rejects_bad_magic() {
        let data = Data(repeating: 0xFF, count: 64)
        XCTAssertThrowsError(try EmbeddingsSidecarBinaryFormat.decode(data)) { err in
            guard case EmbeddingsSidecarBinaryFormat.FormatError.badMagic = err else {
                XCTFail("expected .badMagic, got \(err)")
                return
            }
        }
    }

    func test_decode_rejects_short_read_at_header() {
        // Empty file → can't even read the magic+length prefix.
        XCTAssertThrowsError(try EmbeddingsSidecarBinaryFormat.decode(Data())) { err in
            guard case EmbeddingsSidecarBinaryFormat.FormatError.shortRead = err else {
                XCTFail("expected .shortRead, got \(err)")
                return
            }
        }
    }

    func test_decode_rejects_truncated_vector_blob() throws {
        let sidecar = EmbeddingsSidecar(
            schemaVersion: EmbeddingsSidecar.currentSchemaVersion,
            backendIdentifier: "id",
            dimension: 4,
            paragraphs: [
                EmbeddingsSidecar.Entry(
                    chapterIdx: 0, paragraphIdx: 0, textHash: "h",
                    vector: [1, 2, 3, 4], text: nil
                )
            ],
            hierarchy: nil, entities: nil
        )
        let data = try EmbeddingsSidecarBinaryFormat.encode(sidecar)
        let truncated = data.prefix(data.count - 4)  // drop one float

        XCTAssertThrowsError(try EmbeddingsSidecarBinaryFormat.decode(truncated)) { err in
            guard case EmbeddingsSidecarBinaryFormat.FormatError.blobSizeMismatch = err else {
                XCTFail("expected .blobSizeMismatch, got \(err)")
                return
            }
        }
    }

    func test_encode_writes_packed_float32_blob() throws {
        // Sanity: the encoded size for a 1-paragraph 4-dim sidecar
        // should be magic(8) + headerLen(4) + headerJSON + 16 bytes
        // of Float32 vector. We don't care about the JSON length
        // exactly, just that the trailing blob is the expected 16.
        let sidecar = EmbeddingsSidecar(
            schemaVersion: EmbeddingsSidecar.currentSchemaVersion,
            backendIdentifier: "x",
            dimension: 4,
            paragraphs: [
                EmbeddingsSidecar.Entry(
                    chapterIdx: 0, paragraphIdx: 0, textHash: "h",
                    vector: [1.5, 2.5, 3.5, 4.5], text: nil
                )
            ],
            hierarchy: nil, entities: nil
        )
        let data = try EmbeddingsSidecarBinaryFormat.encode(sidecar)
        // Header length sits at bytes [8..<12].
        let headerLen = Int(data.subdata(in: 8..<12)
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        let trailing = data.count - (8 + 4 + headerLen)
        XCTAssertEqual(trailing, 16,
                       "vector blob should be exactly dimension * 4 bytes")

        // Spot-check the float bytes: last 16 bytes should encode
        // 1.5, 2.5, 3.5, 4.5 in IEEE 754 single precision.
        let tail = data.suffix(16)
        let floats: [Float] = tail.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: ptr.baseAddress, count: 4))
        }
        XCTAssertEqual(floats, [1.5, 2.5, 3.5, 4.5])
    }

    func test_roundtrip_preserves_wasFallback_true() throws {
        // Sticky-fallback flag — set by the fallback branch of the
        // index builder when the user's primary backend errored and
        // we wrote against the Apple-NL safety net. Used by the
        // bulk-index skip check; loses meaning if it doesn't
        // survive write+read.
        var sidecar = EmbeddingsSidecar.empty(
            backend: "apple.nl.sentence.en", dimension: 4
        )
        sidecar.wasFallback = true
        let data = try EmbeddingsSidecarBinaryFormat.encode(sidecar)
        let restored = try EmbeddingsSidecarBinaryFormat.decode(data)
        XCTAssertTrue(restored.wasFallback)
    }

    func test_roundtrip_preserves_wasFallback_false() throws {
        let sidecar = EmbeddingsSidecar.empty(
            backend: "gemini.embedding-001.768", dimension: 4
        )
        // wasFallback defaults to false; encode/decode should not
        // flip it.
        let data = try EmbeddingsSidecarBinaryFormat.encode(sidecar)
        let restored = try EmbeddingsSidecarBinaryFormat.decode(data)
        XCTAssertFalse(restored.wasFallback)
    }
}
