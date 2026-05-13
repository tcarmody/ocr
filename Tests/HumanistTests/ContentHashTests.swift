import XCTest
@testable import Humanist

/// R-Library-Dedupe `ContentHash` coverage. The streamed-file
/// path and the in-memory path are both exercised, plus a known-
/// vector check against the canonical SHA-256 of "abc" so a
/// future regression in the chunking would surface immediately.
final class ContentHashTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("contenthash-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    func testSHA256OfData_matchesKnownVector() {
        // NIST canonical SHA-256("abc")
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(
            ContentHash.sha256(of: Data("abc".utf8)),
            expected
        )
    }

    func testSHA256OfFile_matchesData() throws {
        let payload = Data("the rain in spain falls mainly on the plain\n".utf8)
        let url = tempDir.appendingPathComponent("sample.txt")
        try payload.write(to: url)
        let fromFile = try ContentHash.sha256(of: url)
        let fromBytes = ContentHash.sha256(of: payload)
        XCTAssertEqual(fromFile, fromBytes)
    }

    func testSHA256OfFile_largerThanChunk_matchesData() throws {
        // 200 KB triggers multiple 64 KB reads; the streamed path
        // must produce the same digest as feeding the whole blob
        // to SHA256.hash(data:) in one go.
        let bytes = (0..<(200 * 1024)).map { UInt8($0 % 256) }
        let payload = Data(bytes)
        let url = tempDir.appendingPathComponent("big.bin")
        try payload.write(to: url)
        let fromFile = try ContentHash.sha256(of: url)
        let fromBytes = ContentHash.sha256(of: payload)
        XCTAssertEqual(fromFile, fromBytes)
    }

    func testSHA256OfFile_missing_throws() {
        let url = tempDir.appendingPathComponent("does-not-exist.bin")
        XCTAssertThrowsError(try ContentHash.sha256(of: url))
    }

    func testSHA256_distinctContents_distinctHashes() throws {
        let a = tempDir.appendingPathComponent("a.txt")
        let b = tempDir.appendingPathComponent("b.txt")
        try Data("alpha".utf8).write(to: a)
        try Data("beta".utf8).write(to: b)
        XCTAssertNotEqual(
            try ContentHash.sha256(of: a),
            try ContentHash.sha256(of: b)
        )
    }
}
