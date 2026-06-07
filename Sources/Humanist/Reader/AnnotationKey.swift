import Foundation

/// Resolves the storage key under which a book's annotations live in
/// `AnnotationStore`.
///
/// Historically the key was the EPUB's content hash (`ContentHash`).
/// That's fatal for user data: the hash is a digest of the whole file,
/// so every editor Save — which repacks the entire `.epub` — produces a
/// new hash and orphans the book's marks under the old one. The fix is
/// to key by the book's *identity* (`OPFReader.Metadata.bookID`, the
/// package `dc:identifier`), which the editor preserves across saves,
/// re-OCR, and repacking. The content hash remains the fallback for
/// books that declare no identifier.
enum AnnotationKey {

    /// Stable storage key for a book.
    ///
    /// - When `bookID` is present, returns `id-<sha256(bookID)>` — the
    ///   identifier is hashed so the result is always a filesystem-safe
    ///   fixed-length string regardless of the identifier's shape
    ///   (`urn:uuid:…`, a bare ISBN, a URL, etc.). The `id-` prefix
    ///   keeps it distinct from a raw content-hash key.
    /// - Otherwise returns the `contentHash` unchanged, preserving the
    ///   legacy behaviour for books without an identifier.
    static func resolve(bookID: String?, contentHash: String) -> String {
        if let id = bookID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            return "id-" + ContentHash.sha256(of: Data(id.utf8))
        }
        return contentHash
    }
}
