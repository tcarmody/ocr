import Foundation
import CryptoKit

/// R-Library-Dedupe content-fingerprint utility. SHA-256 of a
/// file's bytes, streamed in 64 KB chunks so the hash cost stays
/// flat as file size grows — a 50 MB EPUB hashes in ~0.5 s on
/// Apple silicon without allocating a 50 MB `Data` first.
///
/// Used at three sites:
///  * `EPUBImporter` — pre-flight hash of the incoming source EPUB
///    so a re-imported book short-circuits before any unpacking.
///  * `JobRunner` — pre-flight hash of the source PDF so a re-
///    dropped scan reuses the existing catalog row instead of
///    re-running OCR.
///  * `humanist-cli library-dedupe` — hashes every EPUB on disk
///    to group content-identical entries for one-time cleanup.
///
/// `sha256(of:)` is intentionally synchronous: callers run it off
/// the main actor via `Task.detached` when batching, and the
/// streamed I/O means there's no large allocation to amortize
/// across an async boundary.
enum ContentHash {

    /// SHA-256 hex digest of the file at `url`. Throws when the
    /// file can't be opened (missing, permissions, deleted between
    /// caller's `fileExists` check and ours).
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hexString(hasher.finalize())
    }

    /// SHA-256 hex digest of an in-memory `Data` blob. Used by
    /// tests and by callers that already have the bytes in hand.
    static func sha256(of data: Data) -> String {
        return hexString(SHA256.hash(data: data))
    }

    private static func hexString<D: Sequence>(_ digest: D) -> String
    where D.Element == UInt8 {
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
