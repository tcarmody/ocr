import XCTest
import AI
@testable import Pipeline

/// Tests for `PDFToEPUBPipeline.chunkBatchRequestsBySize` — the
/// greedy bin-packing partitioner introduced after the Habermas
/// Vol.1 OCR run hit Anthropic's 256 MB request cap with a
/// 277-page single batch (~295 MB encoded). The partitioner is
/// pure + small, so unit tests pin the boundary conditions
/// without standing up a full pipeline.
final class BatchChunkingTests: XCTestCase {

    // MARK: - Helpers

    /// Build a fake batch request whose body weight approximates
    /// `imageBytes` of base64 payload + a small JSON envelope. The
    /// partitioner sums each request's image-block character
    /// counts, so we hand it an actual base64-shaped string of the
    /// right size.
    private func makeRequest(
        index: Int, imageBytes: Int
    ) -> AnthropicBatchSubmitRequest.Request {
        let payload = String(repeating: "A", count: imageBytes)
        return AnthropicBatchSubmitRequest.Request(
            customId: String(format: "page-%05d", index),
            params: AnthropicMessageRequest(
                model: .sonnet4_6,
                maxTokens: 8000,
                messages: [
                    Message(role: .user, content: .blocks([
                        .image(
                            mediaType: .png,
                            base64Data: payload,
                            cacheControl: nil
                        )
                    ]))
                ]
            )
        )
    }

    // MARK: - Single-chunk case

    func test_small_batch_fits_in_one_chunk() {
        let requests = (0..<10).map {
            makeRequest(index: $0, imageBytes: 500_000)
        }
        let chunks = PDFToEPUBPipeline.chunkBatchRequestsBySize(
            requests, maxBodyBytes: 180_000_000
        )
        XCTAssertEqual(chunks.count, 1,
            "10 × 500 KB = 5 MB; well under 180 MB so one chunk")
        XCTAssertEqual(chunks.first?.count, 10)
    }

    // MARK: - Multi-chunk case

    func test_large_batch_partitions_into_multiple_chunks() {
        // 277 × ~800 KB raw images ≈ 222 MB raw; base64 inflates
        // ~33% → ~295 MB encoded. Reproduces the Habermas Vol.1
        // hit. With a 180 MB cap, we expect ≥ 2 chunks.
        let requests = (0..<277).map {
            makeRequest(index: $0, imageBytes: 1_070_000)  // ≈ 800 KB raw image base64-encoded
        }
        let chunks = PDFToEPUBPipeline.chunkBatchRequestsBySize(
            requests, maxBodyBytes: 180_000_000
        )
        XCTAssertGreaterThanOrEqual(chunks.count, 2,
            "Habermas-scale batch should split into 2+ chunks")
        // Each chunk must respect the cap.
        for chunk in chunks {
            let totalBytes = chunk.reduce(0) { sum, r in
                sum + r.params.messages.reduce(0) { mSum, m in
                    guard case .blocks(let blocks) = m.content else { return mSum }
                    return mSum + blocks.reduce(0) { bSum, b in
                        if case .image(_, let data, _) = b {
                            return bSum + data.utf8.count
                        }
                        return bSum
                    }
                }
            }
            XCTAssertLessThan(totalBytes, 180_000_000,
                "no chunk should exceed the 180 MB cap")
        }
        // No requests lost in the split.
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.count }, 277)
    }

    func test_partition_preserves_request_order() {
        // Deterministic ordering matters because the batch results
        // come back keyed by customId but the dispatcher's
        // pendingByIndex map relies on stable customId →
        // pageIndex parsing. Verify chunks consume requests in
        // input order, contiguously.
        let requests = (0..<50).map {
            makeRequest(index: $0, imageBytes: 8_000_000)
        }
        let chunks = PDFToEPUBPipeline.chunkBatchRequestsBySize(
            requests, maxBodyBytes: 180_000_000
        )
        var seen = 0
        for chunk in chunks {
            for request in chunk {
                let expected = String(format: "page-%05d", seen)
                XCTAssertEqual(request.customId, expected,
                    "request \(seen) misordered in chunk output")
                seen += 1
            }
        }
        XCTAssertEqual(seen, 50)
    }

    // MARK: - Pathological cases

    func test_oversize_single_request_gets_its_own_chunk() {
        // A 200 MB single request can't fit in a 180 MB cap. The
        // partitioner should still emit it as a single-element
        // chunk; Anthropic will reject it (413), but that's
        // strictly better than refusing to submit anything else
        // alongside it.
        let big = makeRequest(index: 0, imageBytes: 200_000_000)
        let normal = (1..<5).map {
            makeRequest(index: $0, imageBytes: 500_000)
        }
        let chunks = PDFToEPUBPipeline.chunkBatchRequestsBySize(
            [big] + normal, maxBodyBytes: 180_000_000
        )
        XCTAssertGreaterThanOrEqual(chunks.count, 2,
            "oversize request must not block the rest from being submitted")
        XCTAssertEqual(chunks.first?.count, 1,
            "oversize request gets a chunk to itself")
    }

    func test_empty_input_returns_empty_chunks() {
        XCTAssertTrue(
            PDFToEPUBPipeline.chunkBatchRequestsBySize(
                [], maxBodyBytes: 180_000_000
            ).isEmpty
        )
    }
}
