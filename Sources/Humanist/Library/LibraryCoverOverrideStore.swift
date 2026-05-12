import Foundation

/// Side-car cover-image overrides for library entries. Lives next
/// to `library.json` so iCloud-synced libraries see consistent
/// thumbnails on every machine, and so the override travels with
/// the catalog when a user moves their library directory.
///
/// Decoupled from the EPUB file itself: writing an override does
/// NOT modify the `.epub` on disk. The library table prefers an
/// override when one exists; the EPUB-embedded cover stays
/// untouched and remains the fallback when the override file is
/// removed or the user resyncs from a backup.
///
/// File shape: `<storeDir>/.humanist/Covers/<libraryID>.jpg`.
/// JPEG-only for v1 — Open Library hands back JPEGs and writing
/// one format keeps the read path simple. PNG / WebP support is
/// straightforward to add if a source ever returns them.
struct LibraryCoverOverrideStore: Sendable {
    let catalogURL: URL

    init(catalogURL: URL) {
        self.catalogURL = catalogURL
    }

    /// Resolve the override store for the current run-time
    /// configuration — picks up the iCloud-shared catalog
    /// location vs. local Application Support automatically by
    /// reusing `LibraryStore.resolveStoreURL`. Cheap to call;
    /// each call hits UserDefaults + a couple of FileManager
    /// checks. Convenient for read-side callers (`CoverImageCache`)
    /// that don't already hold a `LibraryStore` reference.
    static func currentDefault() -> LibraryCoverOverrideStore {
        let resolved = LibraryStore.resolveStoreURL()
        return LibraryCoverOverrideStore(catalogURL: resolved.url)
    }

    /// `<storeDir>/.humanist/Covers/`. Created lazily on first
    /// write; read paths just check existence and return nil if
    /// the directory hasn't been created yet.
    var directory: URL {
        catalogURL.deletingLastPathComponent()
            .appendingPathComponent("Covers", isDirectory: true)
    }

    /// Resolve the on-disk override URL for a library entry. Does
    /// NOT check whether the file exists — callers use this for
    /// both reading (existence check) and writing (destination).
    func url(for libraryID: UUID) -> URL {
        directory.appendingPathComponent("\(libraryID.uuidString).jpg")
    }

    /// True when an override file exists on disk for this entry.
    /// Cheap stat — safe to call per-row during table rendering.
    func hasOverride(for libraryID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: libraryID).path)
    }

    /// Write the bytes verbatim. Creates the directory if needed.
    /// Atomic write so a partial download / interrupted save
    /// doesn't leave a corrupt JPEG in place. Caller is
    /// responsible for already-decoded validation (e.g. checking
    /// the response was actually image data, not an HTML error
    /// page).
    func save(data: Data, for libraryID: UUID) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try data.write(to: url(for: libraryID), options: .atomic)
    }

    /// Remove the override for a library entry. Best-effort —
    /// missing files don't throw (a no-override removal is
    /// already in the desired state).
    func delete(for libraryID: UUID) {
        try? FileManager.default.removeItem(at: url(for: libraryID))
    }

    // MARK: - downloading

    /// Fetch the bytes at `remoteURL` and save them as the
    /// override for this entry. Throws on network failure,
    /// non-2xx HTTP, or zero-byte response. Used by the
    /// metadata-lookup sheet's accept path.
    func download(
        from remoteURL: URL,
        for libraryID: UUID,
        session: URLSession = .shared
    ) async throws {
        let (data, response) = try await session.data(from: remoteURL)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw CoverDownloadError.http(status: http.statusCode)
        }
        guard !data.isEmpty else {
            throw CoverDownloadError.emptyResponse
        }
        try save(data: data, for: libraryID)
    }
}

enum CoverDownloadError: Error, LocalizedError {
    case http(status: Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .http(let s):     return "Cover host returned HTTP \(s)."
        case .emptyResponse:   return "Cover host returned no data."
        }
    }
}
