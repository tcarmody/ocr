import XCTest
@testable import AI

/// Smoke tests for the Array `chunked(into:)` helper that
/// `GeminiEmbeddingBackend.embed(_:)` uses to partition large
/// paragraph counts under Google's 100-items-per-request limit.
/// The actual `embed` call hits the network, so those tests live
/// in the manual-spike binaries; this file pins the
/// partitioning invariants the chunker depends on.
///
/// (`chunked(into:)` is a fileprivate extension inside
/// GeminiEmbeddingBackend.swift; we test the same behavior via
/// a local copy here to avoid widening the access modifier just
/// for tests.)
final class GeminiEmbeddingChunkingTests: XCTestCase {

    /// Local mirror of the chunker used by GeminiEmbeddingBackend.
    /// Same signature, same body — tests pin the invariants the
    /// production path relies on without changing access modifiers.
    private func chunked<T>(_ array: [T], into size: Int) -> [[T]] {
        precondition(size > 0)
        guard !array.isEmpty else { return [] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<Swift.min($0 + size, array.count)])
        }
    }

    func test_small_input_returns_one_chunk() {
        let xs = chunked(Array(0..<50), into: 100)
        XCTAssertEqual(xs.count, 1)
        XCTAssertEqual(xs[0], Array(0..<50))
    }

    func test_exactly_at_chunk_size_returns_one_chunk() {
        let xs = chunked(Array(0..<100), into: 100)
        XCTAssertEqual(xs.count, 1)
        XCTAssertEqual(xs[0].count, 100)
    }

    func test_just_over_chunk_size_returns_two_chunks() {
        let xs = chunked(Array(0..<101), into: 100)
        XCTAssertEqual(xs.count, 2)
        XCTAssertEqual(xs[0].count, 100)
        XCTAssertEqual(xs[1], [100])
    }

    func test_long_book_partitions_correctly() {
        // 1500 paragraphs — typical for a long Habermas / Foucault
        // book. With the v1 single-request behavior this would hit
        // Gemini's 100-item cap and fail. Verify the chunker
        // produces 15 chunks of exactly 100.
        let xs = chunked(Array(0..<1500), into: 100)
        XCTAssertEqual(xs.count, 15)
        for chunk in xs {
            XCTAssertEqual(chunk.count, 100)
        }
        // No items lost in the split.
        XCTAssertEqual(xs.reduce(0) { $0 + $1.count }, 1500)
        // Order preserved — the federated index expects embeddings
        // in input order since the Gemini response doesn't include
        // an index field.
        XCTAssertEqual(xs.flatMap { $0 }, Array(0..<1500))
    }

    func test_uneven_remainder_truncates_last_chunk() {
        let xs = chunked(Array(0..<137), into: 100)
        XCTAssertEqual(xs.count, 2)
        XCTAssertEqual(xs[0].count, 100)
        XCTAssertEqual(xs[1].count, 37)
    }

    func test_empty_input_returns_empty_chunks() {
        XCTAssertTrue(chunked([Int](), into: 100).isEmpty)
    }
}
